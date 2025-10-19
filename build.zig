const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ==
    // == MAIN BUILD ==
    // ==
    const run_step = b.step("run", "Run the app");
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport(
            "ghostty-vt",
            dep.module("ghostty-vt"),
        );
    }

    if (b.lazyDependency("libxev", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport("xev", dep.module("xev"));
    }

    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("clap", clap_dep.module("clap"));

    const exe = b.addExecutable(.{
        .name = "zmx",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // ==
    // == TEST BUILD ==
    // ==
    const test_step = b.step("test", "Run unit tests");
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    test_step.dependOn(&run_exe_unit_tests.step);

    // ==
    // == CHECK BUILD ==
    // ==
    const exe_check = b.addExecutable(.{
        .name = "zmx",
        .root_module = exe_mod,
    });

    // by ZLS and automatically enable Build-On-Save.
    const check = b.step("check", "Check if zmx compiles");
    check.dependOn(&exe_check.step);
}
