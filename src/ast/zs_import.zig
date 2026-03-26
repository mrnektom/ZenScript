const std = @import("std");

pub const ImportedSymbol = struct {
    name: []const u8,
    alias: ?[]const u8,
};

path: []const u8,
symbols: []ImportedSymbol,
startPos: usize,
endPos: usize,

pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
    allocator.free(self.symbols);
}
