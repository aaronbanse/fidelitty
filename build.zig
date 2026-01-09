const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // const vaxis = b.dependency("vaxis", .{
    //     .target = target,
    //     .optimize = optimize,
    // });
    // exe_mod.addImport("vaxis", vaxis.module("vaxis"));
    //
    // const vulkan = b.dependency("vulkan_zig", .{
    //     .target = target,
    //     .registry = b.path("vk.xml"),
    // });
    // exe_mod.addImport("vulkan", vulkan.module("vulkan-zig"));

    const exe = b.addExecutable(.{
        .name = "fragmentty",
        .root_module = exe_mod,
    });

    exe_mod.addCSourceFile(.{.file=b.path("src/external/stb_truetype_impl.c")});
    exe_mod.addIncludePath(b.path("src/external/"));
    exe.linkLibC();
    
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}

