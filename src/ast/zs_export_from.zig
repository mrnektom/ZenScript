const std = @import("std");
const zs_import = @import("zs_import.zig");

path: []const u8,
symbols: []zs_import.ImportedSymbol,
startPos: usize,
endPos: usize,

pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
    allocator.free(self.symbols);
}
