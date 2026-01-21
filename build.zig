const std = @import("std");
const math = std.math;
const fs = std.fs;

pub fn build(b: *std.Build) void {
    // CONFIGURATION - Modifiable
    // ==========================

    // Define set of unicode characters used to compose images
    // This set consist of characters in the range [0x2500, 0x25ff] and [0x2800, 0x28ff]
    const u8_vals: u32 = math.maxInt(u8) + 1;
    const CHARACTER_SET_SIZE: u32 = u8_vals * 2;

    var codepoints: [CHARACTER_SET_SIZE]u32 = undefined;
    for (0..u8_vals) |n| {
        // [0x2800, 0x28ff]
        codepoints[n] = 0x2800 + @as(u16, @intCast(n));

        // [0x2500, 0x25ff] - {0x2591, 0x2592, 0x2593}
        if (n == 0x91 or n == 0x92 or n == 0x93) { // these characters caused visual issues for whatever reason
            codepoints[n+u8_vals] = 0x2500; // simpler to default than to omit completely
        } else {
            codepoints[n+u8_vals] = 0x2500 + @as(u16, @intCast(n));
        }
    }

    // Compression constants - how many virtual pixels does a unicode character represent
    const PATCH_WIDTH = 4;
    const PATCH_HEIGHT = 4;

    // Raw byte file containing all unicode codepoints. Embedded in gen-dataset executable.
    const CHARACTER_SET_PATH = "unicode_glyph_data/charset.raw";

    // Raw byte file containing all the processed unicode glyph data. Embedded in main executable.
    const DATASET_PATH = "unicode_glyph_data/dataset.raw";

    // File identifier used to embed the dataset into the binary
    const DATASET_FILE_IDENTIFIER = "glyph-dataset";

    // Font path from root /usr/share/fonts/
    const FONT_PATH = "Adwaita/AdwaitaMono-Regular.ttf";

    // BUILT-IN - modify at your own risk
    // ==================================

    // Configure constants for gen_dataset and main
    const config = b.addOptions();
    config.addOption(u8, "patch_width", PATCH_WIDTH);
    config.addOption(u8, "patch_height", PATCH_HEIGHT);
    config.addOption(u32, "charset_size", CHARACTER_SET_SIZE);
    config.addOption([]const u8, "dataset_path", DATASET_PATH);
    config.addOption([]const u8, "dataset_file", DATASET_FILE_IDENTIFIER);
    config.addOption([]const u8, "font_path", FONT_PATH);

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
        }),
    });
    gen_dataset.root_module.addOptions("config", config);
    gen_dataset.addIncludePath(b.path("src/external"));
    gen_dataset.addCSourceFile(.{.file=b.path("src/external/stb_truetype_impl.c")});
    gen_dataset.linkLibC();

    // Define step to generate dataset
    const run_gen = b.addRunArtifact(gen_dataset);
    const gen_step = b.step("gen-dataset", "Generate and serialize a glyph dataset for the given set of characters");

    // Write set of character codepoints for generator to build
    const write_charset = b.addWriteFiles();
    const cached_charset_file = write_charset.add(CHARACTER_SET_PATH, std.mem.asBytes(&codepoints));

    run_gen.addFileArg(cached_charset_file);
    gen_step.dependOn(&run_gen.step);


    // ============= main exe (default) ==============

    // Create main executable
    const exe = b.addExecutable(.{
        .name = "fidelitty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("config", config);
    
    // Allow embedding of dataset into binary
    exe.root_module.addAnonymousImport(DATASET_FILE_IDENTIFIER, .{
        .root_source_file = b.path(DATASET_PATH)
    });

    // Compile shader
    const shader_cmd = b.addSystemCommand(&.{
        "glslc",
        "-fshader-stage=compute",
        "--target-env=vulkan1.4",
        "-o",
    });
    const shader_spv = shader_cmd.addOutputFileArg("shaders/bin/compute_pixel.spv");
    shader_cmd.addFileArg(b.path("shaders/compute_pixel.glsl"));
    exe.root_module.addAnonymousImport("shaders/bin/compute_pixel.spv", .{
        .root_source_file = shader_spv
    });

    // Compile stb headers and link LibC
    exe.root_module.addIncludePath(b.path("src/external/"));
    exe.root_module.addCSourceFile(.{.file=b.path("src/external/stb_truetype_impl.c")});
    exe.root_module.addCSourceFile(.{.file=b.path("src/external/stb_image_impl.c")});
    exe.linkLibC();

    // Add vulkan dependency
    const vulkan = b.dependency("vulkan_zig", .{
        .target = target,
        .registry = b.path("vk.xml"),
    });
    exe.root_module.addImport("vulkan", vulkan.module("vulkan-zig"));
    exe.linkSystemLibrary("vulkan");

    // Install
    b.installArtifact(exe);

    // Optionally run
    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
}

