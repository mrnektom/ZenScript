const std = @import("std");
const zsm = @import("../ast/zs_module.zig");
const ast = @import("../ast/ast_node.zig");
const sig = @import("symbol_signature.zig");
const sts = @import("symbol_table_stack.zig");
const Symbol = @import("symbol.zig");
const AnalyzeError = @import("analyze_error.zig");
const SymbolTable = sts.SymbolTable;
const Self = @This();

tableStack: *sts,
errors: *std.ArrayList(AnalyzeError),
allocator: std.mem.Allocator,
module: zsm.ZSModule,
deps: *const std.StringHashMap(AnalyzeResult),
exports: SymbolTable,
overloads: std.StringHashMap(std.ArrayList(OverloadEntry)),
resolutions: std.AutoHashMap(usize, []const u8),
overloadedNames: std.StringHashMap(void),
allocatedStrings: std.ArrayList([]const u8),
allocatedTypes: std.ArrayList(*Symbol.ZSType),
allocatedSliceLists: std.ArrayList([]const []const u8),

const OverloadEntry = struct {
    argTypes: []const []const u8,
    mangledName: []const u8,
    retType: Symbol.ZSType,
    external: bool,
};

const Error = error{} || std.mem.Allocator.Error || sts.Error;

pub const AnalyzeResult = struct {
    exports: SymbolTable,
    errors: []AnalyzeError,
    resolutions: std.AutoHashMap(usize, []const u8),
    overloadedNames: std.StringHashMap(void),
    allocatedStrings: std.ArrayList([]const u8),
    allocatedTypes: std.ArrayList(*Symbol.ZSType),
    allocatedSliceLists: std.ArrayList([]const []const u8),

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.errors);
        self.exports.deinit();

        self.resolutions.deinit();

        self.overloadedNames.deinit();

        // Free all tracked heap-allocated strings (mangled names)
        for (self.allocatedStrings.items) |s| {
            allocator.free(s);
        }
        self.allocatedStrings.deinit(allocator);

        // Free all tracked heap-allocated ZSType pointers
        for (self.allocatedTypes.items) |t| {
            allocator.destroy(t);
        }
        self.allocatedTypes.deinit(allocator);

        // Free all tracked argTypes slice arrays
        for (self.allocatedSliceLists.items) |s| {
            allocator.free(s);
        }
        self.allocatedSliceLists.deinit(allocator);
    }
};

const computeMangledName = @import("ZenScript").MangleHelpers.computeMangledName;

fn typeToString(zsType: Symbol.ZSType) []const u8 {
    return switch (zsType) {
        .number => "number",
        .string => "string",
        .boolean => "boolean",
        .function => "function",
        .unknown => "unknown",
    };
}

pub fn analyze(module: zsm.ZSModule, allocator: std.mem.Allocator, deps: *const std.StringHashMap(AnalyzeResult)) !AnalyzeResult {
    var errors = try std.ArrayList(AnalyzeError).initCapacity(allocator, 1);
    defer errors.deinit(allocator);
    var tableStack = try sts.create(allocator);
    defer tableStack.deinit();
    var analyzer = Self{
        .tableStack = &tableStack,
        .errors = &errors,
        .allocator = allocator,
        .module = module,
        .deps = deps,
        .exports = SymbolTable.init(allocator),
        .overloads = std.StringHashMap(std.ArrayList(OverloadEntry)).init(allocator),
        .resolutions = std.AutoHashMap(usize, []const u8).init(allocator),
        .overloadedNames = std.StringHashMap(void).init(allocator),
        .allocatedStrings = try std.ArrayList([]const u8).initCapacity(allocator, 8),
        .allocatedTypes = try std.ArrayList(*Symbol.ZSType).initCapacity(allocator, 4),
        .allocatedSliceLists = try std.ArrayList([]const []const u8).initCapacity(allocator, 8),
    };

    // Free overloads map and its inner ArrayLists (but NOT their contents —
    // argTypes and mangledName are tracked in allocatedStrings)
    defer {
        var iter = analyzer.overloads.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        analyzer.overloads.deinit();
    }
    // Note: resolutions, overloadedNames, allocatedStrings, allocatedTypes
    // are moved into the result, not freed here

    var table = SymbolTable.init(allocator);
    defer table.deinit();
    try tableStack.enterScope(&table);

    // Pre-pass: register all function overloads
    try analyzer.registerFunctions(module);

    // Determine which names are overloaded
    var overloadIter = analyzer.overloads.iterator();
    while (overloadIter.next()) |entry| {
        if (entry.value_ptr.items.len > 1) {
            try analyzer.overloadedNames.put(entry.key_ptr.*, {});
        }
    }

    try analyzer.analyzeModule(module);
    _ = try tableStack.exitScope();

    return .{
        .exports = analyzer.exports,
        .errors = try allocator.dupe(AnalyzeError, errors.items),
        .resolutions = analyzer.resolutions,
        .overloadedNames = analyzer.overloadedNames,
        .allocatedStrings = analyzer.allocatedStrings,
        .allocatedTypes = analyzer.allocatedTypes,
        .allocatedSliceLists = analyzer.allocatedSliceLists,
    };
}

fn registerFunctions(self: *Self, module: zsm.ZSModule) !void {
    for (module.ast) |node| {
        switch (node) {
            .stmt => {
                switch (node.stmt) {
                    .function => |func| {
                        try self.registerFunction(func);
                    },
                    else => {},
                }
            },
            .import_decl, .expr => {},
        }
    }
}

fn registerFunction(self: *Self, func: ast.stmt.ZSFn) !void {
    const argTypes = try self.allocator.alloc([]const u8, func.args.len);
    try self.allocatedSliceLists.append(self.allocator, argTypes);
    for (func.args, 0..) |arg, i| {
        argTypes[i] = if (arg.type) |t| t.reference else "unknown";
    }

    const external = func.modifiers.external != null;
    const mangledName = if (external)
        func.name
    else blk: {
        const name = try computeMangledName(self.allocator, func.name, argTypes);
        try self.allocatedStrings.append(self.allocator, name);
        break :blk name;
    };

    const retType = resolveTypeAnnotation(func.ret);

    // Check for duplicate signatures
    if (self.overloads.getPtr(func.name)) |entries| {
        for (entries.items) |entry| {
            if (entry.argTypes.len == argTypes.len) {
                var allMatch = true;
                for (entry.argTypes, argTypes) |a, b| {
                    if (!std.mem.eql(u8, a, b)) {
                        allMatch = false;
                        break;
                    }
                }
                if (allMatch) {
                    const nameStart = @intFromPtr(func.name.ptr) - @intFromPtr(self.module.source.ptr);
                    try self.recordErrorAt(nameStart, nameStart + func.name.len, "Duplicate function signature");
                    return;
                }
            }
        }
        try entries.append(self.allocator, .{
            .argTypes = argTypes,
            .mangledName = mangledName,
            .retType = retType,
            .external = external,
        });
    } else {
        var entries = try std.ArrayList(OverloadEntry).initCapacity(self.allocator, 2);
        try entries.append(self.allocator, .{
            .argTypes = argTypes,
            .mangledName = mangledName,
            .retType = retType,
            .external = external,
        });
        try self.overloads.put(func.name, entries);
    }
}

fn resolveTypeAnnotation(ret: ?ast.ZSType) Symbol.ZSType {
    if (ret) |r| {
        return switch (r) {
            .reference => |ref| {
                if (std.mem.eql(u8, ref, "number")) return .number;
                if (std.mem.eql(u8, ref, "string")) return .string;
                if (std.mem.eql(u8, ref, "boolean")) return .boolean;
                return .unknown;
            },
        };
    }
    return .unknown;
}

fn analyzeModule(self: *Self, module: zsm.ZSModule) !void {
    for (module.ast) |node| {
        if (try self.analyzeNode(node)) |symbol| {
            try self.tableStack.put(symbol);
        }
    }
}

fn analyzeNode(self: *Self, node: ast.ZSAstNode) !?Symbol {
    return switch (node) {
        .stmt => try self.analyzeStmt(node.stmt),
        .expr => b: {
            _ = try self.analyzeExpr(node.expr);
            break :b null;
        },
        .import_decl => try self.analyzeImport(node.import_decl),
    };
}

fn analyzeImport(self: *Self, imp: ast.ZSImport) !?Symbol {
    // Look up dependency analysis results
    if (self.deps.get(imp.path)) |depResult| {
        for (imp.symbols) |sym| {
            const localName = sym.alias orelse sym.name;
            if (depResult.exports.get(sym.name)) |exportedSym| {
                try self.tableStack.put(.{
                    .name = localName,
                    .assignable = exportedSym.assignable,
                    .signature = exportedSym.signature,
                });
            } else {
                try self.recordErrorAt(imp.startPos, imp.endPos, "Imported symbol not found in module");
            }
        }
    } else {
        try self.recordErrorAt(imp.startPos, imp.endPos, "Module not found");
    }
    return null;
}

fn analyzeStmt(self: *Self, stmt: ast.stmt.ZSStmt) !?Symbol {
    return switch (stmt) {
        .variable => try self.analyzeVariable(stmt.variable),
        .function => try self.analyzeFunction(stmt.function),
        .reassign => {
            try self.analyzeReassign(stmt.reassign);
            return null;
        },
    };
}

fn analyzeExpr(self: *Self, expr: ast.expr.ZSExpr) !Symbol.ZSType {
    return switch (expr) {
        .number => Symbol.ZSType.number,
        .string => Symbol.ZSType.string,
        .boolean => Symbol.ZSType.boolean,
        .call => self.analyzeCall(expr.call),
        .reference => self.analyzeReference(expr.reference),
        .if_expr => self.analyzeIfExpr(expr.if_expr),
        .binary => self.analyzeBinary(expr.binary),
        .block => self.analyzeBlock(expr.block),
        .return_expr => self.analyzeReturn(expr.return_expr),
    };
}

fn analyzeVariable(self: *Self, variable: ast.stmt.ZSVar) !Symbol {
    const stype = try self.analyzeExpr(variable.expr);
    const sym = Symbol{ .name = variable.name, .assignable = variable.type == .Let, .signature = stype };
    if (variable.modifiers.exported != null) {
        try self.exports.put(sym.name, sym);
    }
    return sym;
}

fn analyzeReassign(self: *Self, reassign: ast.stmt.ZSReassign) !void {
    _ = try self.analyzeExpr(reassign.expr);
    const nameStart = @intFromPtr(reassign.name.ptr) - @intFromPtr(self.module.source.ptr);
    const nameEnd = nameStart + reassign.name.len;
    if (self.tableStack.get(reassign.name)) |sym| {
        if (!sym.assignable) {
            try self.recordErrorAt(nameStart, nameEnd, "Cannot reassign const variable");
        }
    } else {
        try self.recordErrorAt(nameStart, nameEnd, "Reference not found");
    }
}

fn analyzeFunction(self: *Self, function: ast.stmt.ZSFn) !Symbol {
    const retType = resolveTypeAnnotation(function.ret);
    const args = try self.analyzeFnArgs(function.args);

    // Heap-allocate the return type to avoid dangling pointer
    const retPtr = try self.allocator.create(Symbol.ZSType);
    retPtr.* = retType;
    try self.allocatedTypes.append(self.allocator, retPtr);

    if (function.body) |body| {
        var scope = SymbolTable.init(self.allocator);
        defer scope.deinit();
        try self.tableStack.enterScope(&scope);
        // Add args as symbols in the function scope
        for (function.args) |arg| {
            const argType = resolveTypeAnnotation(arg.type);
            try self.tableStack.put(.{
                .name = arg.name,
                .assignable = false,
                .signature = argType,
            });
        }
        _ = try self.analyzeExpr(body);
        _ = try self.tableStack.exitScope();
    }

    const sym = Symbol{
        .name = function.name,
        .assignable = false,
        .signature = Symbol.ZSType{
            .function = .{
                .ret = retPtr,
                .args = args,
            },
        },
    };
    if (function.modifiers.exported != null) {
        try self.exports.put(sym.name, sym);
    }
    return sym;
}

fn analyzeType(self: *Self, ret: *const ?ast.ZSType) !Symbol.ZSType {
    _ = self;
    return resolveTypeAnnotation(ret.*);
}

fn analyzeBuiltin(self: *Self, builtin: ast.ZSBuiltin) !Symbol.ZSType {
    _ = self;
    return switch (builtin) {
        .number => Symbol.ZSType.number,
    };
}

fn analyzeFnArgs(self: *Self, args: []ast.stmt.ZSFn.Arg) ![]Symbol.sig.ZSFnArg {
    _ = self;
    _ = args;

    return &[_]Symbol.sig.ZSFnArg{};
}

fn analyzeCall(self: *Self, call: ast.expr.ZSCall) Error!Symbol.ZSType {
    // Analyze all argument expressions and collect their types
    // These are static string literals from typeToString, no need to track
    const argTypes = try self.allocator.alloc([]const u8, call.arguments.len);
    defer self.allocator.free(argTypes);
    for (call.arguments, 0..) |arg, i| {
        const argType = try self.analyzeExpr(arg);
        argTypes[i] = typeToString(argType);
    }

    // Get the function name from the subject
    const subject = call.subject.*;
    const fnName: ?[]const u8 = switch (subject) {
        .reference => subject.reference.name,
        else => null,
    };

    if (fnName) |name| {
        // Check if we have overloads for this function
        if (self.overloads.get(name)) |entries| {
            // Find matching overload
            var matched: ?OverloadEntry = null;
            for (entries.items) |entry| {
                if (entry.argTypes.len == argTypes.len) {
                    var allMatch = true;
                    for (entry.argTypes, argTypes) |a, b| {
                        if (!std.mem.eql(u8, a, b)) {
                            allMatch = false;
                            break;
                        }
                    }
                    if (allMatch) {
                        matched = entry;
                        break;
                    }
                }
            }

            if (matched) |entry| {
                // Determine the resolved name
                const isOverloaded = self.overloadedNames.contains(name);
                const resolvedName = if (isOverloaded and !entry.external)
                    entry.mangledName
                else
                    name;

                try self.resolutions.put(call.startPos, resolvedName);

                return entry.retType;
            } else {
                try self.recordError(call, "No matching overload");
                return Symbol.ZSType.unknown;
            }
        }
    }

    // Fallback: resolve via symbol table (for non-function-reference subjects)
    const subjectType = try self.analyzeExpr(call.subject.*);
    return switch (subjectType) {
        .function => subjectType.function.ret.*,
        .unknown => Symbol.ZSType.unknown,
        else => blk: {
            try self.recordError(call, "Subject is not a function");
            break :blk Symbol.ZSType.unknown;
        },
    };
}

fn analyzeReference(self: *Self, ref: ast.expr.ZSReference) !Symbol.ZSType {
    if (self.tableStack.get(ref.name)) |sym| {
        return sym.signature;
    }
    try self.recordError(ref, "Reference not found");
    return Symbol.ZSType.unknown;
}

fn analyzeIfExpr(self: *Self, ifExpr: ast.expr.ZSIfExpr) Error!Symbol.ZSType {
    _ = try self.analyzeExpr(ifExpr.condition.*);
    const thenType = try self.analyzeExpr(ifExpr.then_branch.*);
    if (ifExpr.else_branch) |eb| {
        _ = try self.analyzeExpr(eb.*);
    }
    return thenType;
}

fn analyzeBinary(self: *Self, binary: ast.expr.ZSBinary) Error!Symbol.ZSType {
    _ = try self.analyzeExpr(binary.lhs.*);
    _ = try self.analyzeExpr(binary.rhs.*);
    return Symbol.ZSType.boolean;
}

fn analyzeBlock(self: *Self, block: ast.expr.ZSBlock) Error!Symbol.ZSType {
    var lastType: Symbol.ZSType = .unknown;
    for (block.stmts) |node| {
        switch (node) {
            .stmt => {
                if (try self.analyzeStmt(node.stmt)) |symbol| {
                    try self.tableStack.put(symbol);
                }
                lastType = .unknown;
            },
            .expr => {
                lastType = try self.analyzeExpr(node.expr);
            },
            .import_decl => {
                lastType = .unknown;
            },
        }
    }
    return lastType;
}

fn analyzeReturn(self: *Self, ret: ast.expr.ZSReturn) Error!Symbol.ZSType {
    if (ret.value) |v| {
        return try self.analyzeExpr(v.*);
    }
    return .unknown;
}

fn recordError(
    self: *Self,
    expr: anytype,
    message: []const u8,
) Error!void {
    try self.recordErrorAt(expr.startPos, expr.endPos, message);
}

fn recordErrorAt(
    self: *Self,
    start: usize,
    end: usize,
    message: []const u8,
) Error!void {
    const root = @import("ZenScript");
    try self.errors.append(self.allocator, .{
        .message = message,
        .filename = self.module.filename,
        .start = start,
        .end = end,
        .codeLine = root.SourceHelpers.computeSourceLine(self.module.source, start),
        .lineNumber = root.SourceHelpers.computeLineNumber(self.module.source, start),
        .lineCol = root.SourceHelpers.computeLineOffset(self.module.source, start),
    });
}
