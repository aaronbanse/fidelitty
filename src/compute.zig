const std = @import("std");

const vk = @import("vulkan");

const gen_config = @import("gen_config");
const config = @import("config");

const glyph = @import("glyph.zig");

pub const PixelFormat = enum(u8) {
    rgb = 0, // 3 bytes/pixel, channel order: R G B
    bgra = 1, // 4 bytes/pixel, channel order: B G R A (alpha ignored)

    pub fn bpp(self: @This()) u8 {
        return switch (self) {
            .rgb => 3,
            .bgra => 4,
        };
    }

    /// Channel indices for swizzling to RGB order.
    /// e.g. BGRA layout [B,G,R,A] needs swizzle [2,1,0] to read R,G,B.
    pub fn swizzle(self: @This()) [3]i32 {
        return switch (self) {
            .rgb => .{ 0, 1, 2 },
            .bgra => .{ 2, 1, 0 },
        };
    }
};

/// Output of the pipeline for each terminal cell.
/// Encodes the foreground / background colors and the codepoint.
/// Fg / bg colors can be set with escape sequences in most modern terminals.
pub const UnicodePixelData = extern struct {
    br: u8,
    bg: u8,
    bb: u8,
    fr: u8,
    fg: u8,
    fb: u8,
    _pad: u16,
    codepoint: u32,
};

/// Non-owning handle to a render pipeline managed by compute context
pub const PipelineHandle = struct {
    grid_w: u16,
    grid_h: u16,

    input_surface: [*]u8,
    output_surface: [*]UnicodePixelData,

    pixel_format: PixelFormat,
    im_patch_w: u8, // input-image pixels per cell, horizontally
    im_patch_h: u8, // input-image pixels per cell, vertically

    _id: Context.HandleID,

    pub fn inputDims(self: @This()) struct { w: u32, h: u32 } {
        return .{
            .w = @as(u32, self.grid_w) * @as(u32, self.im_patch_w),
            .h = @as(u32, self.grid_h) * @as(u32, self.im_patch_h),
        };
    }
};

/// Context for managing compute pipelines
pub const Context = struct {
    pub const HandleID = usize;

    const MemBuffer = struct {
        buf: vk.Buffer,
        mem: vk.DeviceMemory,
        size: usize,
    };

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

    _io_desc_layout: vk.DescriptorSetLayout,
    _glyph_set_desc_layout: vk.DescriptorSetLayout,
    _pipeline_layout: vk.PipelineLayout,

    _physical_device: vk.PhysicalDevice,
    _mem_props: vk.PhysicalDeviceMemoryProperties,

    _pipelines: std.AutoHashMap(HandleID, PipelineResources),
    _max_pipelines: u8,

    _device_codepoint_buf: MemBuffer,
    _device_mask_buf: MemBuffer,
    _device_color_eqn_buf: MemBuffer,
    _num_codepoints: u32,

    _cell_w: u8,
    _cell_h: u8,

    _glyph_set_upload_cmd_buf: vk.CommandBuffer,

    _glyph_set_desc_set: vk.DescriptorSet,

    // TODO: heap allocate these to prevent pointers to stack vars
    // Vulkan convenience wrappers
    _vkb: vk.BaseWrapper,
    _vki: vk.InstanceWrapper,
    _vkd: vk.DeviceWrapper,
    _instance: vk.InstanceProxy,
    _device: vk.DeviceProxy,
    _queue: vk.Queue,
    _cmd_pool: vk.CommandPool,
    _desc_pool: vk.DescriptorPool,

    /// Initialize a standalone vulkan context and setup machinery
    pub fn init(self: *@This(), allocator: std.mem.Allocator, max_pipelines: u8) !void {
        self._pipelines = .init(allocator);
        self._max_pipelines = max_pipelines;
        self._cell_w = config.cell_w;
        self._cell_h = config.cell_h;
        self.loadBase();
        try self.createInstance();
        const compute_device_indices = try self.createDevice();
        self.createQueue(compute_device_indices.queue_fam_index);
        try self.createCommandPool(compute_device_indices.queue_fam_index);
        try self.createDescriptorPool(max_pipelines);
        try self.createLayouts();

        // load glyph dataset to gpu
        const Dataset = glyph.UnicodeGlyphDataset(
            config.cell_w,
            config.cell_h,
        );
        var dataset: Dataset = .init();

        try self.createGlyphSet(
            config.cell_w,
            config.cell_h,
            &dataset,
        );
    }

    pub fn deinit(self: *@This()) void {
        self._device.deviceWaitIdle() catch {};

        var iter = self._pipelines.iterator();
        while (iter.next()) |entry| {
            self.destroyPipelineResources(entry.value_ptr);
        }
        self._pipelines.deinit();

        self.destroyMemBuffer(self._device_codepoint_buf);
        self.destroyMemBuffer(self._device_mask_buf);
        self.destroyMemBuffer(self._device_color_eqn_buf);

        self._device.destroyPipelineLayout(self._pipeline_layout, null);
        self._device.destroyDescriptorSetLayout(self._io_desc_layout, null);
        self._device.destroyDescriptorSetLayout(self._glyph_set_desc_layout, null);

        self._device.destroyDescriptorPool(self._desc_pool, null);
        self._device.destroyCommandPool(self._cmd_pool, null);

        self._device.destroyDevice(null);
        self._instance.destroyInstance(null);
    }

    fn computeInputSize(grid_w: u16, grid_h: u16, pixel_format: PixelFormat, im_patch_w: u8, im_patch_h: u8) usize {
        const bpp: usize = pixel_format.bpp();
        return bpp * @as(usize, grid_w) * @as(usize, im_patch_w) * @as(usize, grid_h) * @as(usize, im_patch_h);
    }

    pub fn createRenderPipeline(
        self: *@This(),
        grid_w: u16,
        grid_h: u16,
    ) !PipelineHandle {
        return self.createRenderPipelineEx(grid_w, grid_h, .rgb, self._cell_w, self._cell_h);
    }

    pub fn createRenderPipelineEx(
        self: *@This(),
        grid_w: u16,
        grid_h: u16,
        pixel_format: PixelFormat,
        im_patch_w: u8,
        im_patch_h: u8,
    ) !PipelineHandle {
        const input_size = computeInputSize(grid_w, grid_h, pixel_format, im_patch_w, im_patch_h);
        const output_size = @as(usize, grid_w) * @as(usize, grid_h) * @sizeOf(UnicodePixelData);

        var resources: PipelineResources = undefined;
        try self.createPipelineBuffers(&resources, input_size, output_size);

        try self.createDescriptorSets(&resources);

        var handle: PipelineHandle = .{
            .grid_w = grid_w,
            .grid_h = grid_h,
            .input_surface = undefined,
            .output_surface = undefined,
            ._id = undefined,
            .pixel_format = pixel_format,
            .im_patch_w = im_patch_w,
            .im_patch_h = im_patch_h,
        };
        try self.mapCpuBuffersToHandle(&resources, &handle.input_surface, &handle.output_surface);

        try self.createComputePipeline(&resources);

        try self.allocatePipelineCommandResources(&resources);

        var id: usize = 1;
        while (self._pipelines.contains(id)) : (id += 1) {}
        handle._id = id;

        try self._pipelines.put(id, resources);

        return handle;
    }

    pub fn executeRenderPipeline(self: *@This(), handle: PipelineHandle) !void {
        return self.executeRenderPipelineRegion(handle, 0, 0, handle.grid_w, handle.grid_h);
    }

    pub fn executeRenderPipelineRegion(
        self: *@This(),
        handle: PipelineHandle,
        dispatch_x: u16,
        dispatch_y: u16,
        dispatch_w: u16,
        dispatch_h: u16,
    ) !void {
        const res: PipelineResources = self._pipelines.get(handle._id) orelse return error.InvalidPipelineHandle;

        try self.recordPipelineCommandBuffer(
            res,
            handle,
            dispatch_x,
            dispatch_y,
            dispatch_w,
            dispatch_h,
        );

        try self._device.resetFences(&.{res.pipeline_complete});

        try self._device.queueSubmit(
            self._queue,
            &[_]vk.SubmitInfo{.{
                .command_buffer_count = 1,
                .p_command_buffers = @ptrCast(&res.cmd_buf),
                .p_wait_dst_stage_mask = &[_]vk.PipelineStageFlags{.{ .compute_shader_bit = true }},
            }},
            res.pipeline_complete,
        );
    }

    pub fn waitRenderPipeline(self: @This(), handle: PipelineHandle) !void {
        const timeout: u64 = 1_000_000_000; // 1 second
        const res = self._pipelines.get(handle._id) orelse return error.InvalidPipelineHandle;
        _ = try self._device.waitForFences(&.{res.pipeline_complete}, .true, timeout);
    }

    pub fn resizeRenderPipeline(self: *@This(), handle: *PipelineHandle, new_grid_w: u16, new_grid_h: u16) !void {
        const res = self._pipelines.getPtr(handle._id) orelse return error.InvalidPipelineHandle;

        try self.waitRenderPipeline(handle.*);

        const new_input_size = computeInputSize(new_grid_w, new_grid_h, handle.pixel_format, handle.im_patch_w, handle.im_patch_h);
        const new_output_size = @as(usize, new_grid_w) * @as(usize, new_grid_h) * @sizeOf(UnicodePixelData);

        self._device.unmapMemory(res.input_buf.mem);
        self._device.unmapMemory(res.output_buf.mem);

        self.destroyMemBuffer(res.input_buf);
        self.destroyMemBuffer(res.device_input_buf);
        self.destroyMemBuffer(res.device_output_buf);
        self.destroyMemBuffer(res.output_buf);

        self._device.freeCommandBuffers(self._cmd_pool, &.{res.cmd_buf});
        self._device.destroyFence(res.pipeline_complete, null);

        try self.createPipelineBuffers(res, new_input_size, new_output_size);

        self._device.updateDescriptorSets(&[_]vk.WriteDescriptorSet{
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
        }, &.{});

        try self.mapCpuBuffersToHandle(res, &handle.input_surface, &handle.output_surface);

        try self.allocatePipelineCommandResources(res);

        handle.grid_w = new_grid_w;
        handle.grid_h = new_grid_h;
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

    fn loadBase(self: *@This()) void {
        self._vkb = vk.BaseWrapper.load(vkGetInstanceProcAddr);
    }

    fn createInstance(self: *@This()) !void {
        const instance_handle = try self._vkb.createInstance(&.{
            .p_application_info = &.{
                .api_version = @bitCast(vk.makeApiVersion(0, 1, 4, 328)),
                // ignore =========
                .engine_version = 0,
                .application_version = 0,
                // ================
            },
        }, null);
        self._vki = vk.InstanceWrapper.load(instance_handle, self._vkb.dispatch.vkGetInstanceProcAddr.?);
        self._instance = vk.InstanceProxy.init(instance_handle, &self._vki);
    }

    const ComputeDeviceIndices = struct { dev_index: u32, queue_fam_index: u32 };

    fn createDevice(self: *@This()) !ComputeDeviceIndices {
        // find compute-capable device
        var num_devices: u32 = undefined;
        var devices: [16]vk.PhysicalDevice = undefined;
        _ = try self._instance.enumeratePhysicalDevices(&num_devices, &devices);
        const compute_device_found = findComputeDevice(devices[0..num_devices], &self._vki);
        const compute_indices = compute_device_found orelse return error.NoComputeCapableDevice;

        self._physical_device = devices[compute_indices.dev_index];
        self._mem_props = self._instance.getPhysicalDeviceMemoryProperties(self._physical_device);

        // create device with features required by the Zig SPIR-V compute kernel
        const queue_priority: f32 = 1.0;
        var vk12_features: vk.PhysicalDeviceVulkan12Features = .{
            .shader_int_8 = .true,
            .buffer_device_address = .true,
        };
        const device_handle = try self._vki.createDevice(self._physical_device, &.{
            .p_next = @ptrCast(&vk12_features),
            .queue_create_info_count = 1,
            .p_queue_create_infos = &[_]vk.DeviceQueueCreateInfo{.{
                .queue_family_index = compute_indices.queue_fam_index,
                .queue_count = 1,
                .p_queue_priorities = @ptrCast(&queue_priority),
            }},
            .p_enabled_features = &.{
                .shader_int_64 = .true,
                .shader_int_16 = .true,
            },
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
            .flags = .{ .reset_command_buffer_bit = true },
        }, null);
    }

    fn createDescriptorPool(self: *@This(), max_pipelines: u8) !void {
        self._desc_pool = try self._device.createDescriptorPool(&.{
            .max_sets = 1 + max_pipelines, // 1 for static data, 1 for each pipeline
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

        self._pipeline_layout = try self._device.createPipelineLayout(&.{
            .set_layout_count = 2,
            .p_set_layouts = &[_]vk.DescriptorSetLayout{ self._glyph_set_desc_layout, self._io_desc_layout },
            .push_constant_range_count = 1,
            .p_push_constant_ranges = &[_]vk.PushConstantRange{.{
                .stage_flags = .{ .compute_bit = true },
                .offset = 0,
                .size = @sizeOf(PushConstants),
            }},
        }, null);
    }

    fn createGlyphSet(
        self: *@This(),
        comptime cell_w: u8,
        comptime cell_h: u8,
        glyph_set: *const glyph.UnicodeGlyphDataset(cell_w, cell_h),
    ) !void {
        self._num_codepoints = glyph.UnicodeGlyphDataset(cell_w, cell_h).numCodepoints();

        self._device_codepoint_buf = try self.allocateMemBuffer(
            glyph_set.codepoints.len * @sizeOf(u32),
            .{ .transfer_dst_bit = true, .storage_buffer_bit = true },
            .{ .device_local_bit = true },
        );
        self._device_mask_buf = try self.allocateMemBuffer(
            glyph_set.masks.len * @sizeOf(glyph.GlyphMask(cell_w, cell_h)),
            .{ .transfer_dst_bit = true, .storage_buffer_bit = true },
            .{ .device_local_bit = true },
        );
        self._device_color_eqn_buf = try self.allocateMemBuffer(
            glyph_set.color_eqns.len * @sizeOf(glyph.ColorEqnCache),
            .{ .transfer_dst_bit = true, .storage_buffer_bit = true },
            .{ .device_local_bit = true },
        );

        try self._device.allocateDescriptorSets(&.{
            .descriptor_pool = self._desc_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &[_]vk.DescriptorSetLayout{self._glyph_set_desc_layout},
        }, @ptrCast(&self._glyph_set_desc_set));

        self._device.updateDescriptorSets(&[_]vk.WriteDescriptorSet{
            .{
                .dst_set = self._glyph_set_desc_set,
                .dst_binding = 0,
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
                .dst_binding = 1,
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
        }, &.{});

        // Coalesce all 3 buffers in the dataset into one staging buffer and push to the gpu

        const staging_buffer = try self.allocateMemBuffer(
            self._num_codepoints * (@sizeOf(u32) + @sizeOf(glyph.GlyphMask(cell_w, cell_h)) + @sizeOf(glyph.ColorEqnCache)),
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );

        const staging_mem_reqs = self._device.getBufferMemoryRequirements(staging_buffer.buf);
        const staging_ptr_raw: *anyopaque = try self._device.mapMemory(
            staging_buffer.mem,
            0,
            staging_mem_reqs.size,
            .{},
        ) orelse return error.MapMemoryFailed;

        // NOTE: staging ptr masks is placed first, since it has very strict alignment requirements.
        const staging_ptr_masks: [*]glyph.GlyphMask(cell_w, cell_h) = @ptrCast(@alignCast(staging_ptr_raw));
        const staging_ptr_codepoints: [*]u32 = @ptrCast(@alignCast(staging_ptr_masks + self._num_codepoints));
        const staging_ptr_eqns: [*]glyph.ColorEqnCache = @ptrCast(@alignCast(staging_ptr_codepoints + self._num_codepoints));

        @memcpy(staging_ptr_masks[0..self._num_codepoints], glyph_set.masks[0..self._num_codepoints]);
        @memcpy(staging_ptr_codepoints[0..self._num_codepoints], glyph_set.codepoints[0..self._num_codepoints]);
        @memcpy(staging_ptr_eqns[0..self._num_codepoints], glyph_set.color_eqns[0..self._num_codepoints]);

        try self._device.allocateCommandBuffers(&.{
            .command_pool = self._cmd_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&self._glyph_set_upload_cmd_buf));

        try self._device.beginCommandBuffer(self._glyph_set_upload_cmd_buf, &.{ .flags = .{ .one_time_submit_bit = true } });

        self._device.cmdCopyBuffer(
            self._glyph_set_upload_cmd_buf,
            staging_buffer.buf,
            self._device_mask_buf.buf,
            &[_]vk.BufferCopy{.{
                .src_offset = 0,
                .dst_offset = 0,
                .size = self._device_mask_buf.size,
            }},
        );

        self._device.cmdCopyBuffer(
            self._glyph_set_upload_cmd_buf,
            staging_buffer.buf,
            self._device_codepoint_buf.buf,
            &[_]vk.BufferCopy{.{
                .src_offset = self._device_mask_buf.size,
                .dst_offset = 0,
                .size = self._device_codepoint_buf.size,
            }},
        );

        self._device.cmdCopyBuffer(
            self._glyph_set_upload_cmd_buf,
            staging_buffer.buf,
            self._device_color_eqn_buf.buf,
            &[_]vk.BufferCopy{.{
                .src_offset = self._device_mask_buf.size + self._device_codepoint_buf.size,
                .dst_offset = 0,
                .size = self._device_color_eqn_buf.size,
            }},
        );

        try self._device.endCommandBuffer(self._glyph_set_upload_cmd_buf);

        const fence = try self._device.createFence(&.{}, null);
        defer self._device.destroyFence(fence, null);

        try self._device.queueSubmit(self._queue, &[_]vk.SubmitInfo{.{
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&self._glyph_set_upload_cmd_buf),
        }}, fence);

        const timeout: u64 = 100_000_000; // 100 milliseconds
        _ = try self._device.waitForFences(&.{fence}, .true, timeout);
    }

    fn allocateMemBuffer(
        self: @This(),
        size: usize,
        usage: vk.BufferUsageFlags,
        mem_props: vk.MemoryPropertyFlags,
    ) !MemBuffer {
        var mem_buf: MemBuffer = undefined;
        mem_buf.size = size;

        mem_buf.buf = try self._device.createBuffer(&.{
            .size = size,
            .usage = usage,
            .sharing_mode = .exclusive,
        }, null);

        const mem_reqs = self._device.getBufferMemoryRequirements(mem_buf.buf);

        const mem_type = findMemoryType(
            self._mem_props,
            mem_reqs.memory_type_bits,
            mem_props,
        ) orelse return error.NoSuitableMemory;

        mem_buf.mem = try self._device.allocateMemory(&.{
            .allocation_size = mem_reqs.size,
            .memory_type_index = mem_type,
        }, null);

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

    fn findComputeDevice(devices: []vk.PhysicalDevice, vki: *const vk.InstanceWrapper) ?ComputeDeviceIndices {
        for (devices, 0..) |dev, i| {
            var queue_family_count: u32 = undefined;
            var queue_families: [16]vk.QueueFamilyProperties = undefined;
            vki.getPhysicalDeviceQueueFamilyProperties(dev, &queue_family_count, null);
            vki.getPhysicalDeviceQueueFamilyProperties(dev, &queue_family_count, &queue_families);

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
        res.input_buf = try self.allocateMemBuffer(
            input_size,
            .{ .transfer_src_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
        res.device_input_buf = try self.allocateMemBuffer(
            input_size,
            .{ .transfer_dst_bit = true, .storage_buffer_bit = true },
            .{ .device_local_bit = true },
        );
        res.device_output_buf = try self.allocateMemBuffer(
            output_size,
            .{ .transfer_src_bit = true, .storage_buffer_bit = true },
            .{ .device_local_bit = true },
        );
        res.output_buf = try self.allocateMemBuffer(
            output_size,
            .{ .transfer_dst_bit = true },
            .{ .host_visible_bit = true, .host_coherent_bit = true },
        );
    }

    fn createDescriptorSets(self: *@This(), res: *PipelineResources) !void {
        try self._device.allocateDescriptorSets(&.{
            .descriptor_pool = self._desc_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &[_]vk.DescriptorSetLayout{self._io_desc_layout},
        }, @ptrCast(&res.buf_io_desc_set));

        self._device.updateDescriptorSets(&[_]vk.WriteDescriptorSet{
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
        }, &.{});
    }

    const PushConstants = extern struct {
        num_codepoints: u32,
        grid_w: u32,
        dispatch_x: u32,
        dispatch_y: u32,
        dispatch_w: u32,
        dispatch_h: u32,
        input_bpp: u32,
        _pad: u32,
        swizzle: [3]i32,
        im_patch_w: u32,
        im_patch_h: u32,
        cell_w: u32,
        cell_h: u32,
    };

    fn allocatePipelineCommandResources(self: *@This(), res: *PipelineResources) !void {
        try self._device.allocateCommandBuffers(&.{
            .command_pool = self._cmd_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&res.cmd_buf));

        res.pipeline_complete = try self._device.createFence(&.{}, null);
    }

    fn recordPipelineCommandBuffer(
        self: *@This(),
        res: PipelineResources,
        handle: PipelineHandle,
        dispatch_x: u32,
        dispatch_y: u32,
        dispatch_w: u32,
        dispatch_h: u32,
    ) !void {
        try self._device.resetCommandBuffer(res.cmd_buf, .{});
        try self._device.beginCommandBuffer(res.cmd_buf, &.{});

        // copy CPU to GPU
        self._device.cmdCopyBuffer(
            res.cmd_buf,
            res.input_buf.buf,
            res.device_input_buf.buf,
            &[_]vk.BufferCopy{.{
                .src_offset = 0,
                .dst_offset = 0,
                .size = res.input_buf.size,
            }},
        );

        // memory barrier to ensure write is complete before shader reads it
        self._device.cmdPipelineBarrier(
            res.cmd_buf,
            .{ .transfer_bit = true },
            .{ .compute_shader_bit = true },
            .{},
            null,
            &.{.{
                .src_access_mask = .{ .transfer_write_bit = true },
                .dst_access_mask = .{ .shader_read_bit = true },
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .buffer = res.device_input_buf.buf,
                .offset = 0,
                .size = vk.WHOLE_SIZE,
            }},
            null,
        );

        self._device.cmdBindPipeline(res.cmd_buf, .compute, res.compute_pipeline);

        // upload uniforms as push constants
        const push = PushConstants{
            .num_codepoints = self._num_codepoints,
            .grid_w = handle.grid_w,
            .dispatch_x = dispatch_x,
            .dispatch_y = dispatch_y,
            .dispatch_w = dispatch_w,
            .dispatch_h = dispatch_h,
            .input_bpp = handle.pixel_format.bpp(),
            ._pad = 0,
            .swizzle = handle.pixel_format.swizzle(),
            .im_patch_w = handle.im_patch_w,
            .im_patch_h = handle.im_patch_h,
            .cell_w = self._cell_w,
            .cell_h = self._cell_h,
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
            0,
            &.{ self._glyph_set_desc_set, res.buf_io_desc_set },
            null,
        );

        const work_group_size: u32 = 64;
        const num_work_groups = try std.math.divCeil(u32, dispatch_w * dispatch_h, work_group_size);
        self._device.cmdDispatch(res.cmd_buf, num_work_groups, 1, 1);

        self._device.cmdPipelineBarrier(
            res.cmd_buf,
            .{ .compute_shader_bit = true },
            .{ .transfer_bit = true },
            .{},
            null,
            &.{.{
                .src_access_mask = .{ .shader_write_bit = true },
                .dst_access_mask = .{ .transfer_read_bit = true },
                .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
                .buffer = res.device_output_buf.buf,
                .offset = 0,
                .size = vk.WHOLE_SIZE,
            }},
            null,
        );

        self._device.cmdCopyBuffer(
            res.cmd_buf,
            res.device_output_buf.buf,
            res.output_buf.buf,
            &[_]vk.BufferCopy{.{ .src_offset = 0, .dst_offset = 0, .size = res.output_buf.size }},
        );

        try self._device.endCommandBuffer(res.cmd_buf);
    }

    fn createComputePipeline(self: *@This(), res: *PipelineResources) !void {
        const shader_code = @embedFile("compute_pixel_spv");
        const shader_module = try self._device.createShaderModule(&.{
            .code_size = shader_code.len,
            .p_code = @ptrCast(@alignCast(shader_code.ptr)),
        }, null);

        var pipelines: [1]vk.Pipeline = undefined;
        _ = try self._device.createComputePipelines(
            .null_handle, // pipeline cache TODO: make caching optional, save to ~/.cache
            &[_]vk.ComputePipelineCreateInfo{.{
                .stage = .{
                    .stage = .{ .compute_bit = true },
                    .module = shader_module,
                    .p_name = "main", // entry point
                },
                .layout = self._pipeline_layout,
                .base_pipeline_index = 0,
            }},
            null,
            &pipelines,
        );
        res.compute_pipeline = pipelines[0];
    }

    fn mapCpuBuffersToHandle(
        self: *@This(),
        res: *PipelineResources,
        input_surface: *[*]u8,
        output_surface: *[*]UnicodePixelData,
    ) !void {
        const input_raw: *anyopaque = try self._device.mapMemory(
            res.input_buf.mem,
            0,
            res.input_buf.size,
            .{},
        ) orelse return error.MapMemoryFailed;
        input_surface.* = @ptrCast(@alignCast(input_raw));

        const output_raw: *anyopaque = try self._device.mapMemory(
            res.output_buf.mem,
            0,
            res.output_buf.size,
            .{},
        ) orelse return error.MapMemoryFailed;
        output_surface.* = @ptrCast(@alignCast(output_raw));
    }

    fn destroyMemBuffer(self: @This(), buf: MemBuffer) void {
        self._device.destroyBuffer(buf.buf, null);
        self._device.freeMemory(buf.mem, null);
    }

    fn destroyPipelineResources(self: *@This(), res: *PipelineResources) void {
        self._device.unmapMemory(res.input_buf.mem);
        self._device.unmapMemory(res.output_buf.mem);

        self.destroyMemBuffer(res.input_buf);
        self.destroyMemBuffer(res.device_input_buf);
        self.destroyMemBuffer(res.device_output_buf);
        self.destroyMemBuffer(res.output_buf);

        self._device.destroyPipeline(res.compute_pipeline, null);
        self._device.destroyFence(res.pipeline_complete, null);
    }
};

// Necessary to link Vulkan functions
extern "vulkan" fn vkGetInstanceProcAddr(
    instance: vk.Instance,
    p_name: [*:0]const u8,
) vk.PfnVoidFunction;
