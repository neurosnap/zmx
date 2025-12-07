const std = @import("std");

const linux_targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
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

    const run_step = b.step("run", "Run the app");
    const test_step = b.step("test", "Run unit tests");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // You'll want to use a lazy dependency here so that ghostty is only
    // downloaded if you actually need it.
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport(
            "ghostty-vt",
            dep.module("ghostty-vt"),
        );
    }

    // Exe
    const exe = b.addExecutable(.{
        .name = "zmx",
        .root_module = exe_mod,
    });
    exe.linkLibC();

    b.installArtifact(exe);

    // Run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // Test
    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    test_step.dependOn(&run_exe_unit_tests.step);

    const integration_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const integration_tests = b.addTest(.{
        .root_module = integration_test_mod,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    test_step.dependOn(&run_integration_tests.step);

    // This is where the interesting part begins.
    // As you can see we are re-defining the same executable but
    // we're binding it to a dedicated build step.
    const exe_check = b.addExecutable(.{
        .name = "zmx",
        .root_module = exe_mod,
    });
    exe_check.linkLibC();
    // There is no `b.installArtifact(exe_check);` here.

    // Finally we add the "check" step which will be detected
    // by ZLS and automatically enable Build-On-Save.
    // If you copy this into your `build.zig`, make sure to rename 'foo'
    const check = b.step("check", "Check if foo compiles");
    check.dependOn(&exe_check.step);

    // Release step - macOS can cross-compile to Linux, but Linux cannot cross-compile to macOS (needs SDK)
    const native_os = @import("builtin").os.tag;
    const release_targets = if (native_os == .macos) linux_targets ++ macos_targets else linux_targets;
    const release_step = b.step("release", "Build release binaries (macOS builds all, Linux builds Linux only)");

    // Track built tarballs so we can emit a Homebrew formula with fresh shasums.
    var tarball_steps = std.ArrayListUnmanaged(*std.Build.Step){};

    for (release_targets) |release_target| {
        const resolved = b.resolveTargetQuery(release_target);
        const release_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = resolved,
            .optimize = .ReleaseSafe,
        });

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

        const tar = b.addSystemCommand(&.{ "tar", "--no-xattrs", "--no-mac-metadata", "-czf" });

        const tarball = tar.addOutputFileArg(tarball_name);
        tar.addArg("-C");
        tar.addDirectoryArg(release_exe.getEmittedBinDirectory());
        tar.addArg("zmx");

        const shasum = b.addSystemCommand(&.{ "shasum", "-a", "256" });
        shasum.addFileArg(tarball);
        const shasum_output = shasum.captureStdOut();

        const install_tar = b.addInstallFile(tarball, b.fmt("dist/{s}", .{tarball_name}));
        const install_sha = b.addInstallFile(shasum_output, b.fmt("dist/{s}.sha256", .{tarball_name}));
        release_step.dependOn(&install_tar.step);
        release_step.dependOn(&install_sha.step);

        tarball_steps.append(b.allocator, &install_tar.step) catch @panic("OOM tracking tarball steps");
    }

    // Emit the Homebrew formula directly into Formula/zmx.rb with current shasums.
    const brew_script =
        \\import hashlib, pathlib, sys
        \\version = sys.argv[1]
        \\dest = pathlib.Path(sys.argv[2])
        \\dist = pathlib.Path("zig-out/dist")
        \\dest.parent.mkdir(parents=True, exist_ok=True)
        \\
        \\pairs = {
        \\    "macos-aarch64": ("macos", "arm"),
        \\    "macos-x86_64": ("macos", "intel"),
        \\    "linux-aarch64": ("linux", "arm"),
        \\    "linux-x86_64": ("linux", "intel"),
        \\}
        \\urls = {k: f"https://zmx.sh/a/zmx-{version}-{k}.tar.gz" for k in pairs}
        \\shas = {}
        \\
        \\for name in sorted(urls):
        \\    path = dist / pathlib.Path(urls[name]).name
        \\    data = path.read_bytes()
        \\    shas[name] = hashlib.sha256(data).hexdigest()
        \\
        \\tpl = f"""class Zmx < Formula
        \\  desc \"Session persistence for terminal processes\"
        \\  homepage \"https://github.com/neurosnap/zmx\"
        \\  version \"{version}\"
        \\  license \"MIT\"
        \\
        \\  on_macos do
        \\    on_arm do
        \\      url \"{urls['macos-aarch64']}\"
        \\      sha256 \"{shas['macos-aarch64']}\"
        \\    end
        \\    on_intel do
        \\      url \"{urls['macos-x86_64']}\"
        \\      sha256 \"{shas['macos-x86_64']}\"
        \\    end
        \\  end
        \\
        \\  on_linux do
        \\    on_arm do
        \\      url \"{urls['linux-aarch64']}\"
        \\      sha256 \"{shas['linux-aarch64']}\"
        \\    end
        \\    on_intel do
        \\      url \"{urls['linux-x86_64']}\"
        \\      sha256 \"{shas['linux-x86_64']}\"
        \\    end
        \\  end
        \\
        \\  def install
        \\    bin.install \"zmx\"
        \\  end
        \\
        \\  test do
        \\    assert_match \"Usage: zmx\", shell_output(\"#{{bin}}/zmx help\")
        \\  end
        \\end
        \\"""
        \\
        \\dest.write_text(tpl)
        \\print(f"wrote {dest}")
    ;

    const brew_formula_cmd = b.addSystemCommand(&.{ "python3", "-c", brew_script, version, b.path("Formula/zmx.rb").getPath(b) });
    for (tarball_steps.items) |step_ptr| brew_formula_cmd.step.dependOn(step_ptr);
    release_step.dependOn(&brew_formula_cmd.step);

    // Upload step - rsync docs and dist to pgs.sh
    const upload_step = b.step("upload", "Upload docs and dist to pgs.sh:/zmx");

    const rsync_docs = b.addSystemCommand(&.{ "rsync", "-rv", "docs/", "pgs.sh:/zmx" });
    const rsync_dist = b.addSystemCommand(&.{ "rsync", "-rv", "zig-out/dist/", "pgs.sh:/zmx/a" });

    upload_step.dependOn(&rsync_docs.step);
    upload_step.dependOn(&rsync_dist.step);
}
