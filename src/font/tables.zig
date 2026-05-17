//! OpenType table struct definitions and their builders.

const mem = @import("std").mem;
const config = @import("config");
const common = @import("common.zig");
const Big = common.Big;
const num_glyphs = common.num_glyphs;
const MAX_CONTOURS = common.MAX_CONTOURS;
const MAX_GLYPH_SIZE = common.MAX_GLYPH_SIZE;
const hmtx_size = common.hmtx_size;
const UserFontMetrics = @import("metrics.zig").UserFontMetrics;

// Table structs based on OpenType specification:
// https://learn.microsoft.com/en-us/typography/opentype/spec/

pub const Head = extern struct {
    version_major: Big(u16),
    version_minor: Big(u16),
    font_revision: Big(u32),
    checksum_adjustment: Big(u32),
    magic_number: Big(u32),
    flags: Big(u16),
    units_per_em: Big(u16),
    created: Big(i64),
    modified: Big(i64),
    x_min: Big(i16),
    y_min: Big(i16),
    x_max: Big(i16),
    y_max: Big(i16),
    mac_style: Big(u16),
    lowest_rec_ppem: Big(u16),
    font_direction_hint: Big(i16),
    index_to_loc_format: Big(i16),
    glyph_data_format: Big(i16),
};

pub const Hhea = extern struct {
    major_version: Big(u16),
    minor_version: Big(u16),
    ascender: Big(i16),
    descender: Big(i16),
    line_gap: Big(i16),
    advance_width_max: Big(u16),
    min_left_side_bearing: Big(i16),
    min_right_side_bearing: Big(i16),
    x_max_extent: Big(i16),
    caret_slope_rise: Big(i16),
    caret_slope_run: Big(i16),
    caret_offset: Big(i16),
    reserved1: Big(i16),
    reserved2: Big(i16),
    reserved3: Big(i16),
    reserved4: Big(i16),
    metric_data_format: Big(i16),
    number_of_h_metrics: Big(u16),
};

pub const Maxp = extern struct {
    version: Big(u32),
    num_glyphs: Big(u16),
    max_points: Big(u16),
    max_contours: Big(u16),
    max_composite_points: Big(u16),
    max_composite_contours: Big(u16),
    max_zones: Big(u16),
    max_twilight_points: Big(u16),
    max_storage: Big(u16),
    max_function_defs: Big(u16),
    max_instruction_defs: Big(u16),
    max_stack_elements: Big(u16),
    max_size_of_instructions: Big(u16),
    max_component_elements: Big(u16),
    max_component_depth: Big(u16),
};

pub const Os2 = extern struct {
    version: Big(u16),
    x_avg_char_width: Big(i16),
    us_weight_class: Big(u16),
    us_width_class: Big(u16),
    fs_type: Big(u16),
    y_subscript_x_size: Big(i16),
    y_subscript_y_size: Big(i16),
    y_subscript_x_offset: Big(i16),
    y_subscript_y_offset: Big(i16),
    y_superscript_x_size: Big(i16),
    y_superscript_y_size: Big(i16),
    y_superscript_x_offset: Big(i16),
    y_superscript_y_offset: Big(i16),
    y_strikeout_size: Big(i16),
    y_strikeout_position: Big(i16),
    s_family_class: Big(i16),
    panose: [10]u8,
    ul_unicode_range1: Big(u32),
    ul_unicode_range2: Big(u32),
    ul_unicode_range3: Big(u32),
    ul_unicode_range4: Big(u32),
    ach_vend_id: [4]u8,
    fs_selection: Big(u16),
    us_first_char_index: Big(u16),
    us_last_char_index: Big(u16),
    s_typo_ascender: Big(i16),
    s_typo_descender: Big(i16),
    s_typo_line_gap: Big(i16),
    us_win_ascent: Big(u16),
    us_win_descent: Big(u16),
    ul_code_page_range1: Big(u32),
    ul_code_page_range2: Big(u32),
    sx_height: Big(i16),
    s_cap_height: Big(i16),
    us_default_char: Big(u16),
    us_break_char: Big(u16),
    us_max_context: Big(u16),
};

pub const Post = extern struct {
    version: Big(u32),
    italic_angle: Big(i32),
    underline_position: Big(i16),
    underline_thickness: Big(i16),
    is_fixed_pitch: Big(u32),
    min_mem_type42: Big(u32),
    max_mem_type42: Big(u32),
    min_mem_type1: Big(u32),
    max_mem_type1: Big(u32),
};

pub const NameRecord = extern struct {
    platform_id: Big(u16),
    encoding_id: Big(u16),
    language_id: Big(u16),
    name_id: Big(u16),
    length: Big(u16),
    string_offset: Big(u16),
};

pub const Name = extern struct {
    format: Big(u16),
    count: Big(u16),
    string_offset: Big(u16),
    records: [5]NameRecord,
    string_data: [150]u8, // UTF-16BE encoded strings (75 ASCII chars)
};

pub const CmapEncodingRecord = extern struct {
    platform_id: Big(u16),
    encoding_id: Big(u16),
    subtable_offset: Big(u32),
};

// Format 4 subtable with 1 sentinel segment (specific to this font's layout)
pub const CmapFormat4 = extern struct {
    format: Big(u16),
    length: Big(u16),
    language: Big(u16),
    seg_count_x2: Big(u16),
    search_range: Big(u16),
    entry_selector: Big(u16),
    range_shift: Big(u16),
    // segment arrays (1 sentinel segment)
    end_code: Big(u16),
    reserved_pad: Big(u16),
    start_code: Big(u16),
    id_delta: Big(i16),
    id_range_offset: Big(u16),
};

// Format 12 subtable with 1 group (specific to this font's layout)
pub const CmapFormat12 = extern struct {
    format: Big(u16),
    reserved: Big(u16),
    length: Big(u32),
    language: Big(u32),
    num_groups: Big(u32),
    // groups (1 group)
    start_char_code: Big(u32),
    end_char_code: Big(u32),
    start_glyph_id: Big(u32),
};

pub const Cmap = extern struct {
    version: Big(u16),
    num_tables: Big(u16),
    encoding_records: [3]CmapEncodingRecord,
    format4: CmapFormat4,
    format12: CmapFormat12,
};

pub const OffsetTable = extern struct {
    sf_version: Big(u32),
    num_tables: Big(u16),
    search_range: Big(u16),
    entry_selector: Big(u16),
    range_shift: Big(u16),
};

pub const TableRecord = extern struct {
    tag: [4]u8,
    checksum: Big(u32),
    offset: Big(u32),
    length: Big(u32),
};

// hmtx table: variable-length, per-glyph metric record
pub const LongHorMetric = extern struct {
    advance_width: Big(u16),
    lsb: Big(i16),
};

pub const Glyf = extern struct {
    buf: [num_glyphs * MAX_GLYPH_SIZE]u8,
    len: usize,
};

pub const Loca = extern struct {
    buf: [(num_glyphs + 1) * 4]u8,
};

pub const Hmtx = extern struct {
    buf: [hmtx_size]u8,
};

pub fn buildHead(metrics: UserFontMetrics, rect_w: i16, rect_h: i16) Head {
    return .{
        .version_major = .from(1),
        .version_minor = .from(0),
        .font_revision = .from(0x00010000),
        .checksum_adjustment = .from(0), // filled later
        .magic_number = .from(0x5F0F3CF5),
        .flags = .from(0x000B),
        .units_per_em = .from(@intCast(metrics.upm)),
        .created = .from(0),
        .modified = .from(0),
        .x_min = .from(-rect_w),
        .y_min = .from(-metrics.descent - rect_h),
        .x_max = .from(@as(i16, @intCast(metrics.advance_width)) + rect_w),
        .y_max = .from(metrics.ascent + rect_h),
        .mac_style = .from(0),
        .lowest_rec_ppem = .from(8),
        .font_direction_hint = .from(2),
        .index_to_loc_format = .from(1), // long
        .glyph_data_format = .from(0),
    };
}

pub fn buildHhea(metrics: UserFontMetrics, rect_w: i16) Hhea {
    return .{
        .major_version = .from(1),
        .minor_version = .from(0),
        .ascender = .from(metrics.ascent),
        .descender = .from(-metrics.descent),
        .line_gap = .from(metrics.line_gap),
        .advance_width_max = .from(metrics.advance_width),
        .min_left_side_bearing = .from(0),
        .min_right_side_bearing = .from(0),
        .x_max_extent = .from(@as(i16, @intCast(metrics.advance_width)) + rect_w),
        .caret_slope_rise = .from(1),
        .caret_slope_run = .from(0),
        .caret_offset = .from(0),
        .reserved1 = .from(0),
        .reserved2 = .from(0),
        .reserved3 = .from(0),
        .reserved4 = .from(0),
        .metric_data_format = .from(0),
        .number_of_h_metrics = .from(1),
    };
}

pub fn buildMaxp() Maxp {
    return .{
        .version = .from(0x00010000),
        .num_glyphs = .from(@intCast(num_glyphs)),
        .max_points = .from(MAX_CONTOURS * 4),
        .max_contours = .from(MAX_CONTOURS),
        .max_composite_points = .from(0),
        .max_composite_contours = .from(0),
        .max_zones = .from(1),
        .max_twilight_points = .from(0),
        .max_storage = .from(0),
        .max_function_defs = .from(0),
        .max_instruction_defs = .from(0),
        .max_stack_elements = .from(0),
        .max_size_of_instructions = .from(0),
        .max_component_elements = .from(0),
        .max_component_depth = .from(0),
    };
}

pub fn buildOs2(metrics: UserFontMetrics) Os2 {
    return .{
        .version = .from(4),
        .x_avg_char_width = .from(@intCast(metrics.advance_width)),
        .us_weight_class = .from(400), // Normal
        .us_width_class = .from(5), // Medium
        .fs_type = .from(0),
        .y_subscript_x_size = .from(0),
        .y_subscript_y_size = .from(0),
        .y_subscript_x_offset = .from(0),
        .y_subscript_y_offset = .from(0),
        .y_superscript_x_size = .from(0),
        .y_superscript_y_size = .from(0),
        .y_superscript_x_offset = .from(0),
        .y_superscript_y_offset = .from(0),
        .y_strikeout_size = .from(0),
        .y_strikeout_position = .from(0),
        .s_family_class = .from(0),
        .panose = .{0} ** 10,
        .ul_unicode_range1 = .from(0),
        .ul_unicode_range2 = .from(0),
        .ul_unicode_range3 = .from(0),
        .ul_unicode_range4 = .from(0),
        .ach_vend_id = "    ".*,
        .fs_selection = .from(0x0040), // Regular
        .us_first_char_index = .from(0),
        .us_last_char_index = .from(0xFFFF),
        .s_typo_ascender = .from(metrics.ascent),
        .s_typo_descender = .from(-metrics.descent),
        .s_typo_line_gap = .from(metrics.line_gap),
        .us_win_ascent = .from(@intCast(metrics.ascent)),
        .us_win_descent = .from(@intCast(metrics.descent)),
        .ul_code_page_range1 = .from(0),
        .ul_code_page_range2 = .from(0),
        .sx_height = .from(0),
        .s_cap_height = .from(0),
        .us_default_char = .from(0),
        .us_break_char = .from(0x0020),
        .us_max_context = .from(1),
    };
}

pub fn buildPost() Post {
    return .{
        .version = .from(0x00030000), // format 3.0 (no glyph names)
        .italic_angle = .from(0),
        .underline_position = .from(0),
        .underline_thickness = .from(0),
        .is_fixed_pitch = .from(0),
        .min_mem_type42 = .from(0),
        .max_mem_type42 = .from(0),
        .min_mem_type1 = .from(0),
        .max_mem_type1 = .from(0),
    };
}

pub fn buildHmtx(advance: u16) Hmtx {
    var hmtx: Hmtx = undefined;
    const metric = LongHorMetric{
        .advance_width = .from(advance),
        .lsb = .from(0),
    };
    @memcpy(hmtx.buf[0..@sizeOf(LongHorMetric)], mem.asBytes(&metric));
    // Remaining glyphs: just lsb (i16 each), all zero
    @memset(hmtx.buf[@sizeOf(LongHorMetric)..], 0);
    return hmtx;
}

pub fn buildCmap() Cmap {
    const codepoint_end = config.codepoint_start + num_glyphs - 1;
    return .{
        .version = .from(0),
        .num_tables = .from(3),
        .encoding_records = .{
            .{ .platform_id = .from(0), .encoding_id = .from(3), .subtable_offset = .from(28) }, // Unicode BMP -> format 4
            .{ .platform_id = .from(3), .encoding_id = .from(1), .subtable_offset = .from(28) }, // Windows UCS-2 -> format 4
            .{ .platform_id = .from(3), .encoding_id = .from(10), .subtable_offset = .from(52) }, // Windows UCS-4 -> format 12
        },
        .format4 = .{
            .format = .from(4),
            .length = .from(24),
            .language = .from(0),
            .seg_count_x2 = .from(2), // 1 sentinel segment
            .search_range = .from(2),
            .entry_selector = .from(0),
            .range_shift = .from(0),
            .end_code = .from(0xFFFF),
            .reserved_pad = .from(0),
            .start_code = .from(0xFFFF),
            .id_delta = .from(1),
            .id_range_offset = .from(0),
        },
        .format12 = .{
            .format = .from(12),
            .reserved = .from(0),
            .length = .from(28), // 16 header + 12 per group
            .language = .from(0),
            .num_groups = .from(1),
            .start_char_code = .from(config.codepoint_start),
            .end_char_code = .from(codepoint_end),
            .start_glyph_id = .from(0),
        },
    };
}

fn utf16be(comptime ascii: []const u8) [ascii.len * 2]u8 {
    var result: [ascii.len * 2]u8 = undefined;
    for (ascii, 0..) |ch, i| {
        result[i * 2] = 0;
        result[i * 2 + 1] = ch;
    }
    return result;
}

pub fn buildName() Name {
    return .{
        .format = .from(0),
        .count = .from(5),
        .string_offset = .from(@sizeOf(Name) - 150), // header + records
        .records = .{
            .{ // family
                .platform_id = .from(3),
                .encoding_id = .from(1),
                .language_id = .from(0),
                .name_id = .from(1),
                .length = .from(38),
                .string_offset = .from(0),
            },
            .{ // style
                .platform_id = .from(3),
                .encoding_id = .from(1),
                .language_id = .from(0),
                .name_id = .from(2),
                .length = .from(14),
                .string_offset = .from(38),
            },
            .{ // full name
                .platform_id = .from(3),
                .encoding_id = .from(1),
                .language_id = .from(0),
                .name_id = .from(4),
                .length = .from(38),
                .string_offset = .from(52),
            },
            .{ // version
                .platform_id = .from(3),
                .encoding_id = .from(1),
                .language_id = .from(0),
                .name_id = .from(5),
                .length = .from(22),
                .string_offset = .from(90),
            },
            .{ // postscript name
                .platform_id = .from(3),
                .encoding_id = .from(1),
                .language_id = .from(0),
                .name_id = .from(6),
                .length = .from(38),
                .string_offset = .from(112),
            },
        },
        // zig fmt: off
        .string_data = utf16be("Fidelitty Glyph Set")
            ++ utf16be("Regular")
            ++ utf16be("Fidelitty Glyph Set")
            ++ utf16be("Version 1.0")
            ++ utf16be("Fidelitty-Glyph-Set"),
        // zig fmt: on
    };
}
