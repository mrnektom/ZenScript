const std = @import("std");
const Symbol = @import("symbol.zig");
const Self = @This();
pub const SymbolTable = std.StringHashMap(Symbol);
pub const Node = struct { data: *SymbolTable, node: std.SinglyLinkedList.Node = .{} };

pub const Error = error{NoTableInStack};

list: std.ArrayList(*SymbolTable),
allocator: std.mem.Allocator,

pub fn create(allocator: std.mem.Allocator) !Self {
    return Self{
        .list = try std.ArrayList(*SymbolTable).initCapacity(allocator, 5),
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    self.list.deinit(self.allocator);
}

pub fn enterScope(self: *Self, table: *SymbolTable) !void {
    try self.list.append(self.allocator, table);
}

pub fn exitScope(self: *Self) !*SymbolTable {
    const node = self.list.pop();
    if (node) |n| {
        return n;
    }

    return Error.NoTableInStack;
}

pub fn put(self: *Self, symbol: Symbol) !void {
    var table = self.list.getLastOrNull() orelse return Error.NoTableInStack;

    try table.put(symbol.name, symbol);
}

pub fn get(self: *Self, name: []const u8) ?Symbol {
    var index = self.list.items.len - 1;

    while (true) {
        if (index >= 0) {
            const table = self.list.items[index];

            if (table.get(name)) |sym| {
                return sym;
            }
            if (index == 0) return null;
            index -= 1;
            continue;
        }
    }
    return null;
}
