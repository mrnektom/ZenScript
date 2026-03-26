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
resolutions: *const std.StringHashMap([]const u8),
overloadedNames: *const std.StringHashMap(void),

pub fn generateIr(
    module: *const zsm.ZSModule,
    allocator: std.mem.Allocator,
    resolutions: *const std.StringHashMap([]const u8),
    overloadedNames: *const std.StringHashMap(void),
) !ir.ZSIRInstructions {
    var instructions = try std.ArrayList(ir.ZSIR).initCapacity(allocator, 5);
    defer instructions.deinit(allocator);

    var irGen = Self{
        .instructions = &instructions,
        .allocator = allocator,
        .varNames = std.StringHashMap([]const u8).init(allocator),
        .resolutions = resolutions,
        .overloadedNames = overloadedNames,
    };
    defer irGen.varNames.deinit();

    for (module.ast) |node| {
        _ = try irGen.generateNode(node);
    }
    return .{ .instructions = try allocator.dupe(ir.ZSIR, instructions.items) };
}

fn computeMangledName(allocator: std.mem.Allocator, name: []const u8, argTypes: []const []const u8) ![]const u8 {
    var len: usize = name.len + 2;
    for (argTypes, 0..) |argType, i| {
        if (i > 0) len += 1;
        len += argType.len;
    }

    const buf = try allocator.alloc(u8, len);
    var pos: usize = 0;
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;
    @memcpy(buf[pos..][0..2], "__");
    pos += 2;
    for (argTypes, 0..) |argType, i| {
        if (i > 0) {
            buf[pos] = '_';
            pos += 1;
        }
        @memcpy(buf[pos..][0..argType.len], argType);
        pos += argType.len;
    }
    return buf;
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
        .boolean => self.generateBooleanAssign(expr.boolean),
        .call => self.generateCall(expr.call),
        .reference => self.generateReference(expr.reference),
        .if_expr => self.generateIfExpr(expr.if_expr),
        .binary => self.generateBinary(expr.binary),
        .block => self.generateBlock(expr.block),
        .return_expr => self.generateReturn(expr.return_expr),
    };
}

fn generateCall(self: *Self, call: ast.expr.ZSCall) Error![]const u8 {
    var callerName = try self.generateExpr(call.subject.*);
    const argNames = try self.allocator.alloc([]const u8, call.arguments.len);

    for (call.arguments, 0..) |arg, index| {
        argNames[index] = try self.generateExpr(arg);
    }

    // Check if this call has a resolved overload name
    const key = try std.fmt.allocPrint(self.allocator, "{}", .{call.startPos});
    defer self.allocator.free(key);
    if (self.resolutions.get(key)) |resolvedName| {
        callerName = resolvedName;
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

    // Determine the function name: mangle if overloaded and not external
    // Always allocate an owned copy so IR can free it uniformly
    const fnName = if (!external and self.overloadedNames.contains(func.name))
        try computeMangledName(self.allocator, func.name, argTypes)
    else
        try self.allocator.dupe(u8, func.name);

    if (func.body) |body| {
        // User-defined function with body
        const argNames = try self.allocator.alloc([]const u8, func.args.len);
        for (func.args, 0..) |arg, i| {
            argNames[i] = arg.name;
        }

        // Generate body instructions into a separate list
        var bodyInstructions = try std.ArrayList(ir.ZSIR).initCapacity(self.allocator, 8);
        defer bodyInstructions.deinit(self.allocator);

        // Save and swap instruction target
        const outerInstructions = self.instructions;
        self.instructions = &bodyInstructions;

        // Save and create new scope for function args
        var innerVarNames = std.StringHashMap([]const u8).init(self.allocator);
        // Copy outer scope
        var outerIter = self.varNames.iterator();
        while (outerIter.next()) |entry| {
            try innerVarNames.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        // Add function args to scope (they reference themselves by name)
        for (func.args) |arg| {
            try innerVarNames.put(arg.name, arg.name);
        }
        const outerVarNames = self.varNames;
        self.varNames = innerVarNames;

        const bodyResult = try self.generateExpr(body);

        // For expression bodies (not blocks), add an implicit return
        if (body != .block) {
            try self.instructions.append(
                self.allocator,
                ir.ZSIR{
                    .ret = ir.ZSIRRet{
                        .value = bodyResult,
                    },
                },
            );
        }

        // Restore outer state
        self.instructions = outerInstructions;
        self.varNames = outerVarNames;
        innerVarNames.deinit();

        try self.instructions.append(
            self.allocator,
            ir.ZSIR{
                .fn_def = ir.ZSIRFnDef{
                    .name = fnName,
                    .argTypes = argTypes,
                    .argNames = argNames,
                    .retType = retType,
                    .body = try self.allocator.dupe(ir.ZSIR, bodyInstructions.items),
                },
            },
        );
    } else {
        // External/forward declaration
        try self.instructions.append(
            self.allocator,
            ir.ZSIR{
                .fn_decl = ir.ZSIRFnDecl{
                    .name = fnName,
                    .argTypes = argTypes,
                    .retType = retType,
                    .external = external,
                },
            },
        );
    }
    return "";
}

fn generateIfExpr(self: *Self, ifExpr: ast.expr.ZSIfExpr) Error![]const u8 {
    const condName = try self.generateExpr(ifExpr.condition.*);

    // Generate then body
    var thenInstructions = try std.ArrayList(ir.ZSIR).initCapacity(self.allocator, 4);
    defer thenInstructions.deinit(self.allocator);
    const outerInstructions = self.instructions;
    self.instructions = &thenInstructions;
    const thenResult = try self.generateExpr(ifExpr.then_branch.*);
    self.instructions = outerInstructions;

    // Generate else body
    var elseInstructions = try std.ArrayList(ir.ZSIR).initCapacity(self.allocator, 4);
    defer elseInstructions.deinit(self.allocator);
    var elseResult: ?[]const u8 = null;
    if (ifExpr.else_branch) |eb| {
        self.instructions = &elseInstructions;
        elseResult = try self.generateExpr(eb.*);
        self.instructions = outerInstructions;
    }

    // Determine if branches produce values (non-empty result, not a block with returns)
    const thenHasValue = thenResult.len > 0;
    const elseHasValue = if (elseResult) |er| er.len > 0 else false;
    const hasResult = thenHasValue and elseHasValue;

    var resultName: ?[]const u8 = null;
    if (hasResult) {
        resultName = try self.generateName();
    }

    try self.instructions.append(
        self.allocator,
        ir.ZSIR{
            .branch = ir.ZSIRBranch{
                .condition = condName,
                .thenBody = try self.allocator.dupe(ir.ZSIR, thenInstructions.items),
                .elseBody = try self.allocator.dupe(ir.ZSIR, elseInstructions.items),
                .resultName = resultName,
                .thenResult = if (thenHasValue) thenResult else null,
                .elseResult = elseResult,
            },
        },
    );
    return resultName orelse "";
}

fn generateBinary(self: *Self, binary: ast.expr.ZSBinary) Error![]const u8 {
    const lhsName = try self.generateExpr(binary.lhs.*);
    const rhsName = try self.generateExpr(binary.rhs.*);
    const resultName = try self.generateName();

    try self.instructions.append(
        self.allocator,
        ir.ZSIR{
            .compare = ir.ZSIRCompare{
                .resultName = resultName,
                .lhs = lhsName,
                .rhs = rhsName,
                .op = binary.op,
            },
        },
    );
    return resultName;
}

fn generateBlock(self: *Self, block: ast.expr.ZSBlock) Error![]const u8 {
    var lastResult: []const u8 = "";
    for (block.stmts) |node| {
        lastResult = try self.generateNode(node);
    }
    return lastResult;
}

fn generateReturn(self: *Self, ret: ast.expr.ZSReturn) Error![]const u8 {
    var valueName: ?[]const u8 = null;
    if (ret.value) |v| {
        valueName = try self.generateExpr(v.*);
    }
    try self.instructions.append(
        self.allocator,
        ir.ZSIR{
            .ret = ir.ZSIRRet{
                .value = valueName,
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

fn generateBooleanAssign(self: *Self, boolean: ast.expr.ZSBoolean) Error![]const u8 {
    return self.generateAssign(ir.ZSIRValue{ .boolean = boolean.value });
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
