const std = @import("std");
const math = std.math;
const fs = std.fs;

pub fn build(b: *std.Build) void {
    const CHARACTER_SET_START: u32 = 0xF5000;

    const CELL_VIRTUAL_W = 4;
    const CELL_VIRTUAL_H = 4;

    const FONT_PATH = "~/.local/share/fonts/fidelitty/fidelitty.ttf";

    const USE_ZIG_SHADER = false;

    const dataset_config = b.addOptions();
    dataset_config.addOption(u8, "cell_virtual_w", CELL_VIRTUAL_W);
    dataset_config.addOption(u8, "cell_virtual_h", CELL_VIRTUAL_H);
    dataset_config.addOption(u32, "charset_start", CHARACTER_SET_START);
    dataset_config.addOption([]const u8, "font_path", FONT_PATH);

    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});


    // ============= root module ==============

    const build_mode = b.option(
        enum { module, shared_lib },
        "build-mode", "Build as Zig module or shared library"
    ) orelse .module;

    const root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("fidelitty.zig"),
        .link_libc = true,
    });

    const lib_artifact_opt = if (build_mode == .shared_lib) b.addLibrary(.{
        .name = "fidelitty",
        .root_module = root_module,
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 1, .patch = 0 },
    }) else null;

    root_module.addOptions("dataset_config", dataset_config);


    if (USE_ZIG_SHADER) {
        const gpu_buf_limits = b.addOptions();
        gpu_buf_limits.addOption(usize, "image", 100_000);

        const kernel_module = b.createModule(.{
            .root_source_file = b.path("src/kernel.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .spirv64,
                .cpu_model = .{ .explicit = &std.Target.spirv.cpu.vulkan_v1_2 },
                .os_tag = .vulkan,
            }),
            .optimize = optimize,
        });
        kernel_module.addOptions("dataset_config", dataset_config);
        kernel_module.addOptions("gpu_buf_limits", gpu_buf_limits);

        const kernel_obj = b.addObject(.{
            .name = "compute_pixel",
            .root_module = kernel_module,
        });

        root_module.addAnonymousImport("compute_pixel_spv", .{
            .root_source_file = kernel_obj.getEmittedBin(),
        });
    } else {
        const shader_cmd = b.addSystemCommand(&.{
            "glslc",
            "-fshader-stage=compute",
            "--target-env=vulkan1.4",
            "-o",
        });
        const shader_spv = shader_cmd.addOutputFileArg("shaders/bin/compute_pixel.spv");
        shader_cmd.addFileArg(b.path("shaders/compute_pixel.glsl"));
        root_module.addAnonymousImport("compute_pixel_spv", .{
            .root_source_file = shader_spv,
        });
    }

    const vulkan = b.dependency("vulkan_zig", .{
        .target = target,
        .registry = b.path("vk.xml"),
    });
    root_module.addImport("vulkan", vulkan.module("vulkan-zig"));

    if (lib_artifact_opt) |lib_artifact| {
        lib_artifact.root_module.linkSystemLibrary("vulkan", .{});
        b.installArtifact(lib_artifact);
        b.installFile("include/fidelitty.h", "include/fidelitty.h");
    }


    // ============ run example exe =============

    const example_lang = b.option(enum { zig, c }, "example", "Which language version of the example to build and run (zig or c)") orelse .zig;

    const img_exe = switch (example_lang) {
        .zig => blk: {
            const exe = b.addExecutable(.{
                .name = "img-example",
                .root_module = b.createModule(.{
                    .optimize = optimize,
                    .target = target,
                    .root_source_file = b.path("examples/render_image.zig"),
                    .imports = &.{ .{ .name = "fidelitty", .module = root_module} },
                })
            });
            exe.root_module.linkSystemLibrary("vulkan", .{});
            break :blk exe;
        },
        .c => blk: {
            const fidelitty_lib = b.addLibrary(.{
                .name = "fidelitty",
                .root_module = root_module,
                .linkage = .static,
            });
            fidelitty_lib.root_module.linkSystemLibrary("vulkan", .{});

            const exe = b.addExecutable(.{
                .name = "img-example",
                .root_module = b.createModule(.{
                    .optimize = optimize,
                    .target = target,
                    .link_libc = true,
                })
            });
            exe.root_module.addCSourceFile(.{.file = b.path("examples/render_image.c")});
            exe.root_module.addIncludePath(b.path("include/"));
            exe.root_module.linkLibrary(fidelitty_lib);
            exe.root_module.linkSystemLibrary("vulkan", .{});
            break :blk exe;
        },
    };

    img_exe.root_module.addIncludePath(b.path("examples/"));
    img_exe.root_module.addCSourceFile(.{.file=b.path("examples/stb_image_impl.c")});

    b.installArtifact(img_exe);

    const run_exe = b.addRunArtifact(img_exe);
    const run_step = b.step("run-img-ex", "Run the example");
    run_step.dependOn(&run_exe.step);
}
