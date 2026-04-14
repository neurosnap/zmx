const std = @import("std");

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
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Version string for release") orelse
        @as([]const u8, @import("build.zig.zon").version);

    var code: u8 = 0;
    const git_sha = std.mem.trim(u8, b.runAllowFail(
        &.{ "git", "rev-parse", "--short", "HEAD" },
        &code,
        .Inherit,
    ) catch "unknown", "\n");

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "git_sha", git_sha);
    const ghostty_ver = @import("build.zig.zon").dependencies.ghostty.hash;
    options.addOption([]const u8, "ghostty_version", ghostty_ver);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addOptions("build_options", options);

    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport(
            "ghostty-vt",
            dep.module("ghostty-vt"),
        );
    }

    // Run
    {
        const run_step = b.step("run", "Run the app");
        const exe = b.addExecutable(.{
            .name = "zmx",
            .root_module = exe_mod,
        });
        exe.linkLibC();
        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
        run_step.dependOn(&run_cmd.step);
    }

    // Test
    {
        const test_step = b.step("test", "Run unit tests");
        const test_module = b.addModule("test", .{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        });
        if (b.lazyDependency("ghostty", .{
            .target = target,
            .optimize = optimize,
        })) |dep| {
            test_module.addImport(
                "ghostty-vt",
                dep.module("ghostty-vt"),
            );
        }
        const exe_unit_tests = b.addTest(.{
            .root_module = test_module,
        });
        const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
        test_step.dependOn(&run_exe_unit_tests.step);
    }

    // Check for LSP integration
    {
        const check = b.step("check", "Check if zmx compiles");
        const exe_check = b.addExecutable(.{
            .name = "zmx",
            .root_module = exe_mod,
        });
        exe_check.linkLibC();

        // Finally we add the "check" step which will be detected
        // by ZLS and automatically enable Build-On-Save.
        // If you copy this into your `build.zig`, make sure to rename 'foo'
        check.dependOn(&exe_check.step);
    }

    // Release step - macOS can cross-compile to Linux,
    // but Linux cannot cross-compile to macOS (needs SDK)
    {
        const release_step = b.step(
            "release",
            "Build release binaries (macOS builds all, Linux builds Linux only)",
        );
        const native_os = @import("builtin").os.tag;
        const release_targets = if (native_os == .macos) linux_targets ++ macos_targets else linux_targets;
        for (release_targets) |release_target| {
            const resolved = b.resolveTargetQuery(release_target);
            const release_mod = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved,
                .optimize = .ReleaseSafe,
            });
            release_mod.addOptions("build_options", options);

            if (b.lazyDependency("ghostty", .{
                .target = resolved,
                .optimize = .ReleaseSafe,
            })) |dep| {
                release_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
            }

            const release_exe = b.addExecutable(.{
                .name = "zmx",
                .root_module = release_mod,
            });
            release_exe.linkLibC();

            const os_name = @tagName(release_target.os_tag orelse .linux);
            const arch_name = @tagName(release_target.cpu_arch orelse .x86_64);
            const tarball_name = b.fmt("zmx-{s}-{s}-{s}.tar.gz", .{ version, os_name, arch_name });

            const tar = b.addSystemCommand(&.{ "tar", "--no-xattrs", "-czf" });

            const tarball = tar.addOutputFileArg(tarball_name);
            tar.addArg("-C");
            tar.addDirectoryArg(release_exe.getEmittedBinDirectory());
            tar.addArg("zmx");

            const shasum = b.addSystemCommand(&.{ "shasum", "-a", "256" });
            shasum.addFileArg(tarball);
            const shasum_output = shasum.captureStdOut();

            const install_tar = b.addInstallFile(tarball, b.fmt("dist/{s}", .{tarball_name}));
            const install_sha = b.addInstallFile(
                shasum_output,
                b.fmt("dist/{s}.sha256", .{tarball_name}),
            );
            release_step.dependOn(&install_tar.step);
            release_step.dependOn(&install_sha.step);
        }
    }

    // Upload artifacts to pgs
    {
        const upload_step = b.step("upload", "Upload docs and dist to pgs.sh:/zmx");
        const gen_doc = b.addSystemCommand(&.{
            "sh", "-c",
            "cat README.md | pdocs -tmpl index.tmpl -toc | ssh pgs.sh /zmx/index.html"
        });
        const rsync_docs = b.addSystemCommand(&.{ "rsync", "-v", "logo.png", "pgs.sh:/zmx/logo.png" });
        const rsync_dist = b.addSystemCommand(&.{ "rsync", "-rv", "zig-out/dist/", "pgs.sh:/zmx/a" });

        upload_step.dependOn(&gen_doc.step);
        upload_step.dependOn(&rsync_docs.step);
        upload_step.dependOn(&rsync_dist.step);
    }
}
