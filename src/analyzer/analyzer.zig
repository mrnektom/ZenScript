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
allocatedStructFields: std.ArrayList([]sig.ZSStructField),
allocatedTypeSlices: std.ArrayList([]const Symbol.ZSType),
structDefs: std.StringHashMap(StructDef),
exportedStructDefs: std.StringHashMap(StructDef),
fieldIndices: std.AutoHashMap(usize, u32),
enumDefs: std.StringHashMap(EnumDef),
exportedEnumDefs: std.StringHashMap(EnumDef),
useAliases: std.StringHashMap(UseAlias),
allocatedEnumVariants: std.ArrayList([]sig.ZSEnumVariant),
enumInits: std.AutoHashMap(usize, EnumInitInfo),
derefTypes: std.AutoHashMap(usize, []const u8),
inLoop: bool,

pub const EnumInitInfo = struct {
    enumName: []const u8,
    variantTag: u32,
};

const UseAlias = struct {
    enum_name: []const u8,
    variant_name: []const u8,
};

pub const StructDef = struct {
    name: []const u8,
    type_params: []const []const u8,
    fields: []ast.stmt.ZSStruct.ZSStructField,
};

pub const EnumDef = struct {
    name: []const u8,
    type_params: []const []const u8,
    variants: []ast.stmt.ZSEnum.ZSEnumVariant,
};

pub const OverloadEntry = struct {
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
    overloads: std.StringHashMap(std.ArrayList(OverloadEntry)),
    allocatedStrings: std.ArrayList([]const u8),
    allocatedTypes: std.ArrayList(*Symbol.ZSType),
    allocatedSliceLists: std.ArrayList([]const []const u8),
    allocatedStructFields: std.ArrayList([]sig.ZSStructField),
    allocatedTypeSlices: std.ArrayList([]const Symbol.ZSType),
    structDefs: std.StringHashMap(StructDef),
    exportedStructDefs: std.StringHashMap(StructDef),
    fieldIndices: std.AutoHashMap(usize, u32),
    enumDefs: std.StringHashMap(EnumDef),
    exportedEnumDefs: std.StringHashMap(EnumDef),
    allocatedEnumVariants: std.ArrayList([]sig.ZSEnumVariant),
    enumInits: std.AutoHashMap(usize, EnumInitInfo),
    derefTypes: std.AutoHashMap(usize, []const u8),

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.errors);
        self.exports.deinit();

        self.resolutions.deinit();

        self.overloadedNames.deinit();

        // Free overloads map and its inner ArrayLists
        var overloadIter = self.overloads.iterator();
        while (overloadIter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        self.overloads.deinit();

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

        // Free all tracked struct field slices
        for (self.allocatedStructFields.items) |s| {
            allocator.free(s);
        }
        self.allocatedStructFields.deinit(allocator);

        // Free all tracked type slices
        for (self.allocatedTypeSlices.items) |s| {
            allocator.free(s);
        }
        self.allocatedTypeSlices.deinit(allocator);

        self.structDefs.deinit();
        self.exportedStructDefs.deinit();
        self.fieldIndices.deinit();
        self.enumDefs.deinit();
        self.exportedEnumDefs.deinit();

        for (self.allocatedEnumVariants.items) |s| {
            allocator.free(s);
        }
        self.allocatedEnumVariants.deinit(allocator);
        self.enumInits.deinit();
        self.derefTypes.deinit();
    }
};

const computeMangledName = @import("ZenScript").MangleHelpers.computeMangledName;

fn typeToString(zsType: Symbol.ZSType) []const u8 {
    return switch (zsType) {
        .number => "number",
        .boolean => "boolean",
        .char => "char",
        .long => "long",
        .short => "short",
        .byte => "byte",
        .function => "function",
        .unknown => "unknown",
        .struct_type => |st| st.name,
        .pointer => "pointer",
        .array_type => "array",
        .enum_type => |et| et.name,
    };
}

fn isNumericType(name: []const u8) bool {
    return std.mem.eql(u8, name, "number") or
        std.mem.eql(u8, name, "long") or
        std.mem.eql(u8, name, "int") or
        std.mem.eql(u8, name, "short") or
        std.mem.eql(u8, name, "byte") or
        std.mem.eql(u8, name, "char");
}

pub fn analyze(module: zsm.ZSModule, allocator: std.mem.Allocator, deps: *const std.StringHashMap(AnalyzeResult)) !AnalyzeResult {
    return analyzeWithPrelude(module, allocator, deps, null, null, null, null);
}

pub fn analyzeWithPrelude(module: zsm.ZSModule, allocator: std.mem.Allocator, deps: *const std.StringHashMap(AnalyzeResult), preludeExports: ?*const SymbolTable, preludeOverloads: ?*const std.StringHashMap(std.ArrayList(OverloadEntry)), preludeStructDefs: ?*const std.StringHashMap(StructDef), preludeEnumDefs: ?*const std.StringHashMap(EnumDef)) !AnalyzeResult {
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
        .allocatedStructFields = try std.ArrayList([]sig.ZSStructField).initCapacity(allocator, 4),
        .allocatedTypeSlices = try std.ArrayList([]const Symbol.ZSType).initCapacity(allocator, 4),
        .structDefs = std.StringHashMap(StructDef).init(allocator),
        .exportedStructDefs = std.StringHashMap(StructDef).init(allocator),
        .fieldIndices = std.AutoHashMap(usize, u32).init(allocator),
        .enumDefs = std.StringHashMap(EnumDef).init(allocator),
        .exportedEnumDefs = std.StringHashMap(EnumDef).init(allocator),
        .useAliases = std.StringHashMap(UseAlias).init(allocator),
        .allocatedEnumVariants = try std.ArrayList([]sig.ZSEnumVariant).initCapacity(allocator, 4),
        .enumInits = std.AutoHashMap(usize, EnumInitInfo).init(allocator),
        .derefTypes = std.AutoHashMap(usize, []const u8).init(allocator),
        .inLoop = false,
    };

    // Note: resolutions, overloadedNames, overloads, allocatedStrings, allocatedTypes,
    // structDefs, enumDefs are moved into the result, not freed here
    defer analyzer.useAliases.deinit();

    var table = SymbolTable.init(allocator);
    defer table.deinit();
    try tableStack.enterScope(&table);

    // Register built-in load_library(String): void
    {
        const argTypes = try allocator.alloc([]const u8, 1);
        try analyzer.allocatedSliceLists.append(allocator, argTypes);
        argTypes[0] = "String";
        var entries = try std.ArrayList(OverloadEntry).initCapacity(allocator, 1);
        try entries.append(allocator, .{
            .argTypes = argTypes,
            .mangledName = "load_library",
            .retType = .unknown,
            .external = true,
        });
        try analyzer.overloads.put("load_library", entries);
    }

    // Register intrinsics
    try analyzer.registerIntrinsic(allocator, "__syscall2", &.{ "long", "long", "long" }, .long);
    try analyzer.registerIntrinsic(allocator, "__syscall3", &.{ "number", "number", "number", "number" }, .number);
    try analyzer.registerIntrinsic(allocator, "__syscall6", &.{ "long", "long", "long", "long", "long", "long", "long" }, .long);
    // Inject prelude exports into scope
    if (preludeExports) |exports| {
        var iter = exports.iterator();
        while (iter.next()) |entry| {
            try tableStack.put(entry.value_ptr.*);
        }
    }

    // Import prelude function overloads so entry module can resolve them
    if (preludeOverloads) |overloads| {
        var iter2 = overloads.iterator();
        while (iter2.next()) |entry| {
            const gop = try analyzer.overloads.getOrPut(entry.key_ptr.*);
            if (!gop.found_existing) {
                gop.value_ptr.* = try std.ArrayList(OverloadEntry).initCapacity(allocator, 2);
            }
            for (entry.value_ptr.items) |ov| {
                try gop.value_ptr.append(allocator, ov);
            }
        }
    }

    // Import exported struct definitions from dependencies
    {
        var depIter = deps.iterator();
        while (depIter.next()) |dep| {
            var sdIter = dep.value_ptr.exportedStructDefs.iterator();
            while (sdIter.next()) |entry| {
                if (!analyzer.structDefs.contains(entry.key_ptr.*)) {
                    try analyzer.structDefs.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }
    }

    // Import prelude exported struct definitions so entry module can resolve them
    if (preludeStructDefs) |psd| {
        var iter3 = psd.iterator();
        while (iter3.next()) |entry| {
            if (!analyzer.structDefs.contains(entry.key_ptr.*)) {
                try analyzer.structDefs.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    // Import exported enum definitions from dependencies
    {
        var depIter2 = deps.iterator();
        while (depIter2.next()) |dep| {
            var edIter = dep.value_ptr.exportedEnumDefs.iterator();
            while (edIter.next()) |entry| {
                if (!analyzer.enumDefs.contains(entry.key_ptr.*)) {
                    try analyzer.enumDefs.put(entry.key_ptr.*, entry.value_ptr.*);
                }
            }
        }
    }

    // Import prelude exported enum definitions
    if (preludeEnumDefs) |ped| {
        var iter4 = ped.iterator();
        while (iter4.next()) |entry| {
            if (!analyzer.enumDefs.contains(entry.key_ptr.*)) {
                try analyzer.enumDefs.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    }

    // Pre-pass: register all struct definitions
    try analyzer.registerStructs(module);

    // Pre-pass: register all enum definitions
    try analyzer.registerEnums(module);

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
        .overloads = analyzer.overloads,
        .allocatedStrings = analyzer.allocatedStrings,
        .allocatedTypes = analyzer.allocatedTypes,
        .allocatedSliceLists = analyzer.allocatedSliceLists,
        .allocatedStructFields = analyzer.allocatedStructFields,
        .allocatedTypeSlices = analyzer.allocatedTypeSlices,
        .structDefs = analyzer.structDefs,
        .exportedStructDefs = analyzer.exportedStructDefs,
        .fieldIndices = analyzer.fieldIndices,
        .enumDefs = analyzer.enumDefs,
        .exportedEnumDefs = analyzer.exportedEnumDefs,
        .allocatedEnumVariants = analyzer.allocatedEnumVariants,
        .enumInits = analyzer.enumInits,
        .derefTypes = analyzer.derefTypes,
    };
}

fn registerIntrinsic(self: *Self, allocator: std.mem.Allocator, name: []const u8, argTypeNames: []const []const u8, retType: Symbol.ZSType) !void {
    const argTypes = try allocator.alloc([]const u8, argTypeNames.len);
    try self.allocatedSliceLists.append(allocator, argTypes);
    for (argTypeNames, 0..) |t, i| {
        argTypes[i] = t;
    }
    var entries = try std.ArrayList(OverloadEntry).initCapacity(allocator, 1);
    try entries.append(allocator, .{
        .argTypes = argTypes,
        .mangledName = name,
        .retType = retType,
        .external = true,
    });
    try self.overloads.put(name, entries);
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
            .import_decl, .export_from, .expr, .use_decl => {},
        }
    }
}

fn registerFunction(self: *Self, func: ast.stmt.ZSFn) !void {
    const argTypes = try self.allocator.alloc([]const u8, func.args.len);
    try self.allocatedSliceLists.append(self.allocator, argTypes);
    for (func.args, 0..) |arg, i| {
        argTypes[i] = if (arg.type) |t| t.typeName() else "unknown";
    }

    const external = func.modifiers.external != null;
    const mangledName = if (external)
        func.name
    else blk: {
        const name = try computeMangledName(self.allocator, func.name, argTypes);
        try self.allocatedStrings.append(self.allocator, name);
        break :blk name;
    };

    const retType = if (func.ret) |r| try self.resolveTypeAnnotationFull(r) else Symbol.ZSType.unknown;

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
        return resolveTypeInner(r);
    }
    return .unknown;
}

fn resolveTypeInner(r: ast.ZSType) Symbol.ZSType {
    switch (r) {
        .array => return .unknown, // array types need full resolution
        .reference, .generic => {},
    }
    const name = r.typeName();
    if (std.mem.eql(u8, name, "number")) return .number;
    if (std.mem.eql(u8, name, "int")) return .number;
    if (std.mem.eql(u8, name, "long")) return .long;
    if (std.mem.eql(u8, name, "short")) return .short;
    if (std.mem.eql(u8, name, "byte")) return .byte;
    if (std.mem.eql(u8, name, "boolean")) return .boolean;
    if (std.mem.eql(u8, name, "char")) return .char;
    // Note: Pointer<T>, String, and other struct types are resolved
    // during analysis with access to structDefs (see resolveTypeAnnotationFull)
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
        .export_from => b: {
            try self.analyzeExportFrom(node.export_from);
            break :b null;
        },
        .use_decl => b: {
            try self.analyzeUse(node.use_decl);
            break :b null;
        },
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

fn analyzeExportFrom(self: *Self, ef: ast.ZSExportFrom) !void {
    if (self.deps.get(ef.path)) |depResult| {
        for (ef.symbols) |sym| {
            const localName = sym.alias orelse sym.name;
            // Re-export functions/variables
            if (depResult.exports.get(sym.name)) |exportedSym| {
                // Add to current scope so this module can use it
                try self.tableStack.put(.{
                    .name = localName,
                    .assignable = exportedSym.assignable,
                    .signature = exportedSym.signature,
                });
                // Re-export under local name
                try self.exports.put(localName, .{
                    .name = localName,
                    .assignable = exportedSym.assignable,
                    .signature = exportedSym.signature,
                });
            }
            // Re-export struct definitions
            if (depResult.exportedStructDefs.get(sym.name)) |sd| {
                try self.structDefs.put(localName, sd);
                try self.exportedStructDefs.put(localName, sd);
            }
            // Re-export enum definitions
            if (depResult.exportedEnumDefs.get(sym.name)) |ed| {
                try self.enumDefs.put(localName, ed);
                try self.exportedEnumDefs.put(localName, ed);
            }
            // Re-export overloads
            if (depResult.overloads.get(sym.name)) |entries| {
                const gop = try self.overloads.getOrPut(localName);
                if (!gop.found_existing) {
                    gop.value_ptr.* = try std.ArrayList(OverloadEntry).initCapacity(self.allocator, 2);
                }
                for (entries.items) |ov| {
                    try gop.value_ptr.append(self.allocator, ov);
                }
            }
        }
    } else {
        try self.recordErrorAt(ef.startPos, ef.endPos, "Module not found");
    }
}

fn analyzeStmt(self: *Self, stmt: ast.stmt.ZSStmt) !?Symbol {
    return switch (stmt) {
        .variable => try self.analyzeVariable(stmt.variable),
        .function => try self.analyzeFunction(stmt.function),
        .reassign => {
            try self.analyzeReassign(stmt.reassign);
            return null;
        },
        .struct_decl => {
            // Struct definitions are handled in the pre-pass (registerStructs)
            return null;
        },
        .enum_decl => {
            // Enum definitions are handled in the pre-pass (registerEnums)
            return null;
        },
    };
}

fn analyzeExpr(self: *Self, expr: ast.expr.ZSExpr) !Symbol.ZSType {
    return switch (expr) {
        .number => Symbol.ZSType.number,
        .string => try self.getStringStructType(),
        .char => Symbol.ZSType.char,
        .boolean => Symbol.ZSType.boolean,
        .call => self.analyzeCall(expr.call),
        .reference => self.analyzeReference(expr.reference),
        .if_expr => self.analyzeIfExpr(expr.if_expr),
        .while_expr => self.analyzeWhileExpr(expr.while_expr),
        .for_expr => self.analyzeForExpr(expr.for_expr),
        .binary => self.analyzeBinary(expr.binary),
        .unary => self.analyzeUnary(expr.unary),
        .block => self.analyzeBlock(expr.block),
        .return_expr => self.analyzeReturn(expr.return_expr),
        .break_expr => self.analyzeBreak(expr.break_expr),
        .continue_expr => self.analyzeContinue(expr.continue_expr),
        .struct_init => self.analyzeStructInit(expr.struct_init),
        .field_access => self.analyzeFieldAccess(expr.field_access),
        .array_literal => self.analyzeArrayLiteral(expr.array_literal),
        .index_access => self.analyzeIndexAccess(expr.index_access),
        .enum_init => self.analyzeEnumInit(expr.enum_init),
        .match_expr => self.analyzeMatchExpr(expr.match_expr),
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
    switch (reassign.target) {
        .name => |name| {
            const nameStart = @intFromPtr(name.ptr) - @intFromPtr(self.module.source.ptr);
            const nameEnd = nameStart + name.len;
            if (self.tableStack.get(name)) |sym| {
                if (!sym.assignable) {
                    try self.recordErrorAt(nameStart, nameEnd, "Cannot reassign const variable");
                }
            } else {
                try self.recordErrorAt(nameStart, nameEnd, "Reference not found");
            }
        },
        .index => |idx| {
            const nameStart = @intFromPtr(idx.subject_name.ptr) - @intFromPtr(self.module.source.ptr);
            const nameEnd = nameStart + idx.subject_name.len;
            if (self.tableStack.get(idx.subject_name)) |sym| {
                if (!sym.assignable) {
                    try self.recordErrorAt(nameStart, nameEnd, "Cannot reassign const variable");
                }
            } else {
                try self.recordErrorAt(nameStart, nameEnd, "Reference not found");
            }
            _ = try self.analyzeExpr(idx.index);
        },
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
            const argType = if (arg.type) |t| try self.resolveTypeAnnotationFull(t) else Symbol.ZSType.unknown;
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
    // Get the function name from the subject
    const subject = call.subject.*;
    const fnName: ?[]const u8 = switch (subject) {
        .reference => subject.reference.name,
        else => null,
    };

    // Handle ptr/deref intrinsics
    if (fnName) |name| {
        if (std.mem.eql(u8, name, "ptr")) {
            if (call.arguments.len != 1) {
                try self.recordError(call, "ptr() expects exactly 1 argument");
                return Symbol.ZSType.unknown;
            }
            const argType = try self.analyzeExpr(call.arguments[0]);
            const innerPtr = try self.allocator.create(Symbol.ZSType);
            innerPtr.* = argType;
            try self.allocatedTypes.append(self.allocator, innerPtr);
            return Symbol.ZSType{ .pointer = innerPtr };
        }
        if (std.mem.eql(u8, name, "deref")) {
            if (call.arguments.len != 1) {
                try self.recordError(call, "deref() expects exactly 1 argument");
                return Symbol.ZSType.unknown;
            }
            const argType = try self.analyzeExpr(call.arguments[0]);
            const resultType = switch (argType) {
                .pointer => |inner| inner.*,
                .long, .number => Symbol.ZSType.number,
                else => blk: {
                    try self.recordError(call, "deref() argument must be a pointer");
                    break :blk Symbol.ZSType.unknown;
                },
            };
            try self.derefTypes.put(call.startPos, typeToString(resultType));
            return resultType;
        }
    }

    // Analyze all argument expressions and collect their types
    // These are static string literals from typeToString, no need to track
    const argTypes = try self.allocator.alloc([]const u8, call.arguments.len);
    defer self.allocator.free(argTypes);
    for (call.arguments, 0..) |arg, i| {
        const argType = try self.analyzeExpr(arg);
        argTypes[i] = typeToString(argType);
    }

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
                            // Allow numeric type compatibility
                            if (!(isNumericType(a) and isNumericType(b))) {
                                allMatch = false;
                                break;
                            }
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

fn analyzeWhileExpr(self: *Self, whileExpr: ast.expr.ZSWhileExpr) Error!Symbol.ZSType {
    _ = try self.analyzeExpr(whileExpr.condition.*);
    const wasInLoop = self.inLoop;
    self.inLoop = true;
    _ = try self.analyzeExpr(whileExpr.body.*);
    self.inLoop = wasInLoop;
    return .unknown;
}

fn analyzeForExpr(self: *Self, forExpr: ast.expr.ZSForExpr) Error!Symbol.ZSType {
    // Enter scope for the loop variable
    var forScope = SymbolTable.init(self.allocator);
    defer forScope.deinit();
    try self.tableStack.enterScope(&forScope);
    // Analyze init and register the variable
    if (try self.analyzeNode(forExpr.init.*)) |symbol| {
        try self.tableStack.put(symbol);
    }
    _ = try self.analyzeExpr(forExpr.condition.*);
    const wasInLoop = self.inLoop;
    self.inLoop = true;
    _ = try self.analyzeExpr(forExpr.body.*);
    self.inLoop = wasInLoop;
    _ = try self.analyzeNode(forExpr.step.*);
    _ = try self.tableStack.exitScope();
    return .unknown;
}

fn analyzeBreak(self: *Self, breakExpr: ast.expr.ZSBreak) Error!Symbol.ZSType {
    if (!self.inLoop) {
        try self.recordError(breakExpr, "break can only be used inside a loop");
    }
    return .unknown;
}

fn analyzeContinue(self: *Self, continueExpr: ast.expr.ZSContinue) Error!Symbol.ZSType {
    if (!self.inLoop) {
        try self.recordError(continueExpr, "continue can only be used inside a loop");
    }
    return .unknown;
}

fn analyzeUnary(self: *Self, unary: ast.expr.ZSUnary) Error!Symbol.ZSType {
    _ = try self.analyzeExpr(unary.operand.*);
    return Symbol.ZSType.boolean;
}

fn analyzeBinary(self: *Self, binary: ast.expr.ZSBinary) Error!Symbol.ZSType {
    _ = try self.analyzeExpr(binary.lhs.*);
    _ = try self.analyzeExpr(binary.rhs.*);
    const op = binary.op;
    // Comparison and logical operators return boolean
    if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=") or
        std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, "<") or
        std.mem.eql(u8, op, ">=") or std.mem.eql(u8, op, "<=") or
        std.mem.eql(u8, op, "&&") or std.mem.eql(u8, op, "||"))
    {
        return Symbol.ZSType.boolean;
    }
    // Arithmetic operators return number
    return Symbol.ZSType.number;
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
            .export_from => {
                lastType = .unknown;
            },
            .use_decl => {
                try self.analyzeUse(node.use_decl);
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

fn registerStructs(self: *Self, module: zsm.ZSModule) !void {
    for (module.ast) |node| {
        switch (node) {
            .stmt => {
                switch (node.stmt) {
                    .struct_decl => |sd| {
                        const def = StructDef{
                            .name = sd.name,
                            .type_params = sd.type_params,
                            .fields = sd.fields,
                        };
                        try self.structDefs.put(sd.name, def);
                        if (sd.modifiers.exported != null) {
                            try self.exportedStructDefs.put(sd.name, def);
                        }
                    },
                    else => {},
                }
            },
            .import_decl, .export_from, .expr, .use_decl => {},
        }
    }
}

fn resolveTypeAnnotationFull(self: *Self, astType: ast.ZSType) Error!Symbol.ZSType {
    switch (astType) {
        .reference => |ref| {
            if (std.mem.eql(u8, ref, "number")) return .number;
            if (std.mem.eql(u8, ref, "int")) return .number;
            if (std.mem.eql(u8, ref, "long")) return .long;
            if (std.mem.eql(u8, ref, "short")) return .short;
            if (std.mem.eql(u8, ref, "byte")) return .byte;
            if (std.mem.eql(u8, ref, "boolean")) return .boolean;
            if (std.mem.eql(u8, ref, "char")) return .char;
            // Check if it's a known struct type (non-generic)
            if (self.structDefs.get(ref)) |sd| {
                if (sd.type_params.len == 0) {
                    return try self.instantiateStruct(sd, &.{});
                }
            }
            // Check if it's a known enum type (non-generic)
            if (self.enumDefs.get(ref)) |ed| {
                if (ed.type_params.len == 0) {
                    return try self.buildEnumType(ed);
                }
            }
            return .unknown;
        },
        .array => |a| {
            const elemType = try self.resolveTypeAnnotationFull(a.element_type.*);
            const elemPtr = try self.allocator.create(Symbol.ZSType);
            elemPtr.* = elemType;
            try self.allocatedTypes.append(self.allocator, elemPtr);
            return Symbol.ZSType{ .array_type = .{ .element_type = elemPtr, .size = 0 } };
        },
        .generic => |g| {
            if (std.mem.eql(u8, g.name, "Pointer")) {
                return .long;
            }
            // Check for generic struct
            if (self.structDefs.get(g.name)) |sd| {
                return try self.instantiateStruct(sd, g.type_args);
            }
            // Check for generic enum
            if (self.enumDefs.get(g.name)) |ed| {
                return try self.instantiateEnum(ed, g.type_args);
            }
            return .unknown;
        },
    }
}

fn instantiateStruct(self: *Self, sd: StructDef, typeArgs: []const ast.type_notation.ZSType) Error!Symbol.ZSType {
    // Build a mapping from type_param names to resolved types
    const resolvedFields = try self.allocator.alloc(sig.ZSStructField, sd.fields.len);
    try self.allocatedStructFields.append(self.allocator, resolvedFields);
    const resolvedTypeArgs = try self.allocator.alloc(Symbol.ZSType, typeArgs.len);
    try self.allocatedTypeSlices.append(self.allocator, resolvedTypeArgs);

    for (typeArgs, 0..) |ta, i| {
        resolvedTypeArgs[i] = try self.resolveTypeAnnotationFull(ta);
    }

    for (sd.fields, 0..) |field, i| {
        const fieldType = try self.resolveFieldType(field.type, sd.type_params, resolvedTypeArgs);
        resolvedFields[i] = .{ .name = field.name, .type = fieldType };
    }

    return Symbol.ZSType{ .struct_type = .{
        .name = sd.name,
        .fields = resolvedFields,
        .type_args = resolvedTypeArgs,
    } };
}

fn resolveFieldType(self: *Self, fieldAstType: ast.type_notation.ZSType, typeParams: []const []const u8, resolvedTypeArgs: []const Symbol.ZSType) Error!Symbol.ZSType {
    switch (fieldAstType) {
        .reference => |ref| {
            // Check if it's a type parameter
            for (typeParams, 0..) |param, i| {
                if (std.mem.eql(u8, ref, param)) {
                    if (i < resolvedTypeArgs.len) return resolvedTypeArgs[i];
                    return .unknown;
                }
            }
            // Otherwise resolve normally
            return try self.resolveTypeAnnotationFull(fieldAstType);
        },
        .generic, .array => {
            return try self.resolveTypeAnnotationFull(fieldAstType);
        },
    }
}

fn getStringStructType(self: *Self) !Symbol.ZSType {
    // If String is registered as a struct, build its type from the definition
    if (self.structDefs.get("String")) |sd| {
        const resolvedFields = try self.allocator.alloc(sig.ZSStructField, sd.fields.len);
        try self.allocatedStructFields.append(self.allocator, resolvedFields);
        for (sd.fields, 0..) |field, i| {
            const fieldType = resolveTypeInner(field.type);
            resolvedFields[i] = .{ .name = field.name, .type = fieldType };
        }
        return Symbol.ZSType{ .struct_type = .{
            .name = sd.name,
            .fields = resolvedFields,
            .type_args = &.{},
        } };
    }
    return getStringStructTypeStatic();
}

fn getStringStructTypeStatic() Symbol.ZSType {
    return Symbol.ZSType{ .struct_type = .{
        .name = "String",
        .fields = &.{},
        .type_args = &.{},
    } };
}

fn analyzeStructInit(self: *Self, si: ast.expr.ZSStructInit) Error!Symbol.ZSType {
    const sd = self.structDefs.get(si.name) orelse {
        try self.recordError(si, "Unknown struct type");
        return Symbol.ZSType.unknown;
    };

    // Check field count
    if (si.field_values.len != sd.fields.len) {
        try self.recordError(si, "Wrong number of fields in struct init");
    }

    // Analyze each field value and build resolved fields
    const resolvedFields = try self.allocator.alloc(sig.ZSStructField, sd.fields.len);
    try self.allocatedStructFields.append(self.allocator, resolvedFields);
    for (si.field_values, 0..) |fv, i| {
        const valueType = try self.analyzeExpr(fv.value);
        // Find matching field in definition
        var found = false;
        for (sd.fields) |defField| {
            if (std.mem.eql(u8, defField.name, fv.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try self.recordError(si, "Unknown field in struct init");
        }
        if (i < resolvedFields.len) {
            resolvedFields[i] = .{ .name = fv.name, .type = valueType };
        }
    }

    return Symbol.ZSType{ .struct_type = .{
        .name = si.name,
        .fields = resolvedFields,
        .type_args = &.{},
    } };
}

fn analyzeArrayLiteral(self: *Self, al: ast.expr.ZSArrayLiteral) Error!Symbol.ZSType {
    var elemType: Symbol.ZSType = .unknown;
    for (al.elements) |elem| {
        elemType = try self.analyzeExpr(elem);
    }
    const elemPtr = try self.allocator.create(Symbol.ZSType);
    elemPtr.* = elemType;
    try self.allocatedTypes.append(self.allocator, elemPtr);
    return Symbol.ZSType{ .array_type = .{ .element_type = elemPtr, .size = al.elements.len } };
}

fn analyzeIndexAccess(self: *Self, ia: ast.expr.ZSIndexAccess) Error!Symbol.ZSType {
    const subjectType = try self.analyzeExpr(ia.subject.*);
    _ = try self.analyzeExpr(ia.index.*);
    return switch (subjectType) {
        .array_type => |at| at.element_type.*,
        else => blk: {
            try self.recordError(ia, "Index access on non-array type");
            break :blk Symbol.ZSType.unknown;
        },
    };
}

fn analyzeFieldAccess(self: *Self, fa: ast.expr.ZSFieldAccess) Error!Symbol.ZSType {
    // Check if subject is a reference to an enum name (e.g., Option.None)
    if (fa.subject.* == .reference) {
        const refName = fa.subject.reference.name;
        if (self.enumDefs.get(refName)) |ed| {
            // This is EnumName.Variant (unit variant access)
            for (ed.variants, 0..) |variant, i| {
                if (std.mem.eql(u8, variant.name, fa.field)) {
                    // Record this as an enum init for IR gen
                    try self.enumInits.put(fa.startPos, .{
                        .enumName = refName,
                        .variantTag = @intCast(i),
                    });
                    return try self.buildEnumType(ed);
                }
            }
            try self.recordError(fa, "Unknown enum variant");
            return Symbol.ZSType.unknown;
        }
    }

    const subjectType = try self.analyzeExpr(fa.subject.*);
    return switch (subjectType) {
        .struct_type => |st| {
            for (st.fields, 0..) |field, i| {
                if (std.mem.eql(u8, field.name, fa.field)) {
                    try self.fieldIndices.put(fa.startPos, @intCast(i));
                    return field.type;
                }
            }
            try self.recordError(fa, "Field not found in struct");
            return Symbol.ZSType.unknown;
        },
        .array_type => {
            if (std.mem.eql(u8, fa.field, "length")) {
                return Symbol.ZSType.number;
            }
            try self.recordError(fa, "Unknown array field");
            return Symbol.ZSType.unknown;
        },
        else => blk: {
            try self.recordError(fa, "Field access on non-struct type");
            break :blk Symbol.ZSType.unknown;
        },
    };
}

fn registerEnums(self: *Self, module: zsm.ZSModule) !void {
    for (module.ast) |node| {
        switch (node) {
            .stmt => {
                switch (node.stmt) {
                    .enum_decl => |ed| {
                        const def = EnumDef{
                            .name = ed.name,
                            .type_params = ed.type_params,
                            .variants = ed.variants,
                        };
                        try self.enumDefs.put(ed.name, def);
                        if (ed.modifiers.exported != null) {
                            try self.exportedEnumDefs.put(ed.name, def);
                        }
                    },
                    else => {},
                }
            },
            .import_decl, .export_from, .expr, .use_decl => {},
        }
    }
}

fn buildEnumType(self: *Self, ed: EnumDef) Error!Symbol.ZSType {
    const variants = try self.allocator.alloc(sig.ZSEnumVariant, ed.variants.len);
    try self.allocatedEnumVariants.append(self.allocator, variants);
    for (ed.variants, 0..) |v, i| {
        const payloadType: ?Symbol.ZSType = if (v.payload_type) |pt| try self.resolveTypeAnnotationFull(pt) else null;
        variants[i] = .{
            .name = v.name,
            .payload_type = payloadType,
            .tag = @intCast(i),
        };
    }
    return Symbol.ZSType{ .enum_type = .{
        .name = ed.name,
        .variants = variants,
        .type_args = &.{},
    } };
}

fn instantiateEnum(self: *Self, ed: EnumDef, typeArgs: []const ast.type_notation.ZSType) Error!Symbol.ZSType {
    const resolvedTypeArgs = try self.allocator.alloc(Symbol.ZSType, typeArgs.len);
    try self.allocatedTypeSlices.append(self.allocator, resolvedTypeArgs);
    for (typeArgs, 0..) |ta, i| {
        resolvedTypeArgs[i] = try self.resolveTypeAnnotationFull(ta);
    }

    const variants = try self.allocator.alloc(sig.ZSEnumVariant, ed.variants.len);
    try self.allocatedEnumVariants.append(self.allocator, variants);
    for (ed.variants, 0..) |v, i| {
        const payloadType: ?Symbol.ZSType = if (v.payload_type) |pt| blk: {
            // Check if it's a type parameter
            const ptName = pt.typeName();
            for (ed.type_params, 0..) |param, pi| {
                if (std.mem.eql(u8, ptName, param)) {
                    if (pi < resolvedTypeArgs.len) break :blk resolvedTypeArgs[pi];
                    break :blk Symbol.ZSType.unknown;
                }
            }
            break :blk try self.resolveTypeAnnotationFull(pt);
        } else null;
        variants[i] = .{
            .name = v.name,
            .payload_type = payloadType,
            .tag = @intCast(i),
        };
    }

    return Symbol.ZSType{ .enum_type = .{
        .name = ed.name,
        .variants = variants,
        .type_args = resolvedTypeArgs,
    } };
}

fn analyzeEnumInit(self: *Self, ei: ast.expr.ZSEnumInit) Error!Symbol.ZSType {
    const ed = self.enumDefs.get(ei.enum_name) orelse {
        try self.recordError(ei, "Unknown enum type");
        return Symbol.ZSType.unknown;
    };

    // Find the variant
    var foundVariant: ?ast.stmt.ZSEnum.ZSEnumVariant = null;
    for (ed.variants) |v| {
        if (std.mem.eql(u8, v.name, ei.variant_name)) {
            foundVariant = v;
            break;
        }
    }

    if (foundVariant == null) {
        try self.recordError(ei, "Unknown enum variant");
        return Symbol.ZSType.unknown;
    }

    const variant = foundVariant.?;

    // Check payload
    if (ei.payload != null and variant.payload_type == null) {
        try self.recordError(ei, "Variant does not accept a payload");
    } else if (ei.payload == null and variant.payload_type != null) {
        try self.recordError(ei, "Variant requires a payload");
    }

    if (ei.payload) |p| {
        _ = try self.analyzeExpr(p.*);
    }

    return try self.buildEnumType(ed);
}

fn analyzeMatchExpr(self: *Self, me: ast.expr.ZSMatchExpr) Error!Symbol.ZSType {
    const subjectType = try self.analyzeExpr(me.subject.*);

    // Subject must be an enum type
    if (subjectType != .enum_type) {
        try self.recordError(me, "Match subject must be an enum type");
        return Symbol.ZSType.unknown;
    }

    const enumType = subjectType.enum_type;
    var resultType: Symbol.ZSType = .unknown;

    for (me.arms) |arm| {
        // Verify the variant belongs to the enum
        var foundVariant: ?sig.ZSEnumVariant = null;
        for (enumType.variants) |v| {
            if (std.mem.eql(u8, v.name, arm.variant_name)) {
                foundVariant = v;
                break;
            }
        }

        if (foundVariant == null) {
            try self.recordError(me, "Unknown variant in match arm");
            continue;
        }

        const variant = foundVariant.?;

        // Create a scope for the arm with the binding
        var armScope = SymbolTable.init(self.allocator);
        defer armScope.deinit();
        try self.tableStack.enterScope(&armScope);

        if (arm.binding) |binding| {
            const bindingType = variant.payload_type orelse Symbol.ZSType.unknown;
            try self.tableStack.put(.{
                .name = binding,
                .assignable = false,
                .signature = bindingType,
            });
        }

        const armType = try self.analyzeExpr(arm.body.*);
        _ = try self.tableStack.exitScope();

        if (resultType == .unknown) {
            resultType = armType;
        }
    }

    return resultType;
}

fn analyzeUse(self: *Self, u: ast.ZSUse) Error!void {
    const ed = self.enumDefs.get(u.enum_name) orelse {
        try self.recordErrorAt(u.startPos, u.endPos, "Unknown enum type in use declaration");
        return;
    };

    for (u.variants) |variantName| {
        // Verify the variant exists
        var found = false;
        for (ed.variants) |v| {
            if (std.mem.eql(u8, v.name, variantName)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try self.recordErrorAt(u.startPos, u.endPos, "Unknown variant in use declaration");
            continue;
        }
        try self.useAliases.put(variantName, .{
            .enum_name = u.enum_name,
            .variant_name = variantName,
        });
    }
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
