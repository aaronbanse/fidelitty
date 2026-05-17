//! Assembles the table data into a complete OpenType file on disk.

const std = @import("std");
const mem = std.mem;
const math = std.math;
const Io = std.Io;
const config = @import("config");

const common = @import("common.zig");
const Big = common.Big;
const writeBytes = common.writeBytes;
const num_glyphs = common.num_glyphs;
const MAX_GLYPH_SIZE = common.MAX_GLYPH_SIZE;
const hmtx_size = common.hmtx_size;
const cell_w = common.cell_w;
const cell_h = common.cell_h;

const tables_mod = @import("tables.zig");
const Head = tables_mod.Head;
const Hhea = tables_mod.Hhea;
const Maxp = tables_mod.Maxp;
const Os2 = tables_mod.Os2;
const Post = tables_mod.Post;
const Cmap = tables_mod.Cmap;
const Name = tables_mod.Name;
const Glyf = tables_mod.Glyf;
const Loca = tables_mod.Loca;
const OffsetTable = tables_mod.OffsetTable;
const TableRecord = tables_mod.TableRecord;
const buildHead = tables_mod.buildHead;
const buildHhea = tables_mod.buildHhea;
const buildMaxp = tables_mod.buildMaxp;
const buildOs2 = tables_mod.buildOs2;
const buildPost = tables_mod.buildPost;
const buildHmtx = tables_mod.buildHmtx;
const buildCmap = tables_mod.buildCmap;
const buildName = tables_mod.buildName;

const buildGlyf = @import("glyf.zig").buildGlyf;
const UserFontMetrics = @import("metrics.zig").UserFontMetrics;

pub fn generateFromMetrics(io: Io, metrics: UserFontMetrics) !void {
    // MAJOR TODO: depend on glyph.zig for all of our dataset generation,
    // Derive bit ordering and everything from that file. one source of truth

    const glyph_rect_w = @divExact(metrics.advance_width, cell_w);
    const glyph_rect_h = @divExact(metrics.ascent + metrics.descent, cell_h);

    var glyf: Glyf = undefined;
    var loca: Loca = undefined;
    buildGlyf(&glyf, &loca, metrics.ascent, @intCast(glyph_rect_w), @intCast(glyph_rect_h));

    const head = buildHead(metrics, @intCast(glyph_rect_w), @intCast(glyph_rect_h));
    const hhea = buildHhea(metrics, @intCast(glyph_rect_w));
    const maxp = buildMaxp();
    const os2  = buildOs2(metrics);
    const post = buildPost();
    const hmtx = buildHmtx(metrics.advance_width);
    const cmap = buildCmap();
    const name = buildName();

    const Table = struct {
        tag: *const [4]u8,
        data: []const u8,
        padded_len: u32,
    };

    var tables = [_]Table {
        .{ .tag = "OS/2", .data = mem.asBytes(&os2),     .padded_len = undefined },
        .{ .tag = "cmap", .data = mem.asBytes(&cmap),    .padded_len = undefined },
        .{ .tag = "glyf", .data = glyf.buf[0..glyf.len], .padded_len = undefined },
        .{ .tag = "head", .data = mem.asBytes(&head),    .padded_len = undefined },
        .{ .tag = "hhea", .data = mem.asBytes(&hhea),    .padded_len = undefined },
        .{ .tag = "hmtx", .data = &hmtx.buf,             .padded_len = undefined },
        .{ .tag = "loca", .data = &loca.buf,             .padded_len = undefined },
        .{ .tag = "maxp", .data = mem.asBytes(&maxp),    .padded_len = undefined },
        .{ .tag = "name", .data = mem.asBytes(&name),    .padded_len = undefined },
        .{ .tag = "post", .data = mem.asBytes(&post),    .padded_len = undefined },
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
        while (p * 2 <= tables.len) p *= 2;
        break :blk p * 16;
    };
    const offset_table = OffsetTable{
        .sf_version = Big(u32).from(0x00010000),
        .num_tables = Big(u16).from(tables.len),
        .search_range = Big(u16).from(sr),
        .entry_selector = Big(u16).from(@intCast(math.log2_int(u16, sr / 16))),
        .range_shift = Big(u16).from(tables.len * 16 - sr),
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
    writeBytes(out[head_data_offset + @offsetOf(Head, "checksum_adjustment") ..][0..4], 0xB1B0AFBA -% whole_checksum);

    const root = try Io.Dir.cwd().openDir(io, "/", .{});
    const font_dir = try root.createDirPathOpen(io, config.font_dir, .{});
    const font_file = try font_dir.createFile(io, config.font_name, .{});
    try font_file.writePositionalAll(io, out[0..total_size], 0);
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
