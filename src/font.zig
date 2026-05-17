const std = @import("std");
const mem = std.mem;
const math = std.math;
const Io = std.Io;
const fs = std.fs;

const config = @import("config");
const cell_cols = config.cell_cols;
const cell_rows = config.cell_rows;
const num_glyphs = @import("glyph.zig").UnicodeGlyphDataset(cell_cols, cell_rows).numCodepoints();

// TODO: figure out more informed values for these, and where they should live.
const MAX_CONTOURS = 36;
const MAX_GLYPH_SIZE = 1024;
const NUM_TABLES: u16 = 10;
// Should not live here
const hmtx_size = 4 + (@as(usize, num_glyphs) - 1) * 2;

const Metrics = struct {
    upm: i16,
    ascent: i16,
    descent: i16,
    line_gap: i16,
    advance: u16,
};

pub fn syncFont(io: Io) !void {
    // TODO: figure out how to prevent buffer overflow here
    var default_name_buf: [64]u8 = undefined;
    const default_name_size = try detectDefault(io, &default_name_buf);
    const default_name = default_name_buf[0..default_name_size];

    const metrics = try getMetrics(io, default_name);

    if (!try isCached(io, metrics)) {
        try generateFont(io, metrics);
        try cacheMetrics(io, metrics);
    }
}

fn detectDefault(io: Io, out: []u8) !usize {
    // TODO:
    // - Research how each terminal stores default font, plus the format of the string so we can map to fc-match
    // - Research potential exceptions. How could this fail? What assumptions can we rely on?
    // - ensure that buffer passed in is large enough.
    
    // What could fail with this step?
    // - Config file is not in the place we expect.
    // - Symlinks? Should propogate for our application too, if they exist
    // - Fail to parse the default font from the config file due to some exception.
    
    // If no default font is defined, fallback to fc-match command.
}

fn isCached(io: Io, metrics: Metrics) !bool {

    // TODO:
    // check .local/share/fonts/fidelitty/.cache
    // Attempt to parse cache file, return true if parse succeeds and metrics match, false otherwise.
}

fn getMetrics(io: Io, font_name: []const u8) !Metrics {
    // TODO:
    // - Figure out the correct fc-query command to get the info we need.
}

fn cacheMetrics(io: Io, metrics: Metrics) !void {
    // TODO:
    // - Write to a file dictionary-style with each metric, and =, and the value.
    // - Name of file is .cache, goes inside the config.font_dir directory alongside fidelitty.ttf
}

fn generateFont(io: Io, metrics: Metrics) !void {
    // TODO: go through line by line to understand what we're doing here.
    // There are certain areas of the code that could be made more clear, especially
    // in terms of naming things.
    // MAJOR TODO: depend on glyph.zig for all of our dataset generation,
    // Derive bit ordering and everything from that file. one source of truth

    const advance_i16: i16 = @intCast(metrics.advance);
    const glyph_rect_w: i16 = @divExact(advance_i16, cell_cols);
    const glyph_rect_h: i16 = @divExact(metrics.ascent + metrics.descent, cell_rows);

    var glyf: Glyf = undefined;
    var loca: Loca = undefined;
    buildGlyf(&glyf, &loca, metrics.ascent, glyph_rect_w, glyph_rect_h);

    const head = buildHead(metrics, glyph_rect_w, glyph_rect_h);
    const hhea = buildHhea(metrics, glyph_rect_w);
    const maxp = buildMaxp();
    const os2 = buildOs2(metrics);
    const post = buildPost();
    const hmtx = buildHmtx(metrics.advance);
    const cmap = buildCmap();
    const name = buildName();

    const table_defs = [_]struct { tag: *const [4]u8, data: []const u8 }{
        .{ .tag = "OS/2", .data = mem.asBytes(&os2) },
        .{ .tag = "cmap", .data = mem.asBytes(&cmap) },
        .{ .tag = "glyf", .data = glyf.buf[0..glyf.len] },
        .{ .tag = "head", .data = mem.asBytes(&head) },
        .{ .tag = "hhea", .data = mem.asBytes(&hhea) },
        .{ .tag = "hmtx", .data = &hmtx.buf },
        .{ .tag = "loca", .data = &loca.buf },
        .{ .tag = "maxp", .data = mem.asBytes(&maxp) },
        .{ .tag = "name", .data = mem.asBytes(&name) },
        .{ .tag = "post", .data = mem.asBytes(&post) },
    };

    const Table = struct {
        tag: *const [4]u8,
        data: []const u8,
        padded_len: u32,
    };

    var table_buf: [NUM_TABLES]Table = undefined;

    const table_dir_size: u32 = @sizeOf(OffsetTable) + NUM_TABLES * @sizeOf(TableRecord);

    var current_offset = table_dir_size;
    for (0..NUM_TABLES) |i| {
        const padded: u32 = @intCast((table_defs[i].data.len + 3) & ~@as(usize, 3));
        table_buf[i] = .{
            .tag = table_defs[i].tag,
            .data = table_defs[i].data,
            .padded_len = padded,
        };
        current_offset += padded;
    }

    const total_size = current_offset;

    const max_output_size = comptime blk: {
        const ds = @sizeOf(OffsetTable) + NUM_TABLES * @sizeOf(TableRecord);
        break :blk ds + padTo4(@sizeOf(Os2)) + padTo4(@sizeOf(Cmap)) +
            padTo4(num_glyphs * MAX_GLYPH_SIZE) + padTo4(@sizeOf(Head)) +
            padTo4(@sizeOf(Hhea)) + padTo4(hmtx_size) +
            padTo4((num_glyphs + 1) * 4) + padTo4(@sizeOf(Maxp)) +
            padTo4(@sizeOf(Name)) + padTo4(@sizeOf(Post));
    };
    var out: [max_output_size]u8 = undefined;
    @memset(&out, 0);

    // Write offset table header
    const sr = blk: {
        var p: u16 = 1;
        while (p * 2 <= NUM_TABLES) p *= 2;
        break :blk p * 16;
    };
    const offset_table = OffsetTable{
        .sf_version      = Big(u32).from(0x00010000),
        .num_tables      = Big(u16).from(NUM_TABLES),
        .search_range    = Big(u16).from(sr),
        .entry_selector  = Big(u16).from(@intCast(math.log2_int(u16, sr / 16))),
        .range_shift     = Big(u16).from(NUM_TABLES * 16 - sr),
    };
    @memcpy(out[0..@sizeOf(OffsetTable)], mem.asBytes(&offset_table));

    // Write table records and data
    var data_offset: u32 = table_dir_size;
    for (0..NUM_TABLES) |i| {
        const rec = TableRecord{
            .tag      = table_buf[i].tag.*,
            .checksum = Big(u32).from(calcChecksum(table_buf[i].data)),
            .offset   = Big(u32).from(data_offset),
            .length   = Big(u32).from(@intCast(table_buf[i].data.len)),
        };
        const rec_off = @sizeOf(OffsetTable) + i * @sizeOf(TableRecord);
        @memcpy(out[rec_off..][0..@sizeOf(TableRecord)], mem.asBytes(&rec));

        @memcpy(out[data_offset..][0..table_buf[i].data.len], table_buf[i].data);
        data_offset += table_buf[i].padded_len;
    }

    // Fix head.checksumAdjustment
    const whole_checksum = calcChecksum(out[0..total_size]);
    // TODO: fix 3 magic num
    const head_rec_off = @sizeOf(OffsetTable) + 3 * @sizeOf(TableRecord); // table index 3 is head
    const head_rec: *const TableRecord = @ptrCast(@alignCast(out[head_rec_off..][0..@sizeOf(TableRecord)]));
    const head_data_offset = mem.bigToNative(u32, @bitCast(head_rec.offset.raw));
    writeBytes(out[head_data_offset + @offsetOf(Head, "checksum_adjustment") ..][0..4], 0xB1B0AFBA -% whole_checksum);

    const root = try Io.Dir.cwd().openDir(io, "/", .{});
    try root.createDirPath(io, font_dir, .{});
    const font_file = try root.createFileAbsolute(io, font_path, .{});
    try font_file.writePositionalAll(io, out[0..total_size], 0);
}

fn padTo4(comptime n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
}

fn writeBytes(buf: []u8, v: anytype) void {
    const bytes = std.mem.asBytes(&v);
    @memcpy(buf[0..bytes.len], bytes);
}

fn calcChecksum(data: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 4 <= data.len) : (i += 4) {
        sum +%= (@as(u32, data[i]) << 24) |
            (@as(u32, data[i + 1]) << 16) |
            (@as(u32, data[i + 2]) << 8) |
            @as(u32, data[i + 3]);
    }
    // Handle trailing bytes (pad with zeros)
    if (i < data.len) {
        var last: u32 = 0;
        var shift: u5 = 24;
        while (i < data.len) : (i += 1) {
            last |= @as(u32, data[i]) << shift;
            shift -= 8;
        }
        sum +%= last;
    }
    return sum;
}

const Rect = struct {
    x0: i16,
    y0: i16,
    x1: i16,
    y1: i16,
};

fn getGlyphRects(mask: usize, rects: *[MAX_CONTOURS]Rect, rect_w: i16, rect_h: i16, ascent: i16) u8 {
    var count: u8 = 0;

    for (0..(cell_cols * cell_rows)) |idx| {
        if ((mask >> @intCast(idx)) & 1 == 0) continue;
        const col: i16 = @intCast(idx % cell_cols);
        const row: i16 = @intCast(idx / cell_cols);
        const x0 = col * rect_w;
        const y0 = ascent - (row + 1) * rect_h;
        rects[count] = .{
            .x0 = x0,
            .y0 = y0,
            .x1 = x0 + rect_w,
            .y1 = y0 + rect_h,
        };
        count += 1;
    }

    return count;
}

/// Returns the number of bytes written.
fn compileGlyph(mask: usize, out: []u8, rect_w: i16, rect_h: i16, ascent: i16) usize {
    if (mask == 0) return 0; // .notdef: empty

    var rects: [MAX_CONTOURS]Rect = undefined;
    const n_rects = getGlyphRects(mask, &rects, rect_w, rect_h, ascent);
    const n_points: u16 = @as(u16, n_rects) * 4;

    // Compute bounding box
    var xmin: i16 = math.maxInt(i16);
    var ymin: i16 = math.maxInt(i16);
    var xmax: i16 = math.minInt(i16);
    var ymax: i16 = math.minInt(i16);
    for (rects[0..n_rects]) |r| {
        xmin = @min(xmin, r.x0);
        ymin = @min(ymin, r.y0);
        xmax = @max(xmax, r.x1);
        ymax = @max(ymax, r.y1);
    }

    var off: usize = 0;

    // Header: numberOfContours, xMin, yMin, xMax, yMax
    writeBytes(out[off..][0..2], @intCast(n_rects));
    off += 2;
    writeBytes(out[off..][0..2], xmin);
    off += 2;
    writeBytes(out[off..][0..2], ymin);
    off += 2;
    writeBytes(out[off..][0..2], xmax);
    off += 2;
    writeBytes(out[off..][0..2], ymax);
    off += 2;

    // endPtsOfContours
    for (0..n_rects) |i| {
        writeBytes(out[off..][0..2], @intCast(i * 4 + 3));
        off += 2;
    }

    // instructionLength = 0
    writeBytes(out[off..][0..2], 0);
    off += 2;

    // Flags and coordinates
    // Each rect has 4 points: (x0,y0), (x0,y1), (x1,y1), (x1,y0)
    // All points are on-curve (flag bit 0 = 1)
    // We encode coordinates as deltas from the previous point.

    // First pass: compute all absolute coordinates
    var abs_x: [MAX_CONTOURS * 4]i16 = undefined;
    var abs_y: [MAX_CONTOURS * 4]i16 = undefined;
    for (0..n_rects) |i| {
        const r = rects[i];
        abs_x[i * 4 + 0] = r.x0;
        abs_y[i * 4 + 0] = r.y0;
        abs_x[i * 4 + 1] = r.x0;
        abs_y[i * 4 + 1] = r.y1;
        abs_x[i * 4 + 2] = r.x1;
        abs_y[i * 4 + 2] = r.y1;
        abs_x[i * 4 + 3] = r.x1;
        abs_y[i * 4 + 3] = r.y0;
    }

    // Compute deltas
    var dx: [MAX_CONTOURS * 4]i16 = undefined;
    var dy: [MAX_CONTOURS * 4]i16 = undefined;
    dx[0] = abs_x[0];
    dy[0] = abs_y[0];
    for (1..n_points) |i| {
        dx[i] = abs_x[i] - abs_x[i - 1];
        dy[i] = abs_y[i] - abs_y[i - 1];
    }

    // Compute flags based on delta values
    var flags: [MAX_CONTOURS * 4]u8 = undefined;
    for (0..n_points) |i| {
        var f: u8 = 0x01; // on-curve
        // X
        if (dx[i] == 0) {
            f |= 0x10; // xSame (delta=0 when xShort=0)
        } else if (dx[i] >= -255 and dx[i] <= 255) {
            f |= 0x02; // xShort
            if (dx[i] > 0) f |= 0x10; // positive
        }
        // Y
        if (dy[i] == 0) {
            f |= 0x20; // ySame
        } else if (dy[i] >= -255 and dy[i] <= 255) {
            f |= 0x04; // yShort
            if (dy[i] > 0) f |= 0x20; // positive
        }
        flags[i] = f;
    }

    // Write flags (no repeat optimization — not needed for correctness)
    for (0..n_points) |i| {
        out[off] = flags[i];
        off += 1;
    }

    // Write x deltas
    for (0..n_points) |i| {
        const d = dx[i];
        if (d == 0) {
            // nothing
        } else if (flags[i] & 0x02 != 0) {
            // short
            out[off] = @intCast(if (d > 0) d else -d);
            off += 1;
        } else {
            // i16
            writeBytes(out[off..][0..2], d);
            off += 2;
        }
    }

    // Write y deltas
    for (0..n_points) |i| {
        const d = dy[i];
        if (d == 0) {
            // nothing
        } else if (flags[i] & 0x04 != 0) {
            // short
            out[off] = @intCast(if (d > 0) d else -d);
            off += 1;
        } else {
            // i16
            writeBytes(out[off..][0..2], d);
            off += 2;
        }
    }

    // Pad to 2-byte alignment
    if (off % 2 != 0) {
        out[off] = 0;
        off += 1;
    }

    return off;
}

fn Big(comptime T: type) type {
    return extern struct {
        raw: [@sizeOf(T)]u8,

        pub fn from(val: T) @This() {
            return .{ .raw = @bitCast(std.mem.nativeToBig(T, val)) };
        }
    };
}

// Table structs based on OpenType specification:
// https://learn.microsoft.com/en-us/typography/opentype/spec/

const Head = extern struct {
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

const Hhea = extern struct {
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

const Maxp = extern struct {
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

const Os2 = extern struct {
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

const Post = extern struct {
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

const NameRecord = extern struct {
    platform_id: Big(u16),
    encoding_id: Big(u16),
    language_id: Big(u16),
    name_id: Big(u16),
    length: Big(u16),
    string_offset: Big(u16),
};

const Name = extern struct {
    format: Big(u16),
    count: Big(u16),
    string_offset: Big(u16),
    records: [5]NameRecord,
    string_data: [150]u8, // UTF-16BE encoded strings (75 ASCII chars)
};

const CmapEncodingRecord = extern struct {
    platform_id: Big(u16),
    encoding_id: Big(u16),
    subtable_offset: Big(u32),
};

// Format 4 subtable with 1 sentinel segment (specific to this font's layout)
const CmapFormat4 = extern struct {
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
const CmapFormat12 = extern struct {
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

const Cmap = extern struct {
    version: Big(u16),
    num_tables: Big(u16),
    encoding_records: [3]CmapEncodingRecord,
    format4: CmapFormat4,
    format12: CmapFormat12,
};

const OffsetTable = extern struct {
    sf_version: Big(u32),
    num_tables: Big(u16),
    search_range: Big(u16),
    entry_selector: Big(u16),
    range_shift: Big(u16),
};

const TableRecord = extern struct {
    tag: [4]u8,
    checksum: Big(u32),
    offset: Big(u32),
    length: Big(u32),
};

// hmtx table: variable-length, per-glyph metric record
const LongHorMetric = extern struct {
    advance_width: Big(u16),
    lsb: Big(i16),
};

const Glyf = extern struct {
    buf: [num_glyphs * MAX_GLYPH_SIZE]u8,
    len: usize,
};

const Loca = extern struct {
    buf: [(num_glyphs + 1) * 4]u8,
};

const Hmtx = extern struct {
    buf: [hmtx_size]u8,
};

fn buildHead(metrics: Metrics, rect_w: i16, rect_h: i16) Head {
    return .{
        .version_major       = Big(u16).from(1),
        .version_minor       = Big(u16).from(0),
        .font_revision       = Big(u32).from(0x00010000),
        .checksum_adjustment = Big(u32).from(0), // filled later
        .magic_number        = Big(u32).from(0x5F0F3CF5),
        .flags               = Big(u16).from(0x000B),
        .units_per_em        = Big(u16).from(@intCast(metrics.upm)),
        .created             = Big(i64).from(0),
        .modified            = Big(i64).from(0),
        .x_min               = Big(i16).from(-rect_w),
        .y_min               = Big(i16).from(-metrics.descent - rect_h),
        .x_max               = Big(i16).from(@as(i16, @intCast(metrics.advance)) + rect_w),
        .y_max               = Big(i16).from(metrics.ascent + rect_h),
        .mac_style           = Big(u16).from(0),
        .lowest_rec_ppem     = Big(u16).from(8),
        .font_direction_hint = Big(i16).from(2),
        .index_to_loc_format = Big(i16).from(1), // long
        .glyph_data_format   = Big(i16).from(0),
    };
}

fn buildHhea(metrics: Metrics, rect_w: i16) Hhea {
    return .{
        .major_version          = Big(u16).from(1),
        .minor_version          = Big(u16).from(0),
        .ascender               = Big(i16).from(metrics.ascent),
        .descender              = Big(i16).from(-metrics.descent),
        .line_gap               = Big(i16).from(metrics.line_gap),
        .advance_width_max      = Big(u16).from(metrics.advance),
        .min_left_side_bearing  = Big(i16).from(0),
        .min_right_side_bearing = Big(i16).from(0),
        .x_max_extent           = Big(i16).from(@as(i16, @intCast(metrics.advance)) + rect_w),
        .caret_slope_rise       = Big(i16).from(1),
        .caret_slope_run        = Big(i16).from(0),
        .caret_offset           = Big(i16).from(0),
        .reserved1              = Big(i16).from(0),
        .reserved2              = Big(i16).from(0),
        .reserved3              = Big(i16).from(0),
        .reserved4              = Big(i16).from(0),
        .metric_data_format     = Big(i16).from(0),
        .number_of_h_metrics    = Big(u16).from(1),
    };
}

fn buildMaxp() Maxp {
    return .{
        .version                  = Big(u32).from(0x00010000),
        .num_glyphs               = Big(u16).from(@intCast(num_glyphs)),
        .max_points               = Big(u16).from(MAX_CONTOURS * 4),
        .max_contours             = Big(u16).from(MAX_CONTOURS),
        .max_composite_points     = Big(u16).from(0),
        .max_composite_contours   = Big(u16).from(0),
        .max_zones                = Big(u16).from(1),
        .max_twilight_points      = Big(u16).from(0),
        .max_storage              = Big(u16).from(0),
        .max_function_defs        = Big(u16).from(0),
        .max_instruction_defs     = Big(u16).from(0),
        .max_stack_elements       = Big(u16).from(0),
        .max_size_of_instructions = Big(u16).from(0),
        .max_component_elements   = Big(u16).from(0),
        .max_component_depth      = Big(u16).from(0),
    };
}

fn buildOs2(metrics: Metrics) Os2 {
    return .{
        .version                = Big(u16).from(4),
        .x_avg_char_width       = Big(i16).from(@intCast(metrics.advance)),
        .us_weight_class        = Big(u16).from(400), // Normal
        .us_width_class         = Big(u16).from(5), // Medium
        .fs_type                = Big(u16).from(0),
        .y_subscript_x_size     = Big(i16).from(0),
        .y_subscript_y_size     = Big(i16).from(0),
        .y_subscript_x_offset   = Big(i16).from(0),
        .y_subscript_y_offset   = Big(i16).from(0),
        .y_superscript_x_size   = Big(i16).from(0),
        .y_superscript_y_size   = Big(i16).from(0),
        .y_superscript_x_offset = Big(i16).from(0),
        .y_superscript_y_offset = Big(i16).from(0),
        .y_strikeout_size       = Big(i16).from(0),
        .y_strikeout_position   = Big(i16).from(0),
        .s_family_class         = Big(i16).from(0),
        .panose                 = .{0} ** 10,
        .ul_unicode_range1      = Big(u32).from(0),
        .ul_unicode_range2      = Big(u32).from(0),
        .ul_unicode_range3      = Big(u32).from(0),
        .ul_unicode_range4      = Big(u32).from(0),
        .ach_vend_id            = "    ".*,
        .fs_selection           = Big(u16).from(0x0040), // Regular
        .us_first_char_index    = Big(u16).from(0),
        .us_last_char_index     = Big(u16).from(0xFFFF),
        .s_typo_ascender        = Big(i16).from(metrics.ascent),
        .s_typo_descender       = Big(i16).from(-metrics.descent),
        .s_typo_line_gap        = Big(i16).from(metrics.line_gap),
        .us_win_ascent          = Big(u16).from(@intCast(metrics.ascent)),
        .us_win_descent         = Big(u16).from(@intCast(metrics.descent)),
        .ul_code_page_range1    = Big(u32).from(0),
        .ul_code_page_range2    = Big(u32).from(0),
        .sx_height              = Big(i16).from(0),
        .s_cap_height           = Big(i16).from(0),
        .us_default_char        = Big(u16).from(0),
        .us_break_char          = Big(u16).from(0x0020),
        .us_max_context         = Big(u16).from(1),
    };
}

fn buildPost() Post {
    return .{
        .version             = Big(u32).from(0x00030000), // format 3.0 (no glyph names)
        .italic_angle        = Big(i32).from(0),
        .underline_position  = Big(i16).from(0),
        .underline_thickness = Big(i16).from(0),
        .is_fixed_pitch      = Big(u32).from(0),
        .min_mem_type42      = Big(u32).from(0),
        .max_mem_type42      = Big(u32).from(0),
        .min_mem_type1       = Big(u32).from(0),
        .max_mem_type1       = Big(u32).from(0),
    };
}

fn buildGlyf(glyf: *Glyf, loca: *Loca, ascent: i16, rect_w: i16, rect_h: i16) void {
    glyf.len = 0;
    for (0..num_glyphs) |mask| {
        writeBytes(loca.buf[mask * 4 ..][0..4], glyf.len);
        const size = compileGlyph(@intCast(mask), glyf.buf[glyf.len..], rect_w, rect_h, ascent);
        glyf.len += @intCast(size);
    }
    // Sentinel loca entry TODO: what does this mean?
    writeBytes(loca.buf[num_glyphs * 4 ..][0..4], glyf.len);
}

fn buildHmtx(advance: u16) Hmtx {
    var hmtx: Hmtx = .{};
    const metric = LongHorMetric{
        .advance_width = Big(u16).from(advance),
        .lsb           = Big(i16).from(0),
    };
    @memcpy(hmtx.buf[0..@sizeOf(LongHorMetric)], mem.asBytes(&metric));
    // Remaining glyphs: just lsb (i16 each), all zero
    @memset(hmtx.buf[@sizeOf(LongHorMetric)..], 0);
    return hmtx;
}

fn buildCmap() Cmap {
    const codepoint_end = config.codepoint_start + num_glyphs - 1;
    return .{
        .version          = Big(u16).from(0),
        .num_tables       = Big(u16).from(3),
        .encoding_records = .{
            .{ .platform_id = Big(u16).from(0), .encoding_id = Big(u16).from(3),  .subtable_offset = Big(u32).from(28) }, // Unicode BMP -> format 4
            .{ .platform_id = Big(u16).from(3), .encoding_id = Big(u16).from(1),  .subtable_offset = Big(u32).from(28) }, // Windows UCS-2 -> format 4
            .{ .platform_id = Big(u16).from(3), .encoding_id = Big(u16).from(10), .subtable_offset = Big(u32).from(52) }, // Windows UCS-4 -> format 12
        },
        .format4 = .{
            .format          = Big(u16).from(4),
            .length          = Big(u16).from(24),
            .language        = Big(u16).from(0),
            .seg_count_x2    = Big(u16).from(2), // 1 sentinel segment
            .search_range    = Big(u16).from(2),
            .entry_selector  = Big(u16).from(0),
            .range_shift     = Big(u16).from(0),
            .end_code        = Big(u16).from(0xFFFF),
            .reserved_pad    = Big(u16).from(0),
            .start_code      = Big(u16).from(0xFFFF),
            .id_delta        = Big(i16).from(1),
            .id_range_offset = Big(u16).from(0),
        },
        .format12 = .{
            .format          = Big(u16).from(12),
            .reserved        = Big(u16).from(0),
            .length          = Big(u32).from(28), // 16 header + 12 per group
            .language        = Big(u32).from(0),
            .num_groups      = Big(u32).from(1),
            .start_char_code = Big(u32).from(config.codepoint_start),
            .end_char_code   = Big(u32).from(codepoint_end),
            .start_glyph_id  = Big(u32).from(0),
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

fn buildName() Name {
    const be = Big(u16).from;
    return .{
        .format        = be(0),
        .count         = be(5),
        .string_offset = be(@sizeOf(Name) - 150), // header + records
        .records       = .{
            .{ .platform_id = be(3), .encoding_id = be(1), .language_id = be(0), .name_id = be(1), .length = be(38), .string_offset = be(0) },   // family
            .{ .platform_id = be(3), .encoding_id = be(1), .language_id = be(0), .name_id = be(2), .length = be(14), .string_offset = be(38) },  // style
            .{ .platform_id = be(3), .encoding_id = be(1), .language_id = be(0), .name_id = be(4), .length = be(38), .string_offset = be(52) },  // full name
            .{ .platform_id = be(3), .encoding_id = be(1), .language_id = be(0), .name_id = be(5), .length = be(22), .string_offset = be(90) },  // version
            .{ .platform_id = be(3), .encoding_id = be(1), .language_id = be(0), .name_id = be(6), .length = be(38), .string_offset = be(112) }, // postscript name
        },
        .string_data = utf16be("Fidelitty Glyph Set")
            ++ utf16be("Regular")
            ++ utf16be("Fidelitty Glyph Set")
            ++ utf16be("Version 1.0")
            ++ utf16be("Fidelitty-Glyph-Set"),
    };
}
