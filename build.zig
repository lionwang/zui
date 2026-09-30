const std = @import("std");

const SkiaLibs = [_][]const u8{
    "skia", "skparagraph", "skshaper", "skunicode_core", "skunicode_icu",
};

const SystemLibs = [_][]const u8{
    "opengl32", "user32", "gdi32", "dwmapi", "imm32",
    "shell32", "ole32", "advapi32", "d3d12", "d3dcompiler", "dxgi",
    // uuid.lib provides IID_IUnknown (referenced by Skia's DirectWrite font manager).
    "uuid",
    // Dynamic CRT: import libraries for MSVCP140 / VCRUNTIME140 / ucrtbase.
    "msvcprt", "vcruntime", "ucrt",
    // Static CRT pieces that are never exported from the DLLs: the VCStartup
    // objects (operator new/delete, _Init_thread_*, atexit) live in msvcrt.lib
    // and the compiler support routines (security cookie, GS handlers, _setjmp)
    // live in libvcruntime.lib. They are listed *after* the import libraries so
    // that DLL-exported symbols are preferred where both exist.
    "msvcrt",
};

const GlfwSources = [_][]const u8{
    "context.c",        "init.c",          "input.c",          "monitor.c",
    "platform.c",       "vulkan.c",        "window.c",         "wgl_context.c",
    "egl_context.c",    "osmesa_context.c",
    "win32_init.c",     "win32_joystick.c", "win32_module.c",   "win32_monitor.c",
    "win32_thread.c",   "win32_time.c",    "win32_window.c",
    "null_init.c",      "null_joystick.c", "null_monitor.c",   "null_window.c",
};

pub fn build(b: *std.Build) void {
    // The prebuilt Skia static libraries (and our C++ wrapper, compiled with
    // cl.exe) use the MSVC ABI, so the whole project must target windows-msvc
    // even though Zig's native default on Windows is mingw.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .msvc,
    });
    const optimize = b.standardOptimizeOption(.{});

    const zui_mod = b.createModule(.{
        .root_source_file = b.path("src/zui/zui.zig"),
        .target = target,
        .optimize = optimize,
    });
    zui_mod.addIncludePath(b.path("src"));
    zui_mod.addIncludePath(b.path("vendor/glfw/include"));
    addNativeIncludes(b, zui_mod);

    // ---- Skia C++ wrapper, compiled with MSVC's cl.exe ----
    const zsk_obj = compileMsvcCpp(b, "src/zsk.cpp", "zsk.obj", &.{"vendor/skia"});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("examples/counter/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zui", zui_mod);
    exe_mod.addIncludePath(b.path("vendor/glfw/include"));
    addNativeIncludes(b, exe_mod);
    for (GlfwSources) |src| {
        exe_mod.addCSourceFile(.{
            .file = b.path(b.fmt("vendor/glfw/src/{s}", .{src})),
            .flags = &.{ "-D_GLFW_WIN32", "-D_CRT_SECURE_NO_WARNINGS" },
        });
    }
    exe_mod.addObjectFile(zsk_obj);
    exe_mod.addLibraryPath(b.path("vendor/skia-binaries"));
    addWindowsKitsLibPath(b, exe_mod);
    addMsvcLibPath(b, exe_mod);
    for (SkiaLibs) |lib| exe_mod.linkSystemLibrary(lib, .{});
    for (SystemLibs) |lib| exe_mod.linkSystemLibrary(lib, .{});

    const exe = b.addExecutable(.{
        .name = "zui_demo",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // ---- headless render check ----
    const check_mod = b.createModule(.{
        .root_source_file = b.path("examples/check/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_mod.addImport("zui", zui_mod);
    check_mod.addIncludePath(b.path("vendor/glfw/include"));
    addNativeIncludes(b, check_mod);
    for (GlfwSources) |src| {
        check_mod.addCSourceFile(.{
            .file = b.path(b.fmt("vendor/glfw/src/{s}", .{src})),
            .flags = &.{ "-D_GLFW_WIN32", "-D_CRT_SECURE_NO_WARNINGS" },
        });
    }
    check_mod.addObjectFile(zsk_obj);
    check_mod.addLibraryPath(b.path("vendor/skia-binaries"));
    addWindowsKitsLibPath(b, check_mod);
    addMsvcLibPath(b, check_mod);
    for (SkiaLibs) |lib| check_mod.linkSystemLibrary(lib, .{});
    for (SystemLibs) |lib| check_mod.linkSystemLibrary(lib, .{});

    const check_exe = b.addExecutable(.{
        .name = "zui_check",
        .root_module = check_mod,
    });
    b.installArtifact(check_exe);

    const run_check = b.addRunArtifact(check_exe);
    run_check.step.dependOn(b.getInstallStep());
    const check_step = b.step("check", "Run the headless render check");
    check_step.dependOn(&run_check.step);

    // Copy the ICU data file next to the executable; Skia needs it for text
    // shaping and looks it up next to the module / in the working directory.
    const icu = b.addInstallFileWithDir(b.path("vendor/skia-binaries/icudtl.dat"), .bin, "icudtl.dat");
    b.getInstallStep().dependOn(&icu.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the demo app");
    run_step.dependOn(&run_cmd.step);

    // ---- unit tests ----
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/zui/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The tests import skia, which @cImports the Skia C ABI header, so the
    // include paths must match the library module even though the test binary
    // never links against Skia (only rect layout is exercised).
    test_mod.addIncludePath(b.path("src"));
    test_mod.addIncludePath(b.path("vendor/skia"));
    addNativeIncludes(b, test_mod);
    test_mod.addCSourceFile(.{
        .file = b.path("src/zui/test_stubs.c"),
        .flags = &.{},
    });

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library unit tests");
    test_step.dependOn(&run_tests.step);
}

/// Compile a single C++ translation unit with MSVC's cl.exe and return the
/// produced object file. Zig's bundled clang cannot compile C++ against the
/// MSVC STL (its own libc++ headers conflict), so we delegate to cl.exe, whose
/// ABI matches the prebuilt Skia static libraries.
fn compileMsvcCpp(
    b: *std.Build,
    src: []const u8,
    obj_name: []const u8,
    include_dirs: []const []const u8,
) std.Build.LazyPath {
    const vcvars = findVcvars(b) orelse @panic(
        \\zui build error: could not locate the MSVC build environment.
        \\Install Visual Studio with the "Desktop development with C++"
        \\workload (any 2019/2022 edition).
    );

    const bat_path = b.pathFromRoot(".compile_cl.bat");

    var includes: std.ArrayList(u8) = .empty;
    for (include_dirs) |inc| {
        includes.appendSlice(b.allocator, " /I \"") catch @panic("OOM");
        includes.appendSlice(b.allocator, b.pathFromRoot(inc)) catch @panic("OOM");
        includes.append(b.allocator, '"') catch @panic("OOM");
    }

    const bat = std.fmt.allocPrint(
        b.allocator,
        "@echo off\r\n" ++
            "call \"{s}\" >nul 2>&1\r\n" ++
            "cl /nologo /c /EHsc /MD /std:c++17 /utf-8{s} %*\r\n",
        .{ vcvars, includes.items },
    ) catch @panic("OOM");
    std.Io.Dir.cwd().writeFile(b.graph.io, .{ .sub_path = bat_path, .data = bat }) catch @panic("failed to write build script");

    const run = b.addSystemCommand(&.{ "cmd", "/c", bat_path });
    run.addFileArg(b.path(src));
    return run.addPrefixedOutputFileArg("/Fo:", obj_name);
}

/// Add the include directories that cl.exe would use (MSVC + Windows SDK).
///
/// Zig's build system does not always propagate the locally detected MSVC /
/// Windows SDK include paths to embedded C compilations, so we add them
/// explicitly, mirroring what vcvars64.bat puts into INCLUDE.
fn addNativeIncludes(b: *std.Build, mod: *std.Build.Module) void {
    for (nativeIncludeDirs(b)) |inc| {
        mod.addIncludePath(.{ .cwd_relative = inc });
    }
}

fn nativeIncludeDirs(b: *std.Build) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const alloc = b.allocator;

    // MSVC headers: <vsroot>\VC\Tools\MSVC\<ver>\{include, atlmfc\include}
    if (findVcvars(b)) |vcvars| {
        const d1 = std.fs.path.dirname(vcvars) orelse return list.items;
        const d2 = std.fs.path.dirname(d1) orelse return list.items;
        const vc_root = std.fs.path.dirname(d2) orelse return list.items;
        const tools = std.fs.path.join(alloc, &.{ vc_root, "Tools", "MSVC" }) catch return list.items;
        var tools_dir = std.Io.Dir.openDirAbsolute(b.graph.io, tools, .{ .iterate = true }) catch return list.items;
        defer tools_dir.close(b.graph.io);
        var it = tools_dir.iterateAssumeFirstIteration();
        var best: ?[]const u8 = null;
        while (true) {
            const entry = it.next(b.graph.io) catch break;
            const e = entry orelse break;
            if (e.kind != .directory) continue;
            const full = std.fs.path.join(alloc, &.{ tools, e.name }) catch continue;
            const inc = std.fs.path.join(alloc, &.{ full, "include" }) catch continue;
            std.Io.Dir.accessAbsolute(b.graph.io, inc, .{}) catch continue;
            if (best == null or std.mem.order(u8, e.name, std.fs.path.basename(best.?)) == .gt) {
                best = full;
            }
        }
        if (best) |ver_dir| {
            if (std.fs.path.join(alloc, &.{ ver_dir, "include" })) |inc| {
                list.append(alloc, inc) catch {};
            } else |_| {}
            const atlmfc = std.fs.path.join(alloc, &.{ ver_dir, "atlmfc", "include" }) catch null;
            if (atlmfc) |a| {
                std.Io.Dir.accessAbsolute(b.graph.io, a, .{}) catch {
                    list.append(alloc, a) catch {};
                };
            }
        }
    }

    // Windows SDK headers: <kits>\10\Include\<ver>\{ucrt, um, shared}
    if (findWindowsKitsInclude(b)) |sdk_inc| {
        for ([_][]const u8{ "ucrt", "um", "shared" }) |sub| {
            list.append(alloc, std.fs.path.join(alloc, &.{ sdk_inc, sub }) catch continue) catch {};
        }
    }

    return list.items;
}

fn findWindowsKitsInclude(b: *std.Build) ?[]const u8 {
    const alloc = b.allocator;
    const drives = [_][]const u8{ "C:", "D:", "E:", "F:", "G:" };
    const dirs = [_][]const u8{ "Program Files (x86)", "Program Files", "" };
    var best: ?[]const u8 = null;
    for (drives) |drive| for (dirs) |dir| {
        const kits = std.fmt.allocPrint(alloc, "{s}\\{s}\\Windows Kits\\10\\Include", .{ drive, dir }) catch continue;
        var iterate_dir = std.Io.Dir.openDirAbsolute(b.graph.io, kits, .{ .iterate = true }) catch continue;
        defer iterate_dir.close(b.graph.io);
        var it = iterate_dir.iterateAssumeFirstIteration();
        while (true) {
            const entry = it.next(b.graph.io) catch break;
            const e = entry orelse break;
            const full = std.fs.path.join(alloc, &.{ kits, e.name }) catch continue;
            const ucrt = std.fs.path.join(alloc, &.{ full, "ucrt" }) catch continue;
            std.Io.Dir.accessAbsolute(b.graph.io, ucrt, .{}) catch continue;
            if (best == null or std.mem.order(u8, e.name, std.fs.path.basename(best.?)) == .gt) {
                best = full;
            }
        }
    };
    return best;
}
fn addWindowsKitsLibPath(b: *std.Build, mod: *std.Build.Module) void {
    const alloc = b.allocator;
    const drives = [_][]const u8{ "C:", "D:", "E:", "F:", "G:" };
    const dirs = [_][]const u8{ "Program Files (x86)", "Program Files", "" };
    var best: ?[]const u8 = null;
    for (drives) |drive| for (dirs) |dir| {
        const libs = std.fmt.allocPrint(alloc, "{s}\\{s}\\Windows Kits\\10\\Lib", .{ drive, dir }) catch continue;
        var iterate_dir = std.Io.Dir.openDirAbsolute(b.graph.io, libs, .{ .iterate = true }) catch continue;
        defer iterate_dir.close(b.graph.io);
        var it = iterate_dir.iterateAssumeFirstIteration();
        while (true) {
            const entry = it.next(b.graph.io) catch break;
            const e = entry orelse break;
            const full = std.fs.path.join(alloc, &.{ libs, e.name }) catch continue;
            const ucrt = std.fs.path.join(alloc, &.{ full, "ucrt", "x64" }) catch continue;
            std.Io.Dir.accessAbsolute(b.graph.io, ucrt, .{}) catch continue;
            if (best == null or std.mem.order(u8, e.name, std.fs.path.basename(best.?)) == .gt) {
                best = ucrt;
            }
        }
    };
    if (best) |lib_dir| {
        mod.addLibraryPath(.{ .cwd_relative = lib_dir });
        // The um/x64 directory holds the OS import libraries (uuid.lib et al.).
        const ver_dir = std.fs.path.dirname(std.fs.path.dirname(lib_dir) orelse lib_dir) orelse lib_dir;
        const um = std.fs.path.join(alloc, &.{ ver_dir, "um", "x64" }) catch lib_dir;
        std.Io.Dir.accessAbsolute(b.graph.io, um, .{}) catch return;
        mod.addLibraryPath(.{ .cwd_relative = um });
    }
}

/// Add the MSVC tools lib directory (lib\x64) so the C/C++ runtime import
/// libraries (msvcprt.lib, vcruntime.lib, msvcrt.lib) can be found by the linker.
fn addMsvcLibPath(b: *std.Build, mod: *std.Build.Module) void {
    const vcvars = findVcvars(b) orelse return;
    const d1 = std.fs.path.dirname(vcvars) orelse return;
    const d2 = std.fs.path.dirname(d1) orelse return;
    const vc_root = std.fs.path.dirname(d2) orelse return;
    const tools = std.fs.path.join(b.allocator, &.{ vc_root, "Tools", "MSVC" }) catch return;
    var tools_dir = std.Io.Dir.openDirAbsolute(b.graph.io, tools, .{ .iterate = true }) catch return;
    defer tools_dir.close(b.graph.io);
    var it = tools_dir.iterateAssumeFirstIteration();
    var best: ?[]const u8 = null;
    while (true) {
        const entry = it.next(b.graph.io) catch break;
        const e = entry orelse break;
        if (e.kind != .directory) continue;
        const lib = std.fs.path.join(b.allocator, &.{ tools, e.name, "lib", "x64" }) catch continue;
        std.Io.Dir.accessAbsolute(b.graph.io, lib, .{}) catch continue;
        if (best == null or std.mem.order(u8, e.name, std.fs.path.basename(best.?)) == .gt) {
            best = lib;
        }
    }
    if (best) |lib_dir| {
        mod.addLibraryPath(.{ .cwd_relative = lib_dir });
    }
}
/// Locate the Visual Studio build environment by scanning the usual paths.
fn findVcvars(b: *std.Build) ?[]const u8 {
    const alloc = b.allocator;
    const editions = [_][]const u8{ "2022", "2019" };
    const flavors = [_][]const u8{ "Community", "Professional", "Enterprise", "BuildTools" };
    const dirs = [_][]const u8{ "Program Files", "Program Files (x86)" };
    const drives = [_][]const u8{ "C:", "D:", "E:", "F:", "G:" };
    for (drives) |drive| for (dirs) |dir| for (editions) |ed| for (flavors) |fl| {
        const out = std.fmt.allocPrint(
            alloc,
            "{s}\\{s}\\Microsoft Visual Studio\\{s}\\{s}\\VC\\Auxiliary\\Build\\vcvars64.bat",
            .{ drive, dir, ed, fl },
        ) catch continue;
        std.Io.Dir.accessAbsolute(b.graph.io, out, .{}) catch continue;
        return out;
    };
    return null;
}