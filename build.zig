const std = @import("std");
const math = std.math;
const fs = std.fs;

pub fn build(b: *std.Build) void {
    // CONFIGURATION - Modifiable
    // ==========================

    // Define set of unicode characters used to compose images
    const CHARACTER_SET_SIZE: u32 = 65534;

    const codepoints = blk: {
        var codepoints: [CHARACTER_SET_SIZE]u32 = undefined;
        for (0..CHARACTER_SET_SIZE) |n| {
            codepoints[n] = 0xF5000 + @as(u32, @intCast(n));
        }
        break :blk codepoints;
    };

    // Compression constants - how many virtual pixels does a unicode character represent
    const PATCH_WIDTH = 4;
    const PATCH_HEIGHT = 4;

    // Raw byte file containing all unicode codepoints. Embedded in gen-dataset executable.
    const CHARACTER_SET_PATH = "unicode_glyph_data/charset.raw";

    // Raw byte file containing all the processed unicode glyph data. Embedded in main executable.
    const DATASET_PATH = "unicode_glyph_data/dataset.raw";

    // File identifier used to embed the dataset into the binary
    const DATASET_FILE_IDENTIFIER = "glyph-dataset";

    // Font path from root ~/.local/share/fonts
    const FONT_PATH = "fidelitty/fidelitty.ttf";


    // BUILT-IN - modify at your own risk
    // ==================================

    // Configure dataset parameters
    const dataset_config = b.addOptions();
    dataset_config.addOption(u8, "patch_width", PATCH_WIDTH);
    dataset_config.addOption(u8, "patch_height", PATCH_HEIGHT);
    dataset_config.addOption(u32, "charset_size", CHARACTER_SET_SIZE);
    dataset_config.addOption([]const u8, "font_path", FONT_PATH);

    // Comptime constants for dataset generation
    const gen_config = b.addOptions();
    gen_config.addOption([]const u8, "dataset_path", DATASET_PATH);
    gen_config.addOption([]const u8, "dataset_file", DATASET_FILE_IDENTIFIER);

    // Defaults
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});


    // ============== gen-dataset exe ===============

    // Create executable to generate and serialize the glyph dataset.
    const gen_dataset = b.addExecutable(.{
        .name = "gen-dataset",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen_dataset.zig"),
            .target = b.graph.host,
            .link_libc = true,
        }),
    });
    gen_dataset.root_module.addOptions("dataset_config", dataset_config);
    gen_dataset.root_module.addOptions("gen_config", gen_config);
    gen_dataset.root_module.addIncludePath(b.path("src/external"));
    gen_dataset.root_module.addCSourceFile(.{.file=b.path("src/external/stb_truetype_impl.c")});

    // Define step to generate dataset
    const run_gen = b.addRunArtifact(gen_dataset);
    const gen_step = b.step("gen-dataset", "Generate and serialize a glyph dataset for the given set of characters");

    // Write set of character codepoints for generator to build
    const write_charset = b.addWriteFiles();
    const cached_charset_file = write_charset.add(CHARACTER_SET_PATH, std.mem.asBytes(&codepoints));

    run_gen.addFileArg(cached_charset_file);
    gen_step.dependOn(&run_gen.step);


    // ============= root module ==============

    const build_mode = b.option(
        enum { module, shared_lib },
        "build-mode", "Build as Zig module or shared library"
    ) orelse .module;

    // Create library
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
    root_module.addOptions("gen_config", gen_config);
    
    // Allow embedding of dataset into binary
    root_module.addAnonymousImport(DATASET_FILE_IDENTIFIER, .{
        .root_source_file = b.path(DATASET_PATH)
    });

    // Compile compute shader
    const spirv_target = b.resolveTargetQuery(.{
        .cpu_arch = .spirv64,
        .cpu_model = .{ .explicit = &std.Target.spirv.cpu.vulkan_v1_2 },
        .os_tag = .vulkan,
        .ofmt = .spirv,
    });
    const kernel_module = b.createModule(.{
        .root_source_file = b.path("src/kernel.zig"),
        .target = spirv_target,
        .optimize = .ReleaseFast, // no debug info in shaders, always use release
    });
    kernel_module.addOptions("dataset_config", dataset_config);
    const kernel = b.addObject(.{
        .name = "compute_pixel",
        .root_module = kernel_module,
        .use_llvm = false,
        .use_lld = false,
    });
    root_module.addAnonymousImport("compute_pixel_spv", .{
        .root_source_file = kernel.getEmittedBin(),
    });

    // Compile stb_truetype
    root_module.addIncludePath(b.path("src/external/"));
    root_module.addCSourceFile(.{.file=b.path("src/external/stb_truetype_impl.c")});

    // Add vulkan dependency
    const vulkan = b.dependency("vulkan_zig", .{
        .target = target,
        .registry = b.path("vk.xml"),
    });
    root_module.addImport("vulkan", vulkan.module("vulkan-zig"));

    // If we're compiling to .so, link vulkan and install
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

    // Compile stb_image
    img_exe.root_module.addIncludePath(b.path("examples/"));
    img_exe.root_module.addCSourceFile(.{.file=b.path("examples/stb_image_impl.c")});

    // Install binary to zig-out
    b.installArtifact(img_exe);

    const run_exe = b.addRunArtifact(img_exe);
    const run_step = b.step("run-img-ex", "Run the example");
    run_step.dependOn(&run_exe.step);
}

