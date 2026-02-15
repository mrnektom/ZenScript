const std = @import("std");
const napi_build = @import("napi");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const name = "ZenScriptNode";
    const addon = b.addLibrary(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/nodemodule.zig"),
            .optimize = optimize,
            .target = target,
        }),

        .linkage = .dynamic,
    });

    const dep_napi = b.dependency("napi", .{});
    addon.root_module.addImport("napi", dep_napi.module("napi"));
    addon.linker_allow_shlib_undefined = true;
    const install_lib = b.addInstallArtifact(addon, .{
        .dest_sub_path = name ++ ".node",
    });
    b.getInstallStep().dependOn(&install_lib.step);

    const llvm_dep = b.dependency("llvm", .{ // <== as declared in build.zig.zon
        .target = target, // the same as passing `-Dtarget=<...>` to the library's build.zig script
        .optimize = optimize, // ditto for `-Doptimize=<...>`
    });
    const llvm_mod = llvm_dep.module("llvm"); // <== get llvm bindings module
    // and/or
    const clang_mod = llvm_dep.module("clang"); // <== get clang bindings module

    const mod = b.addModule("ZenScript", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "ZenScript",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ZenScript", .module = mod },
            },
        }),
    });
    exe.root_module.addImport("llvm", llvm_mod); // <== add llvm module
    exe.root_module.addImport("clang", clang_mod); // <== add clang module
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
