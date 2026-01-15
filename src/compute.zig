const std = @import("std");
const mem = std.mem;

const vk = @import("vulkan");

const uni_im = @import("unicode_image.zig");
const glyph = @import("glyph.zig");

/// Non-owning handle to a render pipeline managed by compute context
pub const PipelineHandle = struct {
    // dimensions of output image in unicode pixels
    out_im_w: u16,
    out_im_h: u16,
    // dimensions of each unicode pixel in virtual pixels- reasonable value for most cases is 4,4
    pix_w: u8,
    pix_h: u8,
    // input_surface_w = out_im_w * pix_w
    // input_surface_h = out_im_h * pix_h
    input_surface: [*]u8, // write to this
    output_surface: [*]uni_im.UnicodePixelData, // read from this
    // TODO: consider making above a UnicodeImage, compute shaders would need to write chars directly

    _id: Context.HandleID, // Internal: unique id to tie to vulkan resources

    pub fn inputDims(self: @This()) struct { w: u32, h: u32 } {
        return .{
            .w = @as(u32, self.out_im_w) * @as(u32, self.pix_w),
            .h = @as(u32, self.out_im_h) * @as(u32, self.pix_h),
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
    const PipelineResources = struct {
        input_buf: vk.Buffer,
        input_mem: vk.DeviceMemory,

        device_input_buf: vk.Buffer,
        device_input_mem: vk.DeviceMemory,

        device_output_buf: vk.Buffer,
        device_output_mem: vk.DeviceMemory,

        output_buf: vk.Buffer,
        output_mem: vk.DeviceMemory,

        cmd_buf: vk.CommandBuffer,

        compute_pipeline: vk.Pipeline,
        buf_io_desc_layout: vk.DescriptorSetLayout,
        buf_io_desc_set: vk.DescriptorSet,
    };

    // store active pipelines
    _pipelines: std.AutoHashMap(HandleID, PipelineResources),
    
    // pipeline globals - glyph set and associated descriptor set
    _glyph_set_buf: vk.Buffer,
    _glyph_set_desc_layout: vk.DescriptorSetLayout,
    _glyph_set_desc_set: vk.DescriptorSet,

    // dispatch tables
    _vkb: vk.BaseWrapper,
    _vki: vk.InstanceWrapper,
    _vkd: vk.DeviceWrapper,
    
    // physical device info
    _physical_device: vk.PhysicalDevice,
    _mem_props: vk.PhysicalDeviceMemoryProperties,

    _instance: vk.InstanceProxy,
    _device: vk.DeviceProxy,
    _queue: vk.Queue,
    _cmd_pool: vk.CommandPool,
    _desc_pool: vk.DescriptorPool,


    // PUBLIC API
    // ---------------------------

    // Did we create this context or did we derive it from an existing vulkan instance
    context_ownership: ContextOwnershipMode,

    pub fn init(self: *@This(), allocator: mem.Allocator) !void {
        self.context_ownership = .Owned;
        self._pipelines = .init(allocator);
        self.loadBase();
        try self.loadInstance();
        const compute_device_indices = try self.loadDevice();
        self.loadQueue(compute_device_indices.queue_fam_index);
        try self.loadCommandPool(compute_device_indices.queue_fam_index);
    }

    pub fn initFromExisting(self: *@This(), allocator: mem.Allocator) !void {
        self.context_ownership = .Borrowed;
        self._pipelines = .init(allocator);
        // TODO: implement
    }

    pub fn deinit(self: *@This()) void {
        self._pipelines.deinit();
        // if owned, deinit everything, if borrowed, deinit pipelines and buffers only
        // TODO: implement
    }

    // Context manages memory

    pub fn createRenderPipeline(
        self: *@This(),
        im_w: u16,
        im_h: u16,
        pix_w: u8,
        pix_h: u8
    ) !PipelineHandle {
        const input_size = @as(usize, im_w) * @as(usize, im_h) * @as(usize, pix_w) * @as(usize, pix_h) * @sizeOf(u8);
        const output_size = @as(usize, im_w) * @as(usize, im_h) * @sizeOf(uni_im.UnicodePixelData);

        // initialize resources
        var resources: PipelineResources = undefined;
        try self.createPipelineBuffers(&resources, input_size, output_size);

        // allocate memory for resources
        try self.allocatePipelineBuffers(&resources);

        // create handle mapped to input / output buffers
        var handle: PipelineHandle = .{
            .out_im_w = im_w,
            .out_im_h = im_h,
            .pix_w = pix_w,
            .pix_h = pix_h,
        };
        // map handle to input / output buffers
        try self.mapCpuBuffersToHandle(&resources, &handle.input_surface, &handle.output_surface);

        // obtain unique id for handle
        var id: usize = 1;
        while (self._pipelines.contains(id)) : (id += 1) {}
        handle._id = id;

        // add pipeline to registry
        try self._pipelines.put(id, resources);
        
        return handle;
    }

    // TODO: implement these
    // pub fn resizeRenderPipeline(self: *@This(), render_pipeline: *PipelineHandle, im_w: u16, im_h: u16, pix_w: u8, pix_h: u8) !void {
    //
    // }

    // pub fn destroyRenderPipeline(self: *@This(), render_pipeline: *PipelineHandle) void {
    //
    // }

    // INTERNAL
    // ---------------------------
    fn loadBase(self: *@This()) void {
        self._vkb = vk.BaseWrapper.load(vkGetInstanceProcAddr);
    }

    fn loadInstance(self: *@This()) !void {
        const instance_handle = try self._vkb.createInstance(&.{
            .p_application_info = &.{
                .api_version = vk.makeApiVersion(0, 1, 3, 0),
            },
        }, null);
        self._vki = vk.InstanceWrapper.load(instance_handle, self._vkb.dispatch.vkGetInstanceProcAddr.?);
        self._instance = Instance.init(instance_handle, &self._vki);
    }

    const ComputeDeviceIndices = struct {
        dev_index: u32,
        queue_fam_index: u32
    };

    fn loadDevice(self: *@This()) !ComputeDeviceIndices {
        // find compute-capable device
        var num_devices: u32 = undefined;
        var devices: [16]vk.PhysicalDevice = undefined;
        _ = try self._instance.enumeratePhysicalDevices(&num_devices, &devices);
        const compute_device_found = findComputeDevice(devices[0..num_devices], &self._vki);
        const compute_indices = compute_device_found orelse return error.NoComputeCapableDevice;

        // save physical device info
        self._physical_device = devices[compute_indices.dev_index];
        self._mem_props = self._instance.getPhysicalDeviceProperties(self._physical_device);

        // create device
        const queue_priority: f32 = 1.0;
        const device_handle = try self._vki.createDevice(self._physical_device, &.{
            .queue_create_info_count = 1,
            .p_queue_create_infos = &[_]vk.DeviceQueueCreateInfo{.{
                .queue_family_index = compute_indices.queue_fam_index,
                .queue_count = 1,
                .p_queue_priorities = &queue_priority,
            }},
        }, null);
        self._vkd = vk.DeviceWrapper.load(device_handle, self._vki.dispatch.vkGetDeviceProcAddr.?);
        self._device = Device.init(device_handle, &self._vkd);

        return compute_indices;
    }

    fn loadQueue(self: *@This(), compute_queue_fam_index: u32) void {
        self._queue = self._device.getDeviceQueue(compute_queue_fam_index, 0);
    }

    fn loadCommandPool(self: *@This(), compute_queue_fam_index: u32) !void {
        self._cmd_pool = try self._device.createCommandPool(&.{
            .queue_family_index = compute_queue_fam_index,
            .flags = .{},
        }, null);
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
        res.input_buf = try self._device.createBuffer(&.{
            .size = input_size,
            .usage = .{ .transfer_src_bit = true, },
            .sharing_mode = .exclusive,
        }, null);

        // gpu-side input buffer that shaders can bind to
        res.device_input_buf = try self._device.createBuffer(&.{
            .size = input_size,
            .usage = .{ .transfer_dst_bit = true, .storage_buffer_bit = true },
            .sharing_mode = .exclusive,
        }, null);

        // gpu-side output buffer that shaders can bind to
        res.device_output_buf = try self._device.createBuffer(&.{
            .size = output_size,
            .usage = .{ .transfer_src_bit = true, .storage_buffer_bit = true },
            .sharing_mode = .exclusive,
        }, null);

        // cpu-side output buffer to read from
        res.output_buf = try self._device.createBuffer(&.{
            .size = output_size,
            .usage = .{ .transfer_dst_bit = true },
            .sharing_mode = .exclusive,
        }, null);
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

    fn allocatePipelineBuffers(self: *@This(), res: *PipelineResources) !void {
        // link memory properties to each buffer for iteration
        const buf_mem_infos = [_]struct {
            buf: *vk.Buffer,
            mem: *vk.DeviceMemory,
            props: vk.MemoryPropertyFlags
        } {
            .{
                .buf = &res.input_buf,
                .mem = &res.input_mem,
                .props = .{ .host_visible_bit = true, .host_coherent_bit = true },
            },
            .{
                .buf = &res.device_input_buf,
                .mem = &res.device_input_mem,
                .props = .{ .device_local_bit = true },
            },
            .{
                .buf = &res.device_output_buf,
                .mem = &res.device_output_mem,
                .props = .{ .device_local_bit = true },
            },
            .{
                .buf = &res.output_buf,
                .mem = &res.output_mem,
                .props = .{ .host_visible_bit = true, .host_cached_bit = true },
            },
        };

        for (buf_mem_infos) |info| {
            // query memory requirements from buffer
            const mem_reqs = try self._device.getBufferMemoryRequirements(info.buf.*);

            // find suitable memory type
            const mem_type = findMemoryType(
                self._mem_props,
                mem_reqs.memory_type_bits,
                info.props
            ) orelse return error.NoSuitableMemory;

            // allocate memory
            info.mem.* = try self._device.allocateMemory(&.{
                .allocation_size = mem_reqs.size,
                .memory_type_index = mem_type,
            }, null);

            // bind buffer to memory w/ 0 offset
            self._device.bindBufferMemory(info.buf.*, info.mem.*, 0);
        }
    }

    fn setupPipelineCommandBuffer(self: *@This(), res: *PipelineResources) !void {
        // allocate buffer
        try self._device.allocateCommandBuffers(&.{
            .command_pool = self._cmd_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&res.cmd_buf)); 

        // record instructions
        try self._device.beginCommandBuffer(res.cmd_buf, &.{});

        // copy CPU to GPU
        self._device.cmdCopyBuffer(res.cmd_buf, res.input_buf, res.device_input_buf, 1, &[_]vk.BufferCopy{
            .{ .src_offset = 0, .dest_offset = 0, .size = res.input_buf.size }
        });

        // memory barrier to ensure write is valid before shader reads it
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
                .buffer = res.device_buffer,
                .offset = 0,
                .size = vk.WHOLE_SIZE,
            }},
            0, null
        );

        self._device.cmdBindPipeline(res.cmd_buf, .compute, 0);// TODO: fix
        
        try self._device.endCommandBuffer(res.cmd_buf);
    }

    fn setupComputePipeline(self: *@This(), res: *PipelineResources) !void {
        // create shader module
        const shader_code = @embedFile("shader.spv");
        const shader_module = try self._device.createShaderModule(&.{
            .code_size = shader_code.len,
            .p_code = @ptrCast(@alignCast(shader_code.ptr)),
        }, null);

        // descriptor set defining binding to input buffer, and output buffer
        const desc_layout = try self._device.createDescriptorSetLayout(&.{
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
    }

    fn mapCpuBuffersToHandle(
        self: *@This(),
        res: *PipelineResources,
        input_surface: *[*]u8,
        output_surface: *[*]uni_im.UnicodePixelData
    ) !void {
        // map input
        const input_mem_reqs = try self._device.getBufferMemoryRequirements(res.input_buf);
        var input_raw: ?*anyopaque = undefined;
        try self._device.mapMemory(res.input_mem, 0, input_mem_reqs.size, .{}, &input_raw);
        input_surface.* = @ptrCast(input_raw);

        // map output
        const output_mem_reqs = try self._device.getBufferMemoryRequirements(res.output_buf);
        var output_raw: ?*anyopaque = undefined;
        try self._device.mapMemory(res.output_mem, 0, output_mem_reqs.size, .{}, &output_raw);
        output_surface.* = @ptrCast(output_raw);
    }
};

// Link Vulkan functions
extern "vulkan" fn vkGetInstanceProcAddr(
    instance: vk.Instance,
    p_name: [*:0]const u8,
) ?vk.PfnVoidFunction;

