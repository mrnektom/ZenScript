const std = @import("std");
const Tokenizer = @import("tokens/Tokenizer.zig");
const Parser = @import("Parser.zig");
const Analyzer = @import("analyze/analyzer.zig");
const Self = @This();
const IRGen = @import("ir/IRGen.zig");
const llvm = @import("codegen/LLVMCodeGen.zig");

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

    std.debug.print("Parsing\n", .{});
    var parser = try Parser.create(
        allocator,
        tokenizer,
        filePath,
        buffer,
    );

    const module = try parser.parse(allocator);
    defer module.deinit(allocator);

    std.debug.print("Analyzing\n", .{});

    var symTable = try Analyzer.analyze(module, allocator);
    defer symTable.deinit(allocator);

    for (symTable.errors) |e| {
        std.debug.print("{f}\n", .{e});
    }

    std.debug.print("Generating ir\n", .{});

    const ir = try IRGen.generateIr(&module, allocator);
    defer ir.deinit(allocator);
    // std.debug.print("Generating llvm\n", .{});
    // _ = try llvm.generateLLVMModule(&ir);
}
