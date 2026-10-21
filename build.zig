const std = @import("std");
const build_zig_zon = @import("build.zig.zon");

const linux_targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
};

const macos_targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // const is_macos = target.result.os.tag == .macos;
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Version string for release") orelse
        @as([]const u8, build_zig_zon.version);

    const enable_daemon = b.option(bool, "daemon", "Include daemon support and Ghostty VT in zmx pkg") orelse true;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    const ghostty_ver = build_zig_zon.dependencies.ghostty.hash;
    options.addOption([]const u8, "ghostty_version", ghostty_ver);
    options.addOption(bool, "has_daemon", enable_daemon);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addOptions("build_options", options);

    const dep = if (enable_daemon) b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
        // Not redundant: in lib-vt mode emit-xcframework defaults to "xcodebuild
        // on PATH" (true even via the CLT stub), which pulls in the iOS SDK at
        // configure time and breaks builds without full Xcode.
        .@"emit-xcframework" = false,
        .@"emit-macos-app" = false,
    }) else null;
    if (dep) |d| {
        exe_mod.addImport(
            "ghostty-vt",
            d.module("ghostty-vt"),
        );
    }

    // zmx module: programmatic interface for embedding or external tools
    const zmx_pkg_mod = b.addModule("zmx", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    zmx_pkg_mod.addOptions("build_options", options);
    if (dep) |d| {
        zmx_pkg_mod.addImport("ghostty-vt", d.module("ghostty-vt"));
    }

    // Examples: build the usage examples in examples/ against the zmx module
    {
        const examples_step = b.step("examples", "Build usage examples");
        const Example = struct { name: []const u8, file: []const u8 };
        const example_sources: []const Example = &.{
            .{ .name = "example-run-and-wait", .file = "examples/run_and_wait.zig" },
            .{ .name = "example-list-sessions", .file = "examples/list_sessions.zig" },
        };
        for (example_sources) |ex| {
            const ex_mod = b.createModule(.{
                .root_source_file = b.path(ex.file),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            ex_mod.addImport("zmx", zmx_pkg_mod);
            const ex_exe = b.addExecutable(.{ .name = ex.name, .root_module = ex_mod });
            const install = b.addInstallArtifact(ex_exe, .{});
            examples_step.dependOn(&install.step);
        }
    }

    // Run
    {
        const run_step = b.step("run", "Run the app");
        const exe = b.addExecutable(.{
            .name = "zmx",
            // .use_llvm = true,
            // .use_lld = !is_macos,
            .root_module = exe_mod,
        });

        if (enable_daemon) {
            b.installArtifact(exe);
            const run_cmd = b.addRunArtifact(exe);
            run_cmd.step.dependOn(b.getInstallStep());
            if (b.args) |args| run_cmd.addArgs(args);
            run_step.dependOn(&run_cmd.step);
        }
    }

    // Test
    {
        const test_step = b.step("test", "Run unit tests");
        const test_module = b.addModule("test", .{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        test_module.addOptions("build_options", options);
        const test_dep = b.dependency("ghostty", .{
            .target = target,
            .optimize = optimize,
            .@"emit-lib-vt" = true,
            .@"emit-xcframework" = false,
            .@"emit-macos-app" = false,
        });
        test_module.addImport(
            "ghostty-vt",
            test_dep.module("ghostty-vt"),
        );
        const exe_unit_tests = b.addTest(.{
            .root_module = test_module,
            // .use_llvm = true,
            // .use_lld = !is_macos,
        });

        const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
        test_step.dependOn(&run_exe_unit_tests.step);
    }

    // Check for LSP integration
    {
        const check = b.step("check", "Check if zmx compiles");
        if (enable_daemon) {
            const exe_check = b.addExecutable(.{
                .name = "zmx",
                .root_module = exe_mod,
            });
            check.dependOn(&exe_check.step);
        } else {
            const lib_check = b.addLibrary(.{
                .name = "zmx",
                .root_module = zmx_pkg_mod,
                .linkage = .static,
            });
            check.dependOn(&lib_check.step);
        }
    }

    // Release step - cross-compile to all targets from any host
    {
        const release_step = b.step(
            "release",
            "Build release binaries for all platforms",
        );
        const release_targets = linux_targets ++ macos_targets;
        for (release_targets) |release_target| {
            const resolved = b.resolveTargetQuery(release_target);
            const release_mod = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved,
                .optimize = .ReleaseSafe,
                .link_libc = true,
            });
            release_mod.addOptions("build_options", options);

            if (b.lazyDependency("ghostty", .{
                .target = resolved,
                .optimize = .ReleaseSafe,
                .@"emit-lib-vt" = true,
                .@"emit-xcframework" = false,
                .@"emit-macos-app" = false,
            })) |release_dep| {
                release_mod.addImport("ghostty-vt", release_dep.module("ghostty-vt"));
            }

            // const is_local_macos = resolved.result.os.tag == .macos;
            const release_exe = b.addExecutable(.{
                .name = "zmx",
                // .use_llvm = true,
                // .use_lld = !is_local_macos,
                .root_module = release_mod,
            });

            const os_name = @tagName(release_target.os_tag orelse .linux);
            const arch_name = @tagName(release_target.cpu_arch orelse .x86_64);
            const tarball_name = b.fmt("zmx-{s}-{s}-{s}.tar.gz", .{ version, os_name, arch_name });

            const tar = b.addSystemCommand(&.{ "tar", "-czf" });

            const tarball = tar.addOutputFileArg(tarball_name);
            tar.addArg("-C");
            tar.addDirectoryArg(release_exe.getEmittedBinDirectory());
            tar.addArg("zmx");

            const shasum = b.addSystemCommand(&.{"sha256sum"});
            shasum.addFileArg(tarball);
            const shasum_output = shasum.captureStdOut(.{});

            const install_tar = b.addInstallFile(tarball, b.fmt("dist/{s}", .{tarball_name}));
            const install_sha = b.addInstallFile(
                shasum_output,
                b.fmt("dist/{s}.sha256", .{tarball_name}),
            );
            release_step.dependOn(&install_tar.step);
            release_step.dependOn(&install_sha.step);
        }
    }
}
