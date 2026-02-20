const std = @import("std");
const llvm = @import("llvm");
const target = llvm.target;
const types = llvm.types;
const core = llvm.core;
const ir = @import("../ir/ZSIR.zig");

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

    // Clean up LLVM resources
}

pub fn generateLLVMModule(
    instructions: *const ir.ZSIRInstructions,
) !types.LLVMModuleRef {
    startupLLVM();
    // defer core.LLVMShutdown();

    const module: types.LLVMModuleRef = core.LLVMModuleCreateWithName("zs_module");

    var params: [0]types.LLVMTypeRef = [_]types.LLVMTypeRef{};

    const func_type: types.LLVMTypeRef = core.LLVMFunctionType(core.LLVMVoidType(), &params, 0, 0);
    const init_func: types.LLVMValueRef = core.LLVMAddFunction(module, "init", func_type);
    const entry: types.LLVMBasicBlockRef = core.LLVMAppendBasicBlock(init_func, "entry");

    const builder: types.LLVMBuilderRef = core.LLVMCreateBuilder();
    // defer core.LLVMDisposeBuilder(builder);

    core.LLVMPositionBuilderAtEnd(builder, entry);

    for (instructions.instructions) |instruction| {
        try generateInstruction(builder, &instruction);
    }

    _ = core.LLVMBuildRet(builder, null);
    core.LLVMDumpModule(module);

    return module;
}

fn generateInstruction(builder: types.LLVMBuilderRef, instruction: *const ir.ZSIR) !void {
    switch (instruction.*) {
        .assign => try generateAssign(builder, instruction.assign),
        .call => generateCall(builder, instruction.call),
    }
}

fn generateAssign(builder: types.LLVMBuilderRef, assign: ir.ZSIRAssign) !void {
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
}

fn generateCall(builder: types.LLVMBuilderRef, call: ir.ZSIRCall) void {
    _ = builder;
    _ = call;
}

fn getStringType() types.LLVMTypeRef {
    var elems: [2]types.LLVMTypeRef = [_]types.LLVMTypeRef{ core.LLVMInt32Type(), core.LLVMInt8Type() };
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
    return core.LLVMConstStruct(&values, 1, 0);
}

fn convertToCString(allocator: std.mem.Allocator, str: *const []const u8) ![*:0]const u8 {
    return try allocator.dupeZ(u8, str.*);
}

fn startupLLVM() void {
    _ = target.LLVMInitializeNativeTarget();
    _ = target.LLVMInitializeNativeAsmPrinter();
    _ = target.LLVMInitializeNativeAsmParser();
}
