const std = @import("std");
const ir = @import("ZSIR.zig");
const zsm = @import("../ast/zs_module.zig");
const ast = @import("../ast/ast_node.zig");
const Self = @This();

pub const Error = error{} || std.mem.Allocator.Error;

instructions: *std.ArrayList(ir.ZSIR),
allocator: std.mem.Allocator,
nameCount: usize = 0,

pub fn generateIr(module: *const zsm.ZSModule, allocator: std.mem.Allocator) ![]ir.ZSIR {
    var instructions = try std.ArrayList(ir.ZSIR).initCapacity(allocator, 5);
    defer instructions.deinit(allocator);

    var irGen = Self{ .instructions = &instructions, .allocator = allocator };

    for (module.ast) |node| {
        _ = try irGen.generateNode(node);
    }
    return allocator.dupe(ir.ZSIR, instructions.items);
}

fn generateNode(self: *Self, node: ast.ZSAstNode) ![]const u8 {
    return switch (node) {
        .stmt => try self.generateStmt(node.stmt),
        .expr => self.generateExpr(node.expr),
    };
}

fn generateStmt(self: *Self, stmt: ast.stmt.ZSStmt) ![]const u8 {
    return switch (stmt) {
        .variable => try self.generateVariable(stmt.variable),
    };
}

fn generateExpr(self: *Self, expr: ast.expr.ZSExpr) Error![]const u8 {
    return switch (expr) {
        .number => self.generateNumberAssign(expr.number),
        .string => self.generateStringAssign(expr.string),
        .call => self.generateCall(expr.call),
        .reference => self.generateReference(expr.reference),
    };
}

fn generateCall(self: *Self, call: ast.expr.ZSCall) Error![]const u8 {
    const callerName = try self.generateExpr(call.subject.*);
    const argNames = try self.allocator.alloc([]const u8, call.arguments.len);

    for (call.arguments, 0..) |arg, index| {
        argNames[index] = try self.generateExpr(arg);
    }

    const resultName = try self.generateName();
    try self.instructions.append(
        self.allocator,
        ir.ZSIR{
            .call = ir.ZSIRCall{
                .resultName = resultName,
                .fnName = callerName,
                .argNames = argNames,
            },
        },
    );
    return resultName;
}

fn generateReference(self: *Self, reference: ast.expr.ZSReference) []const u8 {
    _ = self;
    return reference.name;
}

fn generateVariable(self: *Self, variable: ast.stmt.ZSVar) ![]const u8 {
    return self.generateExpr(variable.expr);
}

fn generateNumberAssign(self: *Self, number: ast.expr.ZSNumber) Error![]const u8 {
    return self.generateAssign(ir.ZSIRValue{ .number = number.value });
}

fn generateStringAssign(self: *Self, string: ast.expr.ZSString) Error![]const u8 {
    return self.generateAssign(ir.ZSIRValue{ .string = string.value });
}

fn generateAssign(self: *Self, value: ir.ZSIRValue) Error![]const u8 {
    const name = try self.generateName();
    try self.instructions.append(self.allocator, ir.ZSIR{ .assign = ir.ZSIRAssign{ .value = value, .varName = name } });
    return name;
}

fn generateName(self: *Self) Error![]const u8 {
    const name = try std.fmt.allocPrint(self.allocator, "x{}", .{self.nameCount});
    self.nameCount += 1;
    return name;
}
