const std = @import("std");

pub fn build(b: *std.Build) void {
    // Configuration

    const CELL_W = 3;
    const CELL_H = 5;

    // Fidelitty's glyphs occupy the Private Use Area of unicode codepoints.
    // PUA-B starts at 0x100000, so we start at 0x105000 to avoid collisions.
    const CODEPOINT_START: u32 = 0x105000;

    const dataset_config = b.addOptions();
    dataset_config.addOption(u8, "cell_w", CELL_W);
    dataset_config.addOption(u8, "cell_h", CELL_H);
    dataset_config.addOption(u32, "codepoint_start", CODEPOINT_START);

    const FONT_DIR_FROM_HOME = ".local/share/fonts/fidelitty";
    const FONT_NAME = "fidelitty.ttf";

    const font_config = b.addOptions();
    font_config.addOption([]const u8, "font_dir_from_home", FONT_DIR_FROM_HOME);
    font_config.addOption([]const u8, "font_name", FONT_NAME);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build root module

    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });
    c.addIncludePath(b.path("src"));

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = b.path("vk.xml"),
        .target = target,
        .optimize = optimize,
    });

    const shader_spv = blk: {
        // compute_pixel.glsl uses a custom type for large vector operations.
        // We pass in all the parameters for this type as define statements.
        const VEC4_QUOTIENT = (CELL_W * CELL_H) / 4;
        const VEC4_REMAINDER = (CELL_W * CELL_H) % 4;
        const shader_cmd = b.addSystemCommand(&.{
            "glslc",
            std.fmt.comptimePrint("-DCELL_W={d}", .{CELL_W}),
            std.fmt.comptimePrint("-DCELL_H={d}", .{CELL_H}),
            std.fmt.comptimePrint("-DVEC4_QUOTIENT={d}", .{VEC4_QUOTIENT}),
            std.fmt.comptimePrint("-DVEC4_REMAINDER={d}", .{VEC4_REMAINDER}),
            "-fshader-stage=compute",
            // Target the lowest Vulkan env that covers the shader's 8-bit
            // storage usage so the SPIR-V also runs on 1.2-era devices.
            "--target-env=vulkan1.2",
            "-o",
        });
        const spv = shader_cmd.addOutputFileArg("src/shaders/out/compute_pixel.spv");
        shader_cmd.addFileArg(b.path("src/shaders/compute_pixel.glsl"));
        break :blk spv;
    };

    const root_module = b.addModule("fidelitty", .{
        .root_source_file = b.path("src/lib.zig"),
        .imports = &.{
            .{ .name = "dataset_config", .module = dataset_config.createModule() },
            .{ .name = "font_config", .module = font_config.createModule() },
            .{ .name = "c", .module = c.createModule() },
            .{ .name = "vulkan", .module = vulkan.module("vulkan-zig") },
            .{
                .name = "compute_pixel_spv",
                .module = b.createModule(.{ .root_source_file = shader_spv }),
            },
        },
        .target = target,
        .optimize = optimize,
    });

    root_module.linkSystemLibrary("vulkan", .{});
    root_module.addCSourceFile(.{
        .file = b.path("src/ext/stb_truetype_impl.c"),
    });

    // Build shared library

    const lib_artifact = b.addLibrary(.{
        .name = "fidelitty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .imports = &.{ .{ .name = "fidelitty", .module = root_module } },
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .dynamic,
        .version = .{ .major = 0, .minor = 2, .patch = 0 },
    });
    b.installArtifact(lib_artifact);
    b.installFile("include/fidelitty.h", "include/fidelitty.h");

    // Build main executable

    const main_exe = b.addExecutable(.{
        .name = "ftty-init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{ .{ .name = "fidelitty", .module = root_module } },
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(main_exe);

    // Build and run example

    const example_exe = b.addExecutable(.{
        .name = "img-example",
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("examples/render_image.zig"),
            .imports = &.{ .{ .name = "fidelitty", .module = root_module } },
        }),
    });

    example_exe.root_module.addIncludePath(b.path("examples/"));
    example_exe.root_module.addCSourceFile(.{
        .file = b.path("examples/stb_image_impl.c"),
    });

    const run_exe = b.addRunArtifact(example_exe);
    if (b.args) |args| run_exe.addArgs(args);
    const example_step = b.step("example", "Build and run the example");
    example_step.dependOn(&run_exe.step);
}
