const std = @import("std");

pub const Artifact = struct { source: []const u8, name: []const u8 };

/// All producers must finish before this is called. Prepare every replacement
/// before publishing any; each rename is atomic, but the set is not a transaction.
pub fn publish(gpa: std.mem.Allocator, io: std.Io, source_dir: std.Io.Dir, dest: std.Io.Dir, artifacts: []const Artifact) !void {
    for (artifacts) |artifact| {
        const stat = try source_dir.statFile(io, artifact.source, .{});
        if (stat.kind != .file or stat.permissions.toMode() & 0o111 == 0) return error.InvalidExecutable;
    }
    const pending = try gpa.alloc(std.Io.File.Atomic, artifacts.len);
    defer gpa.free(pending);
    var prepared: usize = 0;
    defer for (pending[0..prepared]) |*file| file.deinit(io);
    for (artifacts, pending) |artifact, *file| {
        file.* = try dest.createFileAtomic(io, artifact.name, .{ .replace = true });
        prepared += 1;
        const source = try source_dir.openFile(io, artifact.source, .{});
        defer source.close(io);
        var reader = source.reader(io, &.{});
        var buffer: [4096]u8 = undefined;
        var writer = file.file.writer(io, &buffer);
        _ = writer.interface.sendFileAll(&reader, .unlimited) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.WriteFailed => return writer.err.?,
        };
        try writer.flush();
        try file.file.setPermissions(io, .fromMode(0o755));
    }
    for (pending) |*file| try file.replace(io);
}

fn executable(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    const file = try dir.createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, content);
    try file.setPermissions(std.testing.io, .fromMode(0o755));
}

fn expectContent(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    const actual = try dir.readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(content, actual);
}

test "publication: invalid or missing later candidate preserves all destinations" {
    const io = std.testing.io;
    var fixture = std.testing.tmpDir(.{});
    defer fixture.cleanup();
    try executable(fixture.dir, "candidate", "new");
    try executable(fixture.dir, "first", "original");
    try executable(fixture.dir, "second", "original");
    const artifacts = [_]Artifact{ .{ .source = "candidate", .name = "first" }, .{ .source = "missing", .name = "second" } };
    try std.testing.expectError(error.FileNotFound, publish(std.testing.allocator, io, fixture.dir, fixture.dir, &artifacts));
    try fixture.dir.writeFile(io, .{ .sub_path = "missing", .data = "not executable" });
    try std.testing.expectError(error.InvalidExecutable, publish(std.testing.allocator, io, fixture.dir, fixture.dir, &artifacts));
    try expectContent(fixture.dir, "first", "original");
    try expectContent(fixture.dir, "second", "original");
}

test "publication: stages all files before replacement and cleans failed preparation" {
    const io = std.testing.io;
    var fixture = std.testing.tmpDir(.{ .iterate = true });
    defer fixture.cleanup();
    try executable(fixture.dir, "candidate", "new");
    try executable(fixture.dir, "first", "original");
    const artifacts = [_]Artifact{ .{ .source = "candidate", .name = "first" }, .{ .source = "candidate", .name = "absent/second" } };
    try std.testing.expectError(error.FileNotFound, publish(std.testing.allocator, io, fixture.dir, fixture.dir, &artifacts));
    try expectContent(fixture.dir, "first", "original");
    var iterator = fixture.dir.iterate();
    var count: usize = 0;
    while (try iterator.next(io)) |_| count += 1;
    try std.testing.expectEqual(2, count);
}

test "publication: replaces symlinks, preserves targets, and supports repeated publication" {
    const io = std.testing.io;
    var fixture = std.testing.tmpDir(.{});
    defer fixture.cleanup();
    try executable(fixture.dir, "candidate", "new");
    try executable(fixture.dir, "untouched", "original");
    try fixture.dir.symLink(io, "untouched", "published", .{});
    const artifacts = [_]Artifact{.{ .source = "candidate", .name = "published" }};
    for (0..2) |_| try publish(std.testing.allocator, io, fixture.dir, fixture.dir, &artifacts);
    try expectContent(fixture.dir, "published", "new");
    try expectContent(fixture.dir, "untouched", "original");
    const stat = try fixture.dir.statFile(io, "published", .{ .follow_symlinks = false });
    try std.testing.expectEqual(.file, stat.kind);
    try std.testing.expectEqual(0o755, stat.permissions.toMode() & 0o777);
}
