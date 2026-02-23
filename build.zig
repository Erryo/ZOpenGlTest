// SPDX-FileCopyrightText: NONE
// SPDX-License-Identifier: CC0-1.0

const std = @import("std");
const zigglgen = @import("zigglgen");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag == .emscripten,
    });

    if (target.result.os.tag == .windows and target.result.abi == .msvc) {
        // Work around a problematic definition in wchar.h in Windows SDK version 10.0.26100.0
        app_mod.addCMacro("_Avx2WmemEnabledWeakValue", "_Avx2WmemEnabled");
    }
    const zm = b.dependency("zm", .{
        .target = target,
        .optimize = optimize,
    });
    app_mod.addImport("zm", zm.module("zm"));

    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });

    const sdl_lib = sdl_dep.artifact("SDL3");
    app_mod.linkLibrary(sdl_lib);

    app_mod.addImport("gl", zigglgen.generateBindingsModule(b, if (target.result.os.tag == .emscripten) .{
        .api = .gles,
        .version = .@"3.0", // WebGL 2.0
    } else .{
        .api = .gl,
        .version = .@"4.1", // The last OpenGL version supported on macOS
        .profile = .core,
    }));

    const run = b.step("run", "Run the app");

    // Build for desktop.

    const app_exe = b.addExecutable(.{
        .name = "opengl_hexagon",
        .root_module = app_mod,
    });

    app_exe.linkLibC();
    app_exe.linkSystemLibrary("c");

    b.installArtifact(app_exe);

    const run_app = b.addRunArtifact(app_exe);
    if (b.args) |args| run_app.addArgs(args);
    run_app.step.dependOn(b.getInstallStep());

    run.dependOn(&run_app.step);
}
