//! Glyph outline geometry: turns a cell bitmask into TrueType `glyf` data.

// TODO: glyf.zig / glyph.zig is confusing. The difference is that a glyf is a opentype term and a glyph is a general font term? not sure, maybe ask llm.
const std = @import("std");
const math = std.math;
const common = @import("common.zig");
const Big = common.Big;
const writeBytes = common.writeBytes;
const cell_w = common.cell_w;
const cell_h = common.cell_h;
const num_glyphs = common.num_glyphs;
const MAX_CONTOURS = common.MAX_CONTOURS;
const Glyf = @import("tables.zig").Glyf;
const Loca = @import("tables.zig").Loca;

const Rect = struct {
    x0: i16,
    y0: i16,
    x1: i16,
    y1: i16,
};

fn getGlyphRects(mask: usize, rects: *[MAX_CONTOURS]Rect, rect_w: i16, rect_h: i16, ascent: i16) u8 {
    var count: u8 = 0;

    for (0..(cell_w * cell_h)) |idx| {
        if ((mask >> @intCast(idx)) & 1 == 0) continue;
        const col: i16 = @intCast(idx % cell_w);
        const row: i16 = @intCast(idx / cell_w);
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

pub fn buildGlyf(glyf: *Glyf, loca: *Loca, ascent: i16, rect_w: i16, rect_h: i16) void {
    glyf.len = 0;
    for (0..num_glyphs) |mask| {
        loca.offsets[mask] = Big(u32).from(@intCast(glyf.len));
        const size = compileGlyph(@intCast(mask), glyf.buf[glyf.len..], rect_w, rect_h, ascent);
        glyf.len += @intCast(size);
    }
    // Trailing sentinel: glyph i's data spans loca[i]..loca[i + 1], so a final
    // entry is needed to give the last glyph an end offset.
    loca.offsets[num_glyphs] = Big(u32).from(@intCast(glyf.len));
}
