//! Assembles the table data into a complete OpenType file on disk.

const std = @import("std");
const mem = std.mem;
const Io = std.Io;

const common = @import("common.zig");
const Big = common.Big;
const fixed16_16 = common.fixed16_16;

const dataset = @import("../dataset.zig");
const cell_w = dataset.cell_w;
const cell_h = dataset.cell_h;

const font_config = @import("font_config");
const font_dir_from_home = font_config.font_dir_from_home;
const font_name = font_config.font_name;

const tables_mod = @import("tables.zig");
const Glyf = tables_mod.Glyf;
const Head = tables_mod.Head;
const Loca = tables_mod.Loca;
const OffsetTable = tables_mod.OffsetTable;
const TableRecord = tables_mod.TableRecord;
const buildOs2 = tables_mod.buildOs2;
const buildCmap = tables_mod.buildCmap;
const buildGlyf = tables_mod.buildGlyf;
const buildHead = tables_mod.buildHead;
const buildHhea = tables_mod.buildHhea;
const buildHmtx = tables_mod.buildHmtx;
const buildMaxp = tables_mod.buildMaxp;
const buildName = tables_mod.buildName;
const buildPost = tables_mod.buildPost;
const buildOffsetTable = tables_mod.buildOffsetTable;
const FontMetrics = @import("metrics.zig").FontMetrics;

pub fn writeFont(
    io: Io,
    allocator: mem.Allocator,
    metrics: FontMetrics,
    user_home_dir: []const u8,
) ![]const u8 {
    const data = try generateFontData(allocator, metrics);
    defer allocator.free(data);

    const home = try Io.Dir.cwd().openDir(io, user_home_dir, .{});
    defer home.close(io);
    const font_dir = try home.createDirPathOpen(io, font_dir_from_home, .{});
    defer font_dir.close(io);
    const font_file = try font_dir.createFile(io, font_name, .{});
    defer font_file.close(io);
    try font_file.writePositionalAll(io, data, 0);

    var installed_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const installed_path_size = try font_file.realPath(io, &installed_path_buf);
    return allocator.dupe(u8, installed_path_buf[0..installed_path_size]);
}

// Generates the OpenType font data. User must free returned memory.
fn generateFontData(allocator: mem.Allocator, metrics: FontMetrics) ![]const u8 {
    const glyph_rect_w = @divFloor(metrics.advance_width, cell_w);
    const glyph_rect_h = @divFloor(metrics.ascent + (-metrics.descent), cell_h);

    const os2 = buildOs2(metrics);
    const cmap = buildCmap();

    // glyf and loca are large, these must be heap-allocated
    // to avoid stack overflow.
    const glyf = try allocator.create(Glyf);
    defer allocator.destroy(glyf);
    const loca = try allocator.create(Loca);
    defer allocator.destroy(loca);
    buildGlyf(glyf, metrics.descent, @intCast(glyph_rect_w), @intCast(glyph_rect_h));

    // Flatten glyf entries into a tightly-packed byte buffer; loca gets each
    // entry's start offset, plus the trailing sentinel, as a side effect.
    const glyf_flat = try glyf.flatten(allocator, loca);
    defer allocator.free(glyf_flat);

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
        offset: u32,
    };

    // The OpenType spec requires the table directory to be in tag-alphabetical
    // order. Though not required, we adopt this ordering throught the rest of
    // the codebase for simplicity.
    var tables = [_]Table{
        .{ .tag = "OS/2", .data = mem.asBytes(&os2), .padded_len = undefined, .offset = undefined },
        .{ .tag = "cmap", .data = mem.asBytes(&cmap), .padded_len = undefined, .offset = undefined },
        .{ .tag = "glyf", .data = glyf_flat, .padded_len = undefined, .offset = undefined },
        .{ .tag = "head", .data = mem.asBytes(&head), .padded_len = undefined, .offset = undefined },
        .{ .tag = "hhea", .data = mem.asBytes(&hhea), .padded_len = undefined, .offset = undefined },
        .{ .tag = "hmtx", .data = mem.asBytes(&hmtx), .padded_len = undefined, .offset = undefined },
        .{ .tag = "loca", .data = mem.asBytes(loca), .padded_len = undefined, .offset = undefined },
        .{ .tag = "maxp", .data = mem.asBytes(&maxp), .padded_len = undefined, .offset = undefined },
        .{ .tag = "name", .data = mem.asBytes(&name), .padded_len = undefined, .offset = undefined },
        .{ .tag = "post", .data = mem.asBytes(&post), .padded_len = undefined, .offset = undefined },
    };

    const table_dir_size: u32 = @sizeOf(OffsetTable) + tables.len * @sizeOf(TableRecord);

    var current_offset = table_dir_size;
    for (&tables) |*t| {
        t.padded_len = @intCast((t.data.len + 3) & ~@as(usize, 3));
        t.offset = current_offset;
        current_offset += t.padded_len;
    }

    const total_size = current_offset;

    const data = try allocator.alloc(u8, total_size);
    @memset(data, 0);

    const offset_table = buildOffsetTable(tables.len);
    @memcpy(data[0..@sizeOf(OffsetTable)], mem.asBytes(&offset_table));

    for (tables, 0..) |t, i| {
        const rec = TableRecord{
            .tag = t.tag.*,
            .checksum = Big(u32).from(calcChecksum(t.data)),
            .offset = Big(u32).from(t.offset),
            .length = Big(u32).from(@intCast(t.data.len)),
        };
        const rec_off = @sizeOf(OffsetTable) + i * @sizeOf(TableRecord);
        @memcpy(data[rec_off..][0..@sizeOf(TableRecord)], mem.asBytes(&rec));

        @memcpy(data[t.offset..][0..t.data.len], t.data);
    }

    // Fix head.checksumAdjustment
    const head_offset = for (tables) |t| {
        if (mem.eql(u8, t.tag, "head")) break t.offset;
    } else unreachable;
    const whole_checksum = calcChecksum(data);
    Big(u32).from(0xB1B0AFBA -% whole_checksum).write(
        data[head_offset + @offsetOf(Head, "checksum_adjustment") ..],
    );

    return data;
}

fn calcChecksum(data: []const u8) u32 {
    const chunk = @sizeOf(u32);
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + chunk <= data.len) : (i += chunk) {
        sum +%= mem.readInt(u32, data[i..][0..chunk], .big);
    }
    // Trailing 1-3 bytes are right-zero-padded to form one final u32.
    if (i < data.len) {
        var padded: [chunk]u8 = @splat(0);
        @memcpy(padded[0 .. data.len - i], data[i..]);
        sum +%= mem.readInt(u32, &padded, .big);
    }
    return sum;
}
