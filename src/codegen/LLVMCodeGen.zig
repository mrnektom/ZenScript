const std = @import("std");
const llvm = @import("llvm");
const target = llvm.target;
const types = llvm.types;
const core = llvm.core;
const ir = @import("../ir/ZSIR.zig");

const LocalVar = struct {
    ptr: types.LLVMValueRef,
    ty: types.LLVMTypeRef,
};

pub fn generate() void {
    _ = target.LLVMInitializeNativeTarget();
    _ = target.LLVMInitializeNativeAsmPrinter();
    _ = target.LLVMInitializeNativeAsmParser();
    defer core.LLVMShutdown();

    // Create a new LLVM module
    const module: types.LLVMModuleRef = core.LLVMModuleCreateWithName("sum_module");
    defer core.LLVMDisposeModule(module);

    var params: [2]types.LLVMTypeRef = [_]types.LLVMTypeRef{
        core.LLVMInt32Type(),
        core.LLVMInt32Type(),
    };

    // Create a function that computes the sum of two integers
    const func_type: types.LLVMTypeRef = core.LLVMFunctionType(core.LLVMInt32Type(), &params, 2, 0);
    const sum_func: types.LLVMValueRef = core.LLVMAddFunction(module, "sum", func_type);
    const entry: types.LLVMBasicBlockRef = core.LLVMAppendBasicBlock(sum_func, "entry");
    const builder: types.LLVMBuilderRef = core.LLVMCreateBuilder();
    defer core.LLVMDisposeBuilder(builder);

    core.LLVMPositionBuilderAtEnd(builder, entry);
    const arg1: types.LLVMValueRef = core.LLVMGetParam(sum_func, 0);
    const arg2: types.LLVMValueRef = core.LLVMGetParam(sum_func, 1);
    const sum: types.LLVMValueRef = core.LLVMBuildAdd(builder, arg1, arg2, "sum");
    _ = core.LLVMBuildRet(builder, sum);

    // Dump the LLVM module to stdout
    core.LLVMDumpModule(module);
}

pub fn generateLLVMModule(
    instructions: *const ir.ZSIRInstructions,
    allocator: std.mem.Allocator,
) !types.LLVMModuleRef {
    startupLLVM();

    const module: types.LLVMModuleRef = core.LLVMModuleCreateWithName("zs_module");

    var params: [0]types.LLVMTypeRef = [_]types.LLVMTypeRef{};

    const func_type: types.LLVMTypeRef = core.LLVMFunctionType(core.LLVMVoidType(), &params, 0, 0);
    const init_func: types.LLVMValueRef = core.LLVMAddFunction(module, "init", func_type);
    const entry: types.LLVMBasicBlockRef = core.LLVMAppendBasicBlock(init_func, "entry");

    const builder: types.LLVMBuilderRef = core.LLVMCreateBuilder();

    core.LLVMPositionBuilderAtEnd(builder, entry);

    var locals = std.StringHashMap(LocalVar).init(allocator);
    defer locals.deinit();

    for (instructions.instructions) |instruction| {
        try generateInstruction(builder, module, &locals, &instruction, allocator);
    }

    _ = core.LLVMBuildRet(builder, null);

    return module;
}

fn generateInstruction(
    builder: types.LLVMBuilderRef,
    module: types.LLVMModuleRef,
    locals: *std.StringHashMap(LocalVar),
    instruction: *const ir.ZSIR,
    allocator: std.mem.Allocator,
) !void {
    switch (instruction.*) {
        .assign => try generateAssign(builder, locals, instruction.assign),
        .call => try generateCall(builder, module, locals, instruction.call, allocator),
        .fn_decl => try generateFnDecl(module, instruction.fn_decl, allocator),
    }
}

fn generateFnDecl(module: types.LLVMModuleRef, decl: ir.ZSIRFnDecl, allocator: std.mem.Allocator) !void {
    const paramCount: c_uint = @intCast(decl.argTypes.len);
    var paramTypes: [16]types.LLVMTypeRef = undefined;
    for (decl.argTypes, 0..) |argType, i| {
        paramTypes[i] = mapType(argType);
    }

    const retType = mapType(decl.retType);
    const funcType = core.LLVMFunctionType(retType, &paramTypes, paramCount, 0);
    const nameZ = try allocator.dupeZ(u8, decl.name);
    defer allocator.free(nameZ);
    _ = core.LLVMAddFunction(module, nameZ.ptr, funcType);
}

fn generateAssign(builder: types.LLVMBuilderRef, locals: *std.StringHashMap(LocalVar), assign: ir.ZSIRAssign) !void {
    const ty = switch (assign.value) {
        .number => core.LLVMInt32Type(),
        .string => getStringType(),
    };

    const value = try getValue(builder, &assign.value);

    const ptr: types.LLVMValueRef = core.LLVMBuildAlloca(
        builder,
        ty,
        "x",
    );

    _ = core.LLVMBuildStore(builder, value, ptr);

    try locals.put(assign.varName, LocalVar{ .ptr = ptr, .ty = ty });
}

fn generateCall(
    builder: types.LLVMBuilderRef,
    module: types.LLVMModuleRef,
    locals: *std.StringHashMap(LocalVar),
    call: ir.ZSIRCall,
    allocator: std.mem.Allocator,
) !void {
    const fnNameZ = try allocator.dupeZ(u8, call.fnName);
    defer allocator.free(fnNameZ);
    const funcRef = core.LLVMGetNamedFunction(module, fnNameZ.ptr);
    if (funcRef == null) return;

    const funcType = core.LLVMGlobalGetValueType(funcRef);

    var args: [16]types.LLVMValueRef = undefined;
    for (call.argNames, 0..) |argName, i| {
        if (locals.get(argName)) |local| {
            args[i] = core.LLVMBuildLoad2(builder, local.ty, local.ptr, "arg");
        }
    }

    const argCount: c_uint = @intCast(call.argNames.len);

    const retType = core.LLVMGetReturnType(funcType);
    const isVoid = core.LLVMGetTypeKind(retType) == .LLVMVoidTypeKind;
    const resultName: [*:0]const u8 = if (isVoid) "" else "call_result";

    _ = core.LLVMBuildCall2(builder, funcType, funcRef, &args, argCount, resultName);
}

fn mapType(name: []const u8) types.LLVMTypeRef {
    if (std.mem.eql(u8, name, "number")) {
        return core.LLVMInt32Type();
    } else if (std.mem.eql(u8, name, "string")) {
        return getStringType();
    } else if (std.mem.eql(u8, name, "c_string")) {
        return core.LLVMPointerType(core.LLVMInt8Type(), 0);
    } else if (std.mem.eql(u8, name, "void")) {
        return core.LLVMVoidType();
    } else {
        return core.LLVMVoidType();
    }
}

fn getStringType() types.LLVMTypeRef {
    var elems: [2]types.LLVMTypeRef = [_]types.LLVMTypeRef{ core.LLVMInt32Type(), core.LLVMPointerType(core.LLVMInt8Type(), 0) };
    return core.LLVMStructType(&elems, 2, 0);
}

fn getValue(builder: types.LLVMBuilderRef, value: *const ir.ZSIRValue) !types.LLVMValueRef {
    return switch (value.*) {
        .number => core.LLVMConstInt(core.LLVMInt32Type(), @intCast(value.number), 1),
        .string => getStringValue(builder, value.string),
    };
}

fn getStringValue(builder: types.LLVMBuilderRef, value: [*:0]const u8) !types.LLVMValueRef {
    const zStr: []const u8 = std.mem.span(value);
    const arrTy = core.LLVMArrayType(core.LLVMInt8Type(), @intCast(zStr.len));
    const ptr = core.LLVMBuildAlloca(builder, arrTy, "strVal");
    const str = core.LLVMConstString(value, @intCast(zStr.len), 1);
    _ = core.LLVMBuildStore(builder, str, ptr);
    var values: [2]types.LLVMValueRef = [_]types.LLVMValueRef{ core.LLVMConstInt(core.LLVMInt32Type(), zStr.len, 0), ptr };
    return core.LLVMConstStruct(&values, 2, 0);
}

fn convertToCString(allocator: std.mem.Allocator, str: *const []const u8) ![*:0]const u8 {
    return try allocator.dupeZ(u8, str.*);
}

fn startupLLVM() void {
    _ = target.LLVMInitializeNativeTarget();
    _ = target.LLVMInitializeNativeAsmPrinter();
    _ = target.LLVMInitializeNativeAsmParser();
}
