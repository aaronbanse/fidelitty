//! OpenType table struct definitions and their builders.

const config = @import("config");
const common = @import("common.zig");
const Big = common.Big;
const fixed16_16 = common.fixed16_16;
const num_glyphs = common.num_glyphs;
const MAX_CONTOURS = common.MAX_CONTOURS;
const MAX_GLYPH_SIZE = common.MAX_GLYPH_SIZE;
const UserFontMetrics = @import("metrics.zig").UserFontMetrics;
const renderBitmap = @import("render_bitmap.zig").renderBitmap;

// Table structs based on OpenType specification:
// https://learn.microsoft.com/en-us/typography/opentype/spec/
//
// Tables, their builders, and the on-disk layout in writer.zig are all
// ordered by tag, the order the OpenType spec requires for the table
// directory: OS/2, cmap, glyf, head, hhea, hmtx, loca, maxp, name, post.

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
    panose: [10]u8, // 10 PANOSE classification digits; all-zero = "any"
    ul_unicode_range1: Big(u32),
    ul_unicode_range2: Big(u32),
    ul_unicode_range3: Big(u32),
    ul_unicode_range4: Big(u32),
    ach_vend_id: [4]u8, // 4-char ASCII font vendor ID
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

pub const Glyf = extern struct {
    buf: [num_glyphs * MAX_GLYPH_SIZE]u8,
    len: usize,
};

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

pub const HorizontalMetric = extern struct {
    advance_width: Big(u16),
    lsb: Big(i16),
};

// hmtx table: one full horizontal metric per glyph.
pub const Hmtx = extern struct {
    metrics: [num_glyphs]HorizontalMetric,
};

// loca table, long format (head.index_to_loc_format = 1): a u32 offset into
// glyf for each glyph, plus a trailing sentinel offset marking the end.
pub const Loca = extern struct {
    offsets: [num_glyphs + 1]Big(u32),
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

pub const NameRecord = extern struct {
    platform_id: Big(u16),
    encoding_id: Big(u16),
    language_id: Big(u16),
    name_id: Big(u16),
    length: Big(u16),
    string_offset: Big(u16),
};

// The OpenType name strings, one per name ID. Every record length, string
// offset, and the string-storage size below are derived from this list.
const name_entries = [_]struct { id: u16, text: []const u8 }{
    .{ .id = 1, .text = "Fidelitty Glyph Set" }, // family
    .{ .id = 2, .text = "Regular" }, // subfamily
    .{ .id = 4, .text = "Fidelitty Glyph Set" }, // full name
    .{ .id = 5, .text = "Version 1.0" }, // version
    .{ .id = 6, .text = "Fidelitty-Glyph-Set" }, // postscript name
};

// Total size of the string storage: every name string concatenated and
// UTF-16BE encoded (2 bytes per ASCII character).
const name_string_bytes = blk: {
    var total: usize = 0;
    for (name_entries) |entry| total += entry.text.len * 2;
    break :blk total;
};

pub const Name = extern struct {
    format: Big(u16),
    count: Big(u16),
    string_offset: Big(u16),
    records: [name_entries.len]NameRecord,
    string_data: [name_string_bytes]u8,
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

// File container structures (not OpenType tables): the table directory.
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

pub fn buildOs2(metrics: UserFontMetrics) Os2 {
    return .{
        .version = .from(4), // OS/2 table version 4
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
        .us_win_descent = .from(@intCast(-metrics.descent)),
        .ul_code_page_range1 = .from(0),
        .ul_code_page_range2 = .from(0),
        .sx_height = .from(0),
        .s_cap_height = .from(0),
        .us_default_char = .from(0),
        .us_break_char = .from(0x0020),
        .us_max_context = .from(1),
    };
}

pub fn buildCmap() Cmap {
    const codepoint_end = config.codepoint_start + num_glyphs - 1;
    return .{
        .version = .from(0),
        .num_tables = .from(3),
        .encoding_records = .{
            .{ // Unicode BMP -> format 4
                .platform_id = .from(0),
                .encoding_id = .from(3),
                .subtable_offset = .from(@offsetOf(Cmap, "format4")),
            },
            .{ // Windows UCS-2 -> format 4
                .platform_id = .from(3),
                .encoding_id = .from(1),
                .subtable_offset = .from(@offsetOf(Cmap, "format4")),
            },
            .{ // Windows UCS-4 -> format 12
                .platform_id = .from(3),
                .encoding_id = .from(10),
                .subtable_offset = .from(@offsetOf(Cmap, "format12")),
            },
        },
        .format4 = .{
            .format = .from(4),
            .length = .from(@sizeOf(CmapFormat4)),
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
            .length = .from(@sizeOf(CmapFormat12)),
            .language = .from(0),
            .num_groups = .from(1),
            .start_char_code = .from(config.codepoint_start),
            .end_char_code = .from(codepoint_end),
            .start_glyph_id = .from(0),
        },
    };
}

pub fn buildGlyfLoca(glyf: *Glyf, loca: *Loca, descent: i16, rect_w: i16, rect_h: i16) void {
    glyf.len = 0;
    for (0..num_glyphs) |glyph_id| {
        loca.offsets[glyph_id] = Big(u32).from(@intCast(glyf.len));
        // Glyph index, dataset entry, and codepoint offset are the same value
        // `g`; the bit pattern it renders is `g + 1`, since the degenerate
        // empty pattern (0) is excluded from the set (see `UnicodeGlyphDataset`).
        const size = renderBitmap(@intCast(glyph_id + 1), glyf.buf[glyf.len..], rect_w, rect_h, descent);
        glyf.len += @intCast(size);
    }
    // Trailing sentinel: glyph i's data spans loca[i]..loca[i + 1], so a final
    // entry is needed to give the last glyph an end offset.
    loca.offsets[num_glyphs] = Big(u32).from(@intCast(glyf.len));
}

pub fn buildHead(metrics: UserFontMetrics, rect_w: i16, rect_h: i16) Head {
    return .{
        .version_major = .from(1),
        .version_minor = .from(0),
        .font_revision = .from(fixed16_16(1, 0)),
        .checksum_adjustment = .from(0), // filled later
        .magic_number = .from(0x5F0F3CF5), // required 'head' magic number
        .flags = .from(0x000B), // bits 0,1,3: baseline@y=0, lsb@x=0, integer ppem
        .units_per_em = .from(metrics.units_per_em),
        .created = .from(0),
        .modified = .from(0),
        .x_min = .from(-rect_w),
        .y_min = .from(-metrics.descent - rect_h),
        .x_max = .from(@as(i16, @intCast(metrics.advance_width)) + rect_w),
        .y_max = .from(metrics.ascent + rect_h),
        .mac_style = .from(0),
        .lowest_rec_ppem = .from(8), // smallest legible size, in pixels per em
        .font_direction_hint = .from(2), // deprecated field; 2 per spec
        .index_to_loc_format = .from(1), // 1 = long (32-bit loca offsets)
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
        .number_of_h_metrics = .from(@intCast(num_glyphs)),
    };
}

pub fn buildHmtx(advance: u16) Hmtx {
    const metric: HorizontalMetric = .{
        .advance_width = .from(advance),
        .lsb = .from(0),
    };
    return .{
        .metrics = .{metric} ** num_glyphs,
    };
}

pub fn buildMaxp() Maxp {
    return .{
        .version = .from(fixed16_16(1, 0)),
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

fn utf16be(comptime ascii: []const u8) [ascii.len * 2]u8 {
    var result: [ascii.len * 2]u8 = undefined;
    for (ascii, 0..) |ch, i| {
        result[i * 2] = 0;
        result[i * 2 + 1] = ch;
    }
    return result;
}

pub fn buildName() Name {
    var records: [name_entries.len]NameRecord = undefined;
    var string_data: [name_string_bytes]u8 = undefined;
    var offset: u16 = 0;
    inline for (name_entries, &records) |entry, *record| {
        const encoded = utf16be(entry.text);
        record.* = .{
            .platform_id = .from(3), // Unicode; read by all modern platforms
            .encoding_id = .from(1),
            .language_id = .from(0),
            .name_id = .from(entry.id),
            .length = .from(encoded.len),
            .string_offset = .from(offset),
        };
        @memcpy(string_data[offset..][0..encoded.len], &encoded);
        offset += encoded.len;
    }
    return .{
        .format = .from(0),
        .count = .from(name_entries.len),
        .string_offset = .from(@sizeOf(Name) - name_string_bytes), // past header + records
        .records = records,
        .string_data = string_data,
    };
}

pub fn buildPost() Post {
    return .{
        .version = .from(fixed16_16(3, 0)), // format 3.0: no glyph names
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
