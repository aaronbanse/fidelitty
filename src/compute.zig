const std = @import("std");
const mem = std.mem;

const vk = @import("vulkan");

const gen_config = @import("gen_config");
const dataset_config = @import("dataset_config");

const uni_im = @import("unicode_image.zig");
const glyph = @import("glyph.zig");

/// Non-owning handle to a render pipeline managed by compute context
pub const PipelineHandle = struct {
    // dimensions of output image in unicode pixels
    out_im_w: u16,
    out_im_h: u16,

    input_surface: [*]u8, // write to this
    output_surface: [*]uni_im.UnicodePixelData, // read from this
    // TODO: consider making above a UnicodeImage, compute shaders would need to write chars directly

    _id: Context.HandleID, // Internal: unique id to tie to vulkan resources

    // input surface dimensions is dependent on size of output image * unicode pixel size
    pub fn inputDims(self: @This(), patch_w: u8, patch_h: u8) struct { w: u32, h: u32 } {
        return .{
            .w = @as(u32, self.out_im_w) * @as(u32, patch_w),
            .h = @as(u32, self.out_im_h) * @as(u32, patch_h),
        };
    }
};

/// Context for accessing compute hardware
pub const Context = struct {
    pub const HandleID = usize;

    pub const ContextOwnershipMode = enum {
        Owned,
        Borrowed,
    };

    // INTERNAL
    // ---------------------------

    // Convenience struct since we always bind memory to buffers
    const MemBuffer = struct {
        buf: vk.Buffer,
        mem: vk.DeviceMemory,
        size: usize,
    };

    // Struct for storing handles to resources associated with pipelines,
    // one for each pipeline
    const PipelineResources = struct {
        input_buf: MemBuffer,
        device_input_buf: MemBuffer,
        device_output_buf: MemBuffer,
        output_buf: MemBuffer,

        buf_io_desc_set: vk.DescriptorSet,

        cmd_buf: vk.CommandBuffer,

        compute_pipeline: vk.Pipeline,

        pipeline_complete: vk.Fence,
    };

    // Layouts reused for each pipeline
    _io_desc_layout: vk.DescriptorSetLayout,
    _glyph_set_desc_layout: vk.DescriptorSetLayout,
    _pipeline_layout: vk.PipelineLayout,

    // physical device info
    _physical_device: vk.PhysicalDevice,
    _mem_props: vk.PhysicalDeviceMemoryProperties,

    // store active pipelines
    _pipelines: std.AutoHashMap(HandleID, PipelineResources),
    _max_pipelines: u8,
    
    // Buffers for pipeline-global glyph set
    _device_codepoint_buf: MemBuffer, // Unicode codepoints
    _device_mask_buf: MemBuffer, // Glyph masks
    _device_color_eqn_buf: MemBuffer, // Precomputed values for color equations
    _num_codepoints: u32,
    
    // Size of each unicode pixel in pixels, e.g. compression resolution
    // Fixed on initialization since it is tied to the dimensions of glyphs in our precomputed glyph set
    _patch_w: u8,
    _patch_h: u8,

    // Command buffer for one-time upload
    _glyph_set_upload_cmd_buf: vk.CommandBuffer,

    // Descriptors to bind glyph set data to compute shaders
    _glyph_set_desc_set: vk.DescriptorSet,

    // Vulkan instance wrappers for dispatch tables
    _vkb: vk.BaseWrapper,
    _vki: vk.InstanceWrapper,
    _vkd: vk.DeviceWrapper,
    _instance: vk.InstanceProxy,
    _device: vk.DeviceProxy,
    
    // Handles
    _queue: vk.Queue,
    _cmd_pool: vk.CommandPool,
    _desc_pool: vk.DescriptorPool,


    // PUBLIC API
    // ---------------------------

    // Did we create this context or did we derive it from an existing vulkan instance
    context_ownership: ContextOwnershipMode,

    /// Initialize a standalone vulkan context and setup machinery
    pub fn init(
        allocator: mem.Allocator,
        max_pipelines: u8
    ) !@This() {
        var ctx: @This() = undefined;

        ctx.context_ownership = .Owned;
        ctx._pipelines = .init(allocator);
        ctx._max_pipelines = max_pipelines;
        ctx._patch_w = dataset_config.patch_width;
        ctx._patch_h = dataset_config.patch_height;
        ctx.loadBase();
        try ctx.createInstance();
        const compute_device_indices = try ctx.createDevice();
        ctx.createQueue(compute_device_indices.queue_fam_index);
        try ctx.createCommandPool(compute_device_indices.queue_fam_index);
        try ctx.createDescriptorPool(max_pipelines);
        try ctx.createLayouts();

        // load glyph dataset to gpu
        const dataset_raw = @embedFile(gen_config.dataset_file);
        var dataset: glyph.UnicodeGlyphDataset(dataset_config.patch_width, dataset_config.patch_height, dataset_config.charset_size) = undefined;
        @memcpy(mem.asBytes(&dataset), dataset_raw);
        try ctx.createGlyphSet(dataset_config.patch_width, dataset_config.patch_height, dataset_config.charset_size, &dataset);

        return ctx;
    }

    // TODO: FINISH IMPLEMENTING STUB
    // Initialize a vulkan context from an existing one to allow attaching directly to output of other pipelines
    pub fn initFromExisting(self: *@This(), allocator: mem.Allocator) !void {
        self.context_ownership = .Borrowed;
        self._pipelines = .init(allocator);
    }

    // Cleanup resources
    pub fn deinit(self: *@This()) void {
        // wait for all work to finish
        self._device.deviceWaitIdle() catch {};

        // Destroy all pipelines
        var iter = self._pipelines.iterator();
        while (iter.next()) |entry| {
            self.destroyPipelineResources(entry.value_ptr);
        }
        self._pipelines.deinit();

        // Only cleanup Vulkan resources if we own them
        // We may need to change this, and still destroy resources we allocated ourselves, just not the vulkan / device instance.
        if (self.context_ownership == .Owned) {
            // Destroy glyph set buffers
            self.destroyMemBuffer(self._device_codepoint_buf);
            self.destroyMemBuffer(self._device_mask_buf);
            self.destroyMemBuffer(self._device_color_eqn_buf);

            // Destroy layouts
            self._device.destroyPipelineLayout(self._pipeline_layout, null);
            self._device.destroyDescriptorSetLayout(self._io_desc_layout, null);
            self._device.destroyDescriptorSetLayout(self._glyph_set_desc_layout, null);

            // Destroy pools (frees associated descriptor sets and command buffers)
            self._device.destroyDescriptorPool(self._desc_pool, null);
            self._device.destroyCommandPool(self._cmd_pool, null);

            // Destroy device and instance
            self._device.destroyDevice(null);
            self._instance.destroyInstance(null);
        }       
    }

    pub fn createRenderPipeline(
        self: *@This(),
        im_w: u16,
        im_h: u16,
    ) !PipelineHandle {
        const input_size = 3 * @as(usize, im_w) * @as(usize, im_h) * @as(usize, self._patch_w) * @as(usize, self._patch_h) * @sizeOf(u8);
        const output_size = @as(usize, im_w) * @as(usize, im_h) * @sizeOf(uni_im.UnicodePixelData);

        // initialize and allocate resources
        var resources: PipelineResources = undefined;
        try self.createPipelineBuffers(&resources, input_size, output_size);

        try self.createDescriptorSets(&resources);

        // create handle mapped to input / output buffers
        var handle: PipelineHandle = .{
            .out_im_w = im_w,
            .out_im_h = im_h,
            .input_surface = undefined,
            .output_surface = undefined,
            ._id = undefined,
        };
        // map handle to input / output buffers
        try self.mapCpuBuffersToHandle(&resources, &handle.input_surface, &handle.output_surface);

        try self.createComputePipeline(&resources);

        try self.createPipelineCommandBuffer(&resources, im_w, im_h);

        // obtain unique id for handle
        var id: usize = 1;
        while (self._pipelines.contains(id)) : (id += 1) {}
        handle._id = id;

        // add pipeline to registry
        try self._pipelines.put(id, resources);
        
        return handle;
    }

    pub fn executeRenderPipelines(self: @This(), handles: []const PipelineHandle) !void {
        for (handles) |handle| {
            const res: PipelineResources = self._pipelines.get(handle._id)
                orelse return error.InvalidPipelineHandle;

            try self._device.resetFences(1, &.{res.pipeline_complete});

            try self._device.queueSubmit(
                self._queue,
                1, &[_]vk.SubmitInfo{.{
                    .command_buffer_count = 1,
                    .p_command_buffers = @ptrCast(&res.cmd_buf),
                    .p_wait_dst_stage_mask = &[_]vk.PipelineStageFlags{.{ .compute_shader_bit = true }},
                }},
                res.pipeline_complete,
            );
        }
    }

    pub fn waitRenderPipelines(self: @This(), handles: []const PipelineHandle) !void {
        const timeout: u64 = 1_000_000_000; // 1 second
        var fences: [32]vk.Fence = undefined;

        for (handles, 0..) |handle, i| {
            const res = self._pipelines.get(handle._id) orelse return error.InvalidPipelineHandle;
            fences[i] = res.pipeline_complete;
        }

        _ = try self._device.waitForFences(@intCast(handles.len), @ptrCast(&fences), .true, timeout);
    }

    pub fn resizeRenderPipeline(
        self: *@This(),
        handle: *PipelineHandle,
        new_w: u16, new_h: u16
    ) !void {
        const res = self._pipelines.getPtr(handle._id) orelse return error.InvalidPipelineHandle;

        // wait for work on this pipeline to complete
        try self.waitRenderPipelines(&.{handle.*});

        // Calculate new sizes
        const new_input_size = 3 * @as(usize, new_w) * @as(usize, new_h) * @as(usize, self._patch_w) * @as(usize, self._patch_h) * @sizeOf(u8);
        const new_output_size = @as(usize, new_w) * @as(usize, new_h) * @sizeOf(uni_im.UnicodePixelData);

        // Unmap old buffers
        self._device.unmapMemory(res.input_buf.mem);
        self._device.unmapMemory(res.output_buf.mem);

        // Destroy old buffers
        self.destroyMemBuffer(res.input_buf);
        self.destroyMemBuffer(res.device_input_buf);
        self.destroyMemBuffer(res.device_output_buf);
        self.destroyMemBuffer(res.output_buf);

        // Destroy old command buffer and fence
        self._device.freeCommandBuffers(self._cmd_pool, 1, @ptrCast(&res.cmd_buf));
        self._device.destroyFence(res.pipeline_complete, null);

        // Allocate new buffers
        try self.createPipelineBuffers(res, new_input_size, new_output_size);

        // Update descriptor sets to point to new buffers
        self._device.updateDescriptorSets(2, &[_]vk.WriteDescriptorSet{
            .{
                .dst_set = res.buf_io_desc_set,
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_buffer_info = &[_]vk.DescriptorBufferInfo{.{
                    .buffer = res.device_input_buf.buf,
                    .offset = 0,
                    .range = vk.WHOLE_SIZE,
                }},
                .p_image_info = &.{},
                .p_texel_buffer_view = &.{},
            },
            .{
                .dst_set = res.buf_io_desc_set,
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_buffer_info = &[_]vk.DescriptorBufferInfo{.{
                    .buffer = res.device_output_buf.buf,
                    .offset = 0,
                    .range = vk.WHOLE_SIZE,
                }},
                .p_image_info = &.{},
                .p_texel_buffer_view = &.{},
            },
        }, 0, null);

        // Remap CPU buffers to handle
        try self.mapCpuBuffersToHandle(res, &handle.input_surface, &handle.output_surface);

        // Recreate command buffer with new dimensions
        try self.createPipelineCommandBuffer(res, new_w, new_h);

        // Update handle dimensions
        handle.out_im_w = new_w;
        handle.out_im_h = new_h;
    }

    pub fn destroyRenderPipelines(self: *@This(), handles: []PipelineHandle) void {
        for (handles) |*handle| {
            if (self._pipelines.fetchRemove(handle._id)) |kv| {
                var res = kv.value;
                self.destroyPipelineResources(&res);
            }

            // Invalidate handle
            handle._id = 0;
            handle.input_surface = undefined;
            handle.output_surface = undefined;
        }
    }

    // INTERNAL
    // ---------------------------
    fn loadBase(self: *@This()) void {
        self._vkb = vk.BaseWrapper.load(vkGetInstanceProcAddr);
    }

    fn createInstance(self: *@This()) !void {
        const instance_handle = try self._vkb.createInstance(&.{
            .p_application_info = &.{
                .api_version = @bitCast(vk.makeApiVersion(0, 1, 4, 328)),
                .engine_version = 0, // ignore
                .application_version = 0, // ignore
            },
        }, null);
        self._vki = vk.InstanceWrapper.load(instance_handle, self._vkb.dispatch.vkGetInstanceProcAddr.?);
        self._instance = vk.InstanceProxy.init(instance_handle, &self._vki);
    }

    const ComputeDeviceIndices = struct {
        dev_index: u32,
        queue_fam_index: u32
    };

    fn createDevice(self: *@This()) !ComputeDeviceIndices {
        // find compute-capable device
        var num_devices: u32 = undefined;
        var devices: [16]vk.PhysicalDevice = undefined;
        _ = try self._instance.enumeratePhysicalDevices(&num_devices, &devices);
        const compute_device_found = findComputeDevice(devices[0..num_devices], &self._vki);
        const compute_indices = compute_device_found orelse return error.NoComputeCapableDevice;

        // save physical device info
        self._physical_device = devices[compute_indices.dev_index];
        self._mem_props = self._instance.getPhysicalDeviceMemoryProperties(self._physical_device);

        // create device
        const queue_priority: f32 = 1.0;
        const device_handle = try self._vki.createDevice(self._physical_device, &.{
            .queue_create_info_count = 1,
            .p_queue_create_infos = &[_]vk.DeviceQueueCreateInfo{.{
                .queue_family_index = compute_indices.queue_fam_index,
                .queue_count = 1,
                .p_queue_priorities = @ptrCast(&queue_priority),
            }},
        }, null);
        self._vkd = vk.DeviceWrapper.load(device_handle, self._vki.dispatch.vkGetDeviceProcAddr.?);
        self._device = vk.DeviceProxy.init(device_handle, &self._vkd);

        return compute_indices;
    }

    fn createQueue(self: *@This(), compute_queue_fam_index: u32) void {
        self._queue = self._device.getDeviceQueue(compute_queue_fam_index, 0);
    }

    fn createCommandPool(self: *@This(), compute_queue_fam_index: u32) !void {
        self._cmd_pool = try self._device.createCommandPool(&.{
            .queue_family_index = compute_queue_fam_index,
            .flags = .{},
        }, null);
    }

    fn createDescriptorPool(self: *@This(), max_pipelines: u8) !void {
        self._desc_pool = try self._device.createDescriptorPool(&.{
            .max_sets = 1 + max_pipelines,
            .pool_size_count = 1,
            .p_pool_sizes = &[_]vk.DescriptorPoolSize{
                .{
                    .type = .storage_buffer,
                   // 3 static storage buffers and 2 storage buffers per pipeline 
                    .descriptor_count = 3 + (max_pipelines * 2),
                },
            },
        }, null);
    }

    fn createLayouts(self: *@This()) !void {
        // Descriptor layout for static glyph set buffers
        self._glyph_set_desc_layout = try self._device.createDescriptorSetLayout(&.{
            .binding_count = 3,
            .p_bindings = &[_]vk.DescriptorSetLayoutBinding{
                .{
                    .binding = 0,
                    .descriptor_type = .storage_buffer,
                    .descriptor_count = 1,
                    .stage_flags = .{ .compute_bit = true },
                },
                .{
                    .binding = 1,
                    .descriptor_type = .storage_buffer,
                    .descriptor_count = 1,
                    .stage_flags = .{ .compute_bit = true },
                },
                .{
                    .binding = 2,
                    .descriptor_type = .storage_buffer,
                    .descriptor_count = 1,
                    .stage_flags = .{ .compute_bit = true },
                },
            },
        }, null);

        // Descriptor layout for pipeline input / output buffers
        self._io_desc_layout = try self._device.createDescriptorSetLayout(&.{
            .binding_count = 2,
            .p_bindings = &[_]vk.DescriptorSetLayoutBinding{
                .{
                    .binding = 0,
                    .descriptor_type = .storage_buffer,
                    .descriptor_count = 1,
                    .stage_flags = .{ .compute_bit = true },
                },
                .{
                    .binding = 1,
                    .descriptor_type = .storage_buffer,
                    .descriptor_count = 1,
                    .stage_flags = .{ .compute_bit = true },
                },
            },
        }, null);

        // Define pipeline layout
        self._pipeline_layout = try self._device.createPipelineLayout(&.{
            .set_layout_count = 2,
            .p_set_layouts = &[_]vk.DescriptorSetLayout{
                self._glyph_set_desc_layout,
                self._io_desc_layout
            },
            .push_constant_range_count = 1,
            .p_push_constant_ranges = &[_]vk.PushConstantRange{.{
                .stage_flags = .{ .compute_bit = true },
                .offset = 0,
                .size = 8, // 2 x u32
            }},
        }, null);
    }

    fn createGlyphSet(self: *@This(),
        comptime w: u8, comptime h: u8, comptime n: u16, 
        glyph_set: *const glyph.UnicodeGlyphDataset(w,h,n)
    ) !void {
        self._num_codepoints = @intCast(n);

        // allocate buffers
        self._device_codepoint_buf = try self.allocateMemBuffer(
            glyph_set.codepoints.len * @sizeOf(u32),
            .{ .transfer_dst_bit = true, .storage_buffer_bit = true },
            .{ .device_local_bit = true }
        );

        self._device_mask_buf = try self.allocateMemBuffer(
            glyph_set.masks.len * @sizeOf(glyph.GlyphMask(w,h)),
            .{ .transfer_dst_bit = true, .storage_buffer_bit = true },
            .{ .device_local_bit = true }
        );

        self._device_color_eqn_buf = try self.allocateMemBuffer(
            glyph_set.color_eqns.len * @sizeOf(glyph.ColorEqnParams),
            .{ .transfer_dst_bit = true, .storage_buffer_bit = true },
            .{ .device_local_bit = true }
        );

        // allocate the one descriptor set which will be used many times
        try self._device.allocateDescriptorSets(&.{
            .descriptor_pool = self._desc_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &[_]vk.DescriptorSetLayout{self._glyph_set_desc_layout},
        }, @ptrCast(&self._glyph_set_desc_set));

        // bind descriptors to buffers
        self._device.updateDescriptorSets(3, &[_]vk.WriteDescriptorSet{
            .{
                .dst_set = self._glyph_set_desc_set,
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_buffer_info = &[_]vk.DescriptorBufferInfo{.{
                    .buffer = self._device_codepoint_buf.buf,
                    .offset = 0,
                    .range = vk.WHOLE_SIZE,
                }},
                .p_image_info = &.{},
                .p_texel_buffer_view = &.{},
            },
            .{
                .dst_set = self._glyph_set_desc_set,
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_buffer_info = &[_]vk.DescriptorBufferInfo{.{
                    .buffer = self._device_mask_buf.buf,
                    .offset = 0,
                    .range = vk.WHOLE_SIZE,
                }},
                .p_image_info = &.{},
                .p_texel_buffer_view = &.{},
            },
            .{
                .dst_set = self._glyph_set_desc_set,
                .dst_binding = 2,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_buffer_info = &[_]vk.DescriptorBufferInfo{.{
                    .buffer = self._device_color_eqn_buf.buf,
                    .offset = 0,
                    .range = vk.WHOLE_SIZE,
                }},
                .p_image_info = &.{},
                .p_texel_buffer_view = &.{},
            },
        }, 0, &.{});

        // allocate buffer
        const staging_buffer = try self.allocateMemBuffer(
            self._num_codepoints * (@sizeOf(u32) + @sizeOf(glyph.GlyphMask(w,h)) + @sizeOf(glyph.ColorEqnParams)),
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true }
        );

        // map buffer to cpu pointer for memcpy
        const staging_mem_reqs = self._device.getBufferMemoryRequirements(staging_buffer.buf);
        const staging_ptr_raw: *anyopaque = try self._device.mapMemory(staging_buffer.mem, 0, staging_mem_reqs.size, .{})
            orelse return error.MapMemoryFailed;

        // cast raw to suitable types
        const staging_ptr_codepoints: [*]u32 = @ptrCast(@alignCast(staging_ptr_raw));
        const staging_ptr_masks: [*]glyph.GlyphMask(w,h) = @ptrCast(@alignCast(staging_ptr_codepoints + self._num_codepoints)); // offset is end of prev
        const staging_ptr_eqns: [*]glyph.ColorEqnParams = @ptrCast(@alignCast(staging_ptr_masks + self._num_codepoints)); // offset is end of prev

        // copy memory into staging buffer
        @memcpy(staging_ptr_codepoints[0..self._num_codepoints], glyph_set.codepoints[0..self._num_codepoints]);
        @memcpy(staging_ptr_masks[0..self._num_codepoints], glyph_set.masks[0..self._num_codepoints]);
        @memcpy(staging_ptr_eqns[0..self._num_codepoints], glyph_set.color_eqns[0..self._num_codepoints]);

        try self._device.allocateCommandBuffers(&.{
            .command_pool = self._cmd_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&self._glyph_set_upload_cmd_buf));

        try self._device.beginCommandBuffer(
            self._glyph_set_upload_cmd_buf,
            &.{ .flags = .{ .one_time_submit_bit = true } }
        );

        // copy codepoints
        self._device.cmdCopyBuffer(
            self._glyph_set_upload_cmd_buf,
            staging_buffer.buf,
            self._device_codepoint_buf.buf,
            1, &[_]vk.BufferCopy{.{
                .src_offset = 0,
                .dst_offset = 0,
                .size = self._device_codepoint_buf.size,
            }},
        );

        // copy masks
        self._device.cmdCopyBuffer(
            self._glyph_set_upload_cmd_buf,
            staging_buffer.buf,
            self._device_mask_buf.buf,
            1, &[_]vk.BufferCopy{.{
                .src_offset = self._device_codepoint_buf.size,
                .dst_offset = 0,
                .size = self._device_mask_buf.size,
            }},
        );

        // copy equation caches
        self._device.cmdCopyBuffer(
            self._glyph_set_upload_cmd_buf,
            staging_buffer.buf,
            self._device_color_eqn_buf.buf,
            1, &[_]vk.BufferCopy{.{
                .src_offset = self._device_codepoint_buf.size + self._device_mask_buf.size,
                .dst_offset = 0,
                .size = self._device_color_eqn_buf.size,
            }},
        );

        // done
        try self._device.endCommandBuffer(self._glyph_set_upload_cmd_buf);

        const fence = try self._device.createFence(&.{}, null);
        defer self._device.destroyFence(fence, null);

        // submit command
        try self._device.queueSubmit(
            self._queue,
            1, &[_]vk.SubmitInfo{.{
                .command_buffer_count = 1,
                .p_command_buffers = @ptrCast(&self._glyph_set_upload_cmd_buf),
            }},
            fence
        );

        // cost for waiting is minimal, simplifies logic later on with semaphores
        const timeout: u64 = 1_000_000_000; // 1 second
        _ = try self._device.waitForFences(1, &.{fence}, .true, timeout);
    }

    // Create and allocate a buffer and associated memory
    fn allocateMemBuffer(
        self: @This(),
        size: usize,
        usage: vk.BufferUsageFlags,
        mem_props: vk.MemoryPropertyFlags
    ) !MemBuffer {
        var mem_buf: MemBuffer = undefined;
        mem_buf.size = size;
        
        // create buffer
        mem_buf.buf = try self._device.createBuffer(&.{
            .size = size,
            .usage = usage,
            .sharing_mode = .exclusive,
        }, null);
        
        const mem_reqs = self._device.getBufferMemoryRequirements(mem_buf.buf);

        // find suitable memory type
        const mem_type = findMemoryType(
            self._mem_props,
            mem_reqs.memory_type_bits,
            mem_props
        ) orelse return error.NoSuitableMemory;

        // allocate memory
        mem_buf.mem = try self._device.allocateMemory(&.{
            .allocation_size = mem_reqs.size,
            .memory_type_index = mem_type,
        }, null);

        // bind buffer to memory w/ 0 offset
        try self._device.bindBufferMemory(mem_buf.buf, mem_buf.mem, 0);

        return mem_buf;
    }

    fn findMemoryType(
        mem_props: vk.PhysicalDeviceMemoryProperties,
        type_filter: u32,
        required_flags: vk.MemoryPropertyFlags,
    ) ?u32 {
        for (0..mem_props.memory_type_count) |i| {
            const type_bit = @as(u32, 1) << @intCast(i);
            const has_type = (type_filter & type_bit) != 0;
            const has_flags = mem_props.memory_types[i].property_flags.contains(required_flags);
            if (has_type and has_flags) return @intCast(i);
        }
        return null;
    }

    fn findComputeDevice(
        devices: []vk.PhysicalDevice,
        vki: *const vk.InstanceWrapper
    ) ?ComputeDeviceIndices {
        for (devices, 0..) |dev, i| {
            // get queue familites for device
            var queue_family_count: u32 = undefined;
            var queue_families: [16]vk.QueueFamilyProperties = undefined;
            vki.getPhysicalDeviceQueueFamilyProperties(dev, &queue_family_count, null);
            vki.getPhysicalDeviceQueueFamilyProperties(dev, &queue_family_count, &queue_families);

            // If device has compute queue family, return it
            const compute_queue_family = findComputeQueueFamily(queue_families[0..queue_family_count]);
            if (compute_queue_family) |qf| return .{ .dev_index = @intCast(i), .queue_fam_index = qf };
        }
        return null;
    }

    fn findComputeQueueFamily(families: []vk.QueueFamilyProperties) ?u32 {
        for (families, 0..) |props, i| {
            if (props.queue_flags.compute_bit) {
                return @intCast(i);
            }
        }
        return null;
    }

    fn createPipelineBuffers(self: *@This(), res: *PipelineResources, input_size: usize, output_size: usize) !void {
        // cpu-side input buffer to write to
        res.input_buf = try self.allocateMemBuffer(
            input_size,
            .{ .transfer_src_bit = true, },
            .{ .host_visible_bit = true, .host_coherent_bit = true }
        );

        // gpu-side input buffer that shaders can bind to
        res.device_input_buf = try self.allocateMemBuffer(
            input_size,
            .{ .transfer_dst_bit = true, .storage_buffer_bit = true },
            .{ .device_local_bit = true }
        );

        // gpu-side output buffer that shaders can bind to
        res.device_output_buf = try self.allocateMemBuffer(
            output_size,
            .{ .transfer_src_bit = true, .storage_buffer_bit = true },
            .{ .device_local_bit = true },
        );

        // cpu-side output buffer to read from
        res.output_buf = try self.allocateMemBuffer(
            output_size,
            .{ .transfer_dst_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true }
        );
    }

    fn createDescriptorSets(self: *@This(), res: *PipelineResources) !void {
        try self._device.allocateDescriptorSets(&.{
            .descriptor_pool = self._desc_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &[_]vk.DescriptorSetLayout{self._io_desc_layout},
        }, @ptrCast(&res.buf_io_desc_set));

        // bind I/O buffers to descriptor set
        self._device.updateDescriptorSets(2, &[_]vk.WriteDescriptorSet{
            .{
                .dst_set = res.buf_io_desc_set,
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_buffer_info = &[_]vk.DescriptorBufferInfo{.{
                    .buffer = res.device_input_buf.buf,
                    .offset = 0,
                    .range = vk.WHOLE_SIZE,
                }},
                .p_image_info = &.{},
                .p_texel_buffer_view = &.{},
            },
            .{
                .dst_set = res.buf_io_desc_set,
                .dst_binding = 1,
                .dst_array_element = 0,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_buffer_info = &[_]vk.DescriptorBufferInfo{.{
                    .buffer = res.device_output_buf.buf,
                    .offset = 0,
                    .range = vk.WHOLE_SIZE,
                }},
                .p_image_info = &.{},
                .p_texel_buffer_view = &.{},
            },
        }, 0, null);
    }

    // extern to conform to C ABI
    const PushConstants = extern struct {
        num_codepoints: u32,
        out_im_w: u32,
    };

    fn createPipelineCommandBuffer(self: *@This(), res: *PipelineResources, im_w: u32, im_h: u32) !void {
        // allocate buffer
        try self._device.allocateCommandBuffers(&.{
            .command_pool = self._cmd_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&res.cmd_buf));

        // record instructions
        try self._device.beginCommandBuffer(res.cmd_buf, &.{});

        // copy CPU to GPU
        self._device.cmdCopyBuffer(res.cmd_buf, res.input_buf.buf, res.device_input_buf.buf, 1, &[_]vk.BufferCopy{
            .{ .src_offset = 0, .dst_offset = 0, .size = res.input_buf.size }
        });

        // memory barrier to ensure write is complete before shader reads it
        self._device.cmdPipelineBarrier(
            res.cmd_buf,
            .{ .transfer_bit = true },
            .{ .compute_shader_bit = true },
            .{},
            0, null,
            1, &.{.{
                .src_access_mask = .{ .transfer_write_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .buffer = res.device_input_buf.buf,
                .offset = 0,
                .size = vk.WHOLE_SIZE,
            }},
            0, null
        );

        self._device.cmdBindPipeline(res.cmd_buf, .compute, res.compute_pipeline);

        // upload uniforms as push constants
        const push = PushConstants{
            .num_codepoints = self._num_codepoints,
            .out_im_w = im_w,
        };

        self._device.cmdPushConstants(
            res.cmd_buf,
            self._pipeline_layout,
            .{ .compute_bit = true },
            0,
            @sizeOf(PushConstants),
            @ptrCast(&push),
        );

        self._device.cmdBindDescriptorSets(
            res.cmd_buf,
            .compute,
            self._pipeline_layout,
            0, 2, &.{ self._glyph_set_desc_set, res.buf_io_desc_set },
            0, null
        );

        // Dispatch compute- local_size_x = 64 in glsl
        const work_group_size: u32 = 64;
        const num_work_groups = try std.math.divCeil(u32, im_w * im_h, work_group_size);
        self._device.cmdDispatch(res.cmd_buf, num_work_groups, 1, 1);

        // memory barrier to ensure compute is complete before readback to cpu
        self._device.cmdPipelineBarrier(
            res.cmd_buf,
            .{ .compute_shader_bit = true },
            .{ .transfer_bit = true },
            .{},
            0, null,
            1, &.{.{
                .src_access_mask = .{ .shader_write_bit = true },
                .dst_access_mask = .{ .transfer_read_bit = true },
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .buffer = res.device_output_buf.buf,
                .offset = 0,
                .size = vk.WHOLE_SIZE,
            }},
            0, null
        );

        // readback gpu - cpu
        self._device.cmdCopyBuffer(res.cmd_buf, res.device_output_buf.buf, res.output_buf.buf, 1, &[_]vk.BufferCopy{
            .{ .src_offset = 0, .dst_offset = 0, .size = res.output_buf.size }
        });

        try self._device.endCommandBuffer(res.cmd_buf);

        // create fence so cpu can wait on completion
        res.pipeline_complete = try self._device.createFence(&.{}, null);
    }

    fn createComputePipeline(self: *@This(), res: *PipelineResources) !void {
        // create shader module
        const shader_code = @embedFile("shaders/bin/compute_pixel.spv");
        const shader_module = try self._device.createShaderModule(&.{
            .code_size = shader_code.len,
            .p_code = @ptrCast(@alignCast(shader_code.ptr)),
        }, null);

        _ = try self._device.createComputePipelines(
            .null_handle,  // pipeline cache TODO: make caching optional, save to ~/.cache
            1, &[_]vk.ComputePipelineCreateInfo{.{
                .stage = .{
                    .stage = .{ .compute_bit = true },
                    .module = shader_module,
                    .p_name = "main",  // entry point
                },
                .layout = self._pipeline_layout,
                .base_pipeline_index = 0
            }},
            null,
            @ptrCast(&res.compute_pipeline),
        );
    }

    fn mapCpuBuffersToHandle(
        self: *@This(),
        res: *PipelineResources,
        input_surface: *[*]u8,
        output_surface: *[*]uni_im.UnicodePixelData
    ) !void {
        // map input
        const input_raw: *anyopaque = try self._device.mapMemory(res.input_buf.mem, 0, res.input_buf.size, .{})
            orelse return error.MapMemoryFailed;
        input_surface.* = @ptrCast(@alignCast(input_raw));

        // map output
        const output_raw: *anyopaque = try self._device.mapMemory(res.output_buf.mem, 0, res.output_buf.size, .{})
            orelse return error.MapMemoryFailed;
        output_surface.* = @ptrCast(@alignCast(output_raw));
    }

    fn destroyMemBuffer(self: @This(), buf: MemBuffer) void {
        self._device.destroyBuffer(buf.buf, null);
        self._device.freeMemory(buf.mem, null);
    }

    fn destroyPipelineResources(self: *@This(), res: *PipelineResources) void {
        // Unmap CPU buffers
        self._device.unmapMemory(res.input_buf.mem);
        self._device.unmapMemory(res.output_buf.mem);

        // Destroy buffers
        self.destroyMemBuffer(res.input_buf);
        self.destroyMemBuffer(res.device_input_buf);
        self.destroyMemBuffer(res.device_output_buf);
        self.destroyMemBuffer(res.output_buf);

        // Destroy pipeline and fence
        self._device.destroyPipeline(res.compute_pipeline, null);
        self._device.destroyFence(res.pipeline_complete, null);

        // Note: descriptor sets and command buffers are pool-allocated,
        // they get freed when the pools are destroyed in deinit()
    }
};

// Link Vulkan functions
extern "vulkan" fn vkGetInstanceProcAddr(
    instance: vk.Instance,
    p_name: [*:0]const u8,
) vk.PfnVoidFunction;

