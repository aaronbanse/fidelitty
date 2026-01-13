const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "fidelitty",
        .root_module = exe_mod,
    });

    exe_mod.addIncludePath(b.path("src/external/"));
    exe_mod.addCSourceFile(.{.file=b.path("src/external/stb_truetype_impl.c")});
    exe_mod.addCSourceFile(.{.file=b.path("src/external/stb_image_impl.c")});
    exe.linkLibC();

    const vulkan = b.dependency("vulkan_zig", .{
        .target = target,
        .registry = b.path("vk.xml"),
    });
    exe_mod.addImport("vulkan", vulkan.module("vulkan-zig"));
    
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}

