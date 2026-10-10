//! A static PIE has no dynamic loader to make its RELRO segment read-only
//! once relocations are applied; `protect` does it at the start of `main`.
const std = @import("std");
const builtin = @import("builtin");
const elf = std.elf;
const linux = std.os.linux;

const applies = builtin.os.tag == .linux and builtin.link_mode == .static and builtin.position_independent_executable;

const Range = struct { start: usize, len: usize };

/// The whole pages of the running binary's RELRO segment, rounded as
/// glibc's loader rounds them.
fn range() ?Range {
    const phdrs = @as([*]const elf.Phdr, @ptrFromInt(linux.getauxval(elf.AT_PHDR)))[0..linux.getauxval(elf.AT_PHNUM)];
    const base = for (phdrs) |ph| {
        if (ph.p_type == elf.PT_PHDR) break @intFromPtr(phdrs.ptr) - ph.p_vaddr;
    } else return null;
    const page = std.heap.pageSize();
    for (phdrs) |ph| {
        if (ph.p_type != elf.PT_GNU_RELRO) continue;
        const start = std.mem.alignBackward(usize, base + ph.p_vaddr, page);
        const end = std.mem.alignBackward(usize, base + ph.p_vaddr + ph.p_memsz, page);
        if (end <= start) return null;
        return .{ .start = start, .len = end - start };
    }
    return null;
}

pub fn protect() void {
    if (!applies) return;
    const r = range() orelse return;
    _ = linux.mprotect(@ptrFromInt(r.start), r.len, .{ .READ = true });
}

test protect {
    if (!applies) return error.SkipZigTest;
    const r = range() orelse return error.SkipZigTest;
    protect();
    var buf: [64 * 1024]u8 = undefined;
    const maps = try std.Io.Dir.cwd().readFile(std.testing.io, "/proc/self/maps", &buf);
    var lines = std.mem.tokenizeScalar(u8, maps, '\n');
    var covered: usize = 0;
    while (lines.next()) |line| {
        const dash = std.mem.indexOfScalar(u8, line, '-') orelse continue;
        const space = std.mem.indexOfScalarPos(u8, line, dash, ' ') orelse continue;
        const lo = try std.fmt.parseInt(usize, line[0..dash], 16);
        const hi = try std.fmt.parseInt(usize, line[dash + 1 .. space], 16);
        if (hi <= r.start or lo >= r.start + r.len) continue;
        try std.testing.expectEqualStrings("r--p", line[space + 1 .. space + 5]);
        covered += @min(hi, r.start + r.len) - @max(lo, r.start);
    }
    try std.testing.expectEqual(r.len, covered);
}
