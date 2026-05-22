//! Defines the set of bitmasks used for rendering.

pub fn generate(comptime cell_w: u8, comptime cell_h: u8) [bitmaskSetReducedSize(cell_w, cell_h)]u32 {
    const n_bitmasks_total = bitmaskSetSize(cell_w, cell_h);
    const bitmask_full: u32 = @intCast(n_bitmasks_total - 1);

    @setEvalBranchQuota(n_bitmasks_total + 1000);

    var bitmasks: [bitmaskSetReducedSize(cell_w, cell_h)]u32 = undefined;
    var count: usize = 0;
    for (0..n_bitmasks_total) |i| {
        const bitmask: u32 = @intCast(i);
        // skip degen case
        if (bitmask == 0 or bitmask == bitmask_full) continue;
        // a bitmask and its complement produce identical solver results;
        // keep only the smaller of each pair.
        if (bitmask_full ^ bitmask < bitmask) continue;
        if (count >= bitmasks.len)
            @compileError("bitmask_set.generate: produced more bitmasks than bitmaskSetReducedSize");
        bitmasks[count] = bitmask;
        count += 1;
    }
    return bitmasks;
}

fn bitmaskSetReducedSize(comptime cell_w: u8, comptime cell_h: u8) usize {
    const n_bitmasks_total = bitmaskSetSize(cell_w, cell_h);
    // exclude 0 and full bitmap as degenerate cases
    const n_degen = 2;
    // A bitmask and its complement produce identical results in the solver,
    // so each complement pair contributes only one entry.
    // See README.md for derivation.
    const n_bitmasks_reduced = (n_bitmasks_total - n_degen) / 2;
    return n_bitmasks_reduced;
}

fn bitmaskSetSize(comptime cell_w: u8, comptime cell_h: u8) usize {
    const n_bits = cell_w * cell_h;
    return 1 << n_bits;
}
