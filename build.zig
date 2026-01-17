const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // create root module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // create executable
    const exe = b.addExecutable(.{
        .name = "fidelitty",
        .root_module = exe_mod,
    });

    // compile shader
    const shader_cmd = b.addSystemCommand(&.{
        "glslc",
        "-fshader-stage=compute",
        "--target-env=vulkan1.4",
        "-o",
    });
    const shader_spv = shader_cmd.addOutputFileArg("shaders/bin/compute_pixel.spv");
    shader_cmd.addFileArg(b.path("shaders/compute_pixel.glsl"));
    exe_mod.addAnonymousImport("shaders/bin/compute_pixel.spv", .{
        .root_source_file = shader_spv
    });

    // compile stb headers and link LibC
    exe_mod.addIncludePath(b.path("src/external/"));
    exe_mod.addCSourceFile(.{.file=b.path("src/external/stb_truetype_impl.c")});
    exe_mod.addCSourceFile(.{.file=b.path("src/external/stb_image_impl.c")});
    exe.linkLibC();

    // add vulkan dependency
    const vulkan = b.dependency("vulkan_zig", .{
        .target = target,
        .registry = b.path("vk.xml"),
    });
    exe_mod.addImport("vulkan", vulkan.module("vulkan-zig"));
    exe.linkSystemLibrary("vulkan");
    
    // install
    b.installArtifact(exe);

    // optionally run
    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}

