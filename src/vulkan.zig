const vk = @import("vulkan");

// Link Vulkan functions
extern "vulkan" fn vkGetInstanceProcAddr(
    instance: vk.Instance,
    p_name: [*:0]const u8,
) ?vk.PfnVoidFunction;

pub const Vulkan = struct {
    const BaseDispatcher = vk.BaseWrapper;
    const InstanceDispatcher = vk.InstanceWrapper;
    const DeviceDispatcher = vk.DeviceWrapper;

    const Instance = vk.InstanceProxy; // wrapper for handle + dispatch table
    const Device = vk.DeviceProxy; // wrapper for handle + dispatch table
    const Queue = vk.Queue; // just need opaque handle as queue does not dispatch anything

    // dispatch tables must outlive proxies
    vkb: BaseDispatcher,
    vki: InstanceDispatcher,
    vkd: DeviceDispatcher,

    // proxies: zig-style structs for logical entities
    instance: Instance,
    device: Device,
    queue: Queue,

    pub fn init(self: *@This()) !void {
        self.vkb = BaseDispatcher.load(vkGetInstanceProcAddr);

        // create instance
        const instance_handle = try self.vkb.createInstance(&.{
            .p_application_info = &.{
                .api_version = vk.makeApiVersion(0, 1, 3, 0),
            },
        }, null);
        self.vki = InstanceDispatcher.load(instance_handle, self.vkb.dispatch.vkGetInstanceProcAddr.?);
        self.instance = Instance.init(instance_handle, &self.vki);

        // find compute-capable device
        var num_devices: u32 = undefined;
        var devices: [16]vk.PhysicalDevice = undefined;
        _ = try self.instance.enumeratePhysicalDevices(&num_devices, &devices);
        const compute_device_found = findComputeDevice(devices[0..num_devices], &self.vki);
        const dev_info = compute_device_found orelse return error.NoComputeCapableDevice;

        // create device
        const queue_priority: f32 = 1.0;
        const device_handle = try self.vki.createDevice(devices[dev_info.dev_index], &.{
            .queue_create_info_count = 1,
            .p_queue_create_infos = &[_]vk.DeviceQueueCreateInfo{.{
                .queue_family_index = dev_info.queue_fam_index,
                .queue_count = 1,
                .p_queue_priorities = &queue_priority,
            }},
        }, null);
        self.vkd = DeviceDispatcher.load(device_handle, self.vki.dispatch.vkGetDeviceProcAddr.?);
        self.device = Device.init(device_handle, &self.vkd);
        
        self.queue = self.device.getDeviceQueue(dev_info.queue_fam_index, 0);

        return self;
    }

    fn findComputeDevice(
        devices: []vk.PhysicalDevice,
        vki: *const InstanceDispatcher
    ) ?struct{ dev_index: u32, queue_fam_index: u32 } {
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
};


