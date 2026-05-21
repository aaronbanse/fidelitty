//! Assembles the table data into a complete OpenType file on disk.

const std = @import("std");
const mem = std.mem;
const math = std.math;
const Io = std.Io;

const common = @import("common.zig");
const Big = common.Big;
const fixed16_16 = common.fixed16_16;
const MAX_GLYPH_SIZE = common.MAX_GLYPH_SIZE;

const dataset = @import("../dataset.zig");
const cell_w = dataset.cell_w;
const cell_h = dataset.cell_h;

const font_config = @import("font_config");
const font_dir_from_home = font_config.font_dir_from_home;
const font_name = font_config.font_name;

const tables_mod = @import("tables.zig");
const num_glyphs_incl_notdef = tables_mod.num_glyphs_incl_notdef;
const Os2 = tables_mod.Os2;
const Cmap = tables_mod.Cmap;
const Glyf = tables_mod.Glyf;
const Head = tables_mod.Head;
const Hhea = tables_mod.Hhea;
const Hmtx = tables_mod.Hmtx;
const Loca = tables_mod.Loca;
const Maxp = tables_mod.Maxp;
const Name = tables_mod.Name;
const Post = tables_mod.Post;
const OffsetTable = tables_mod.OffsetTable;
const TableRecord = tables_mod.TableRecord;
const buildOs2 = tables_mod.buildOs2;
const buildCmap = tables_mod.buildCmap;
const buildGlyfLoca = tables_mod.buildGlyfLoca;
const buildHead = tables_mod.buildHead;
const buildHhea = tables_mod.buildHhea;
const buildHmtx = tables_mod.buildHmtx;
const buildMaxp = tables_mod.buildMaxp;
const buildName = tables_mod.buildName;
const buildPost = tables_mod.buildPost;
const UserFontMetrics = @import("metrics.zig").UserFontMetrics;

pub fn generateFromMetrics(
    io: Io,
    allocator: mem.Allocator,
    metrics: UserFontMetrics,
    user_home_dir: []const u8,
) ![]const u8 {
    // Dims of rectangles used to render bitmap
    const glyph_rect_w = @divFloor(metrics.advance_width, cell_w);
    const glyph_rect_h = @divFloor(metrics.ascent + (-metrics.descent), cell_h);

    const os2 = buildOs2(metrics);
    const cmap = buildCmap();

    // glyf and loca are large, these must be heap-allocated
    // to avoid stack overflow. (Woah he said the thing!)
    const glyf = try allocator.create(Glyf);
    defer allocator.destroy(glyf);
    const loca = try allocator.create(Loca);
    defer allocator.destroy(loca);
    buildGlyfLoca(
        glyf,
        loca,
        metrics.descent,
        @intCast(glyph_rect_w),
        @intCast(glyph_rect_h),
    );

    const head = buildHead(metrics, @intCast(glyph_rect_w), @intCast(glyph_rect_h));
    const hhea = buildHhea(metrics, @intCast(glyph_rect_w));
    const hmtx = buildHmtx(metrics.advance_width);
    const maxp = buildMaxp();
    const name = buildName();
    const post = buildPost();

    const Table = struct {
        tag: *const [4]u8,
        data: []const u8,
        padded_len: u32,
    };

    // The OpenType spec requires the table directory to be in tag-alphabetical
    // order. Though not required, we adopt this ordering throught the rest of
    // the codebase for simplicity.
    var tables = [_]Table{
        .{ .tag = "OS/2", .data = mem.asBytes(&os2), .padded_len = undefined },
        .{ .tag = "cmap", .data = mem.asBytes(&cmap), .padded_len = undefined },
        .{ .tag = "glyf", .data = glyf.buf[0..glyf.len], .padded_len = undefined },
        .{ .tag = "head", .data = mem.asBytes(&head), .padded_len = undefined },
        .{ .tag = "hhea", .data = mem.asBytes(&hhea), .padded_len = undefined },
        .{ .tag = "hmtx", .data = mem.asBytes(&hmtx), .padded_len = undefined },
        .{ .tag = "loca", .data = mem.asBytes(loca), .padded_len = undefined },
        .{ .tag = "maxp", .data = mem.asBytes(&maxp), .padded_len = undefined },
        .{ .tag = "name", .data = mem.asBytes(&name), .padded_len = undefined },
        .{ .tag = "post", .data = mem.asBytes(&post), .padded_len = undefined },
    };

    const table_dir_size: u32 = @sizeOf(OffsetTable) + tables.len * @sizeOf(TableRecord);

    var current_offset = table_dir_size;
    for (&tables) |*t| {
        t.padded_len = @intCast((t.data.len + 3) & ~@as(usize, 3));
        current_offset += t.padded_len;
    }

    const total_size = current_offset;

    const max_output_size = comptime blk: {
        const ds = @sizeOf(OffsetTable) + tables.len * @sizeOf(TableRecord);
        break :blk ds + padTo4(@sizeOf(Os2)) + padTo4(@sizeOf(Cmap)) +
            padTo4(num_glyphs_incl_notdef * MAX_GLYPH_SIZE) + padTo4(@sizeOf(Head)) +
            padTo4(@sizeOf(Hhea)) + padTo4(@sizeOf(Hmtx)) +
            padTo4(@sizeOf(Loca)) + padTo4(@sizeOf(Maxp)) +
            padTo4(@sizeOf(Name)) + padTo4(@sizeOf(Post));
    };
    const out = try allocator.alloc(u8, max_output_size);
    defer allocator.free(out);
    @memset(out, 0);

    // Write offset table header
    const sr = blk: {
        var p: u16 = 1;
        while (p * 2 <= tables.len) p *= 2;
        break :blk p * 16;
    };
    const offset_table = OffsetTable{
        .sf_version = Big(u32).from(fixed16_16(1, 0)),
        .num_tables = Big(u16).from(tables.len),
        .search_range = Big(u16).from(sr),
        .entry_selector = Big(u16).from(@intCast(math.log2_int(u16, sr / 16))),
        .range_shift = Big(u16).from(@intCast(tables.len * 16 - sr)),
    };
    @memcpy(out[0..@sizeOf(OffsetTable)], mem.asBytes(&offset_table));

    // Write table records and data
    var data_offset: u32 = table_dir_size;
    for (0..tables.len) |i| {
        const rec = TableRecord{
            .tag = tables[i].tag.*,
            .checksum = Big(u32).from(calcChecksum(tables[i].data)),
            .offset = Big(u32).from(data_offset),
            .length = Big(u32).from(@intCast(tables[i].data.len)),
        };
        const rec_off = @sizeOf(OffsetTable) + i * @sizeOf(TableRecord);
        @memcpy(out[rec_off..][0..@sizeOf(TableRecord)], mem.asBytes(&rec));

        @memcpy(out[data_offset..][0..tables[i].data.len], tables[i].data);
        data_offset += tables[i].padded_len;
    }

    // Fix head.checksumAdjustment
    const whole_checksum = calcChecksum(out[0..total_size]);
    // TODO: fix 3 magic num
    const head_rec_off = @sizeOf(OffsetTable) + 3 * @sizeOf(TableRecord); // table index 3 is head
    const head_rec: *const TableRecord = @ptrCast(@alignCast(out[head_rec_off..][0..@sizeOf(TableRecord)]));
    const head_data_offset = mem.bigToNative(u32, @bitCast(head_rec.offset.raw));
    Big(u32).from(0xB1B0AFBA -% whole_checksum).write(out[head_data_offset + @offsetOf(Head, "checksum_adjustment") ..]);

    const home = try Io.Dir.cwd().openDir(io, user_home_dir, .{});
    const font_dir = try home.createDirPathOpen(io, font_dir_from_home, .{});
    const font_file = try font_dir.createFile(io, font_name, .{});
    try font_file.writePositionalAll(io, out[0..total_size], 0);

    // TODO: does std expose a more elegant way to do this?
    var installed_path_buf: [256]u8 = undefined;
    const intalled_path_size = try font_file.realPath(io, &installed_path_buf);
    const installed_path: []u8 = try allocator.alloc(u8, intalled_path_size);
    @memcpy(installed_path, installed_path_buf[0..intalled_path_size]);
    return installed_path;
}

fn padTo4(comptime n: usize) usize {
    return (n + 3) & ~@as(usize, 3);
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
