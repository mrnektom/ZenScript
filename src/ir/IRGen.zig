const std = @import("std");
const ir = @import("ZSIR.zig");
const zsm = @import("../ast/zs_module.zig");
const ast = @import("../ast/ast_node.zig");
const Self = @This();

pub const Error = error{} || std.mem.Allocator.Error || std.fmt.ParseIntError;

instructions: *std.ArrayList(ir.ZSIR),
allocator: std.mem.Allocator,
nameCount: usize = 0,
varNames: std.StringHashMap([]const u8),

pub fn generateIr(module: *const zsm.ZSModule, allocator: std.mem.Allocator) !ir.ZSIRInstructions {
    var instructions = try std.ArrayList(ir.ZSIR).initCapacity(allocator, 5);
    defer instructions.deinit(allocator);

    var irGen = Self{
        .instructions = &instructions,
        .allocator = allocator,
        .varNames = std.StringHashMap([]const u8).init(allocator),
    };
    defer irGen.varNames.deinit();

    for (module.ast) |node| {
        _ = try irGen.generateNode(node);
    }
    return .{ .instructions = try allocator.dupe(ir.ZSIR, instructions.items) };
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
        .function => try self.generateFunction(stmt.function),
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
    return self.varNames.get(reference.name) orelse reference.name;
}

fn generateVariable(self: *Self, variable: ast.stmt.ZSVar) ![]const u8 {
    const irName = try self.generateExpr(variable.expr);
    try self.varNames.put(variable.name, irName);
    return irName;
}

fn generateFunction(self: *Self, func: ast.stmt.ZSFn) ![]const u8 {
    const argTypes = try self.allocator.alloc([]const u8, func.args.len);
    for (func.args, 0..) |arg, i| {
        argTypes[i] = if (arg.type) |t| t.reference else "unknown";
    }

    const retType: []const u8 = if (func.ret) |r| r.reference else "void";
    const external = func.modifiers.external != null;

    try self.instructions.append(
        self.allocator,
        ir.ZSIR{
            .fn_decl = ir.ZSIRFnDecl{
                .name = func.name,
                .argTypes = argTypes,
                .retType = retType,
                .external = external,
            },
        },
    );
    return "";
}

fn generateNumberAssign(self: *Self, number: ast.expr.ZSNumber) Error![]const u8 {
    return self.generateAssign(ir.ZSIRValue{ .number = try std.fmt.parseInt(i32, number.value, 10) });
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
