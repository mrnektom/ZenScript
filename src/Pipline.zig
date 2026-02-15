const std = @import("std");
const Tokenizer = @import("tokens/Tokenizer.zig");
const Parser = @import("Parser.zig");
const Analyzer = @import("analyze/analyzer.zig");
const Self = @This();

pub fn create() Self {
    return Self{};
}

pub fn compile(self: *Self, filePath: []const u8) !void {
    _ = self;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const file = try std.fs.cwd().openFile(filePath, .{ .mode = .read_only });
    const fileSize: usize = @intCast((try file.stat()).size);
    const buffer = try file.readToEndAlloc(allocator, fileSize);
    defer allocator.free(buffer);

    const tokenizer = Tokenizer.create(buffer);
    var parser = try Parser.create(tokenizer, allocator);

    const module = try parser.parse(allocator);
    defer module.deinit(allocator);
    var symTable = try Analyzer.analyze(module, allocator);
    defer symTable.deinit();

    var iter = symTable.keyIterator();

    std.debug.print("Table keys\n", .{});
    while (iter.next()) |key| {
        std.debug.print("{s}: {any}\n", .{ key.*, symTable.get(key.*) });
    }
}
