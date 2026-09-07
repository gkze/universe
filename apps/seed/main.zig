const std = @import("std");
const builtin = @import("builtin");

const Lock = struct {
    url: []const u8,
    version: []const u8,
    hashes: struct {
        @"linux-x64": Hash,
        @"linux-arm64": Hash,
        @"macos-x64": Hash,
        @"macos-arm64": Hash,
    },
};

const Hash = struct {
    tarball: []const u8,
    binary: []const u8,
};

const platform = switch (builtin.os.tag) {
    .linux => switch (builtin.cpu.arch) {
        .x86_64 => "linux-x64",
        .aarch64 => "linux-arm64",
        else => @compileError("unsupported"),
    },
    .macos => switch (builtin.cpu.arch) {
        .x86_64 => "macos-x64",
        .aarch64 => "macos-arm64",
        else => @compileError("unsupported"),
    },
    else => @compileError("unsupported"),
};

fn replaceAll(gpa: std.mem.Allocator, haystack: []const u8, needle: []const u8, value: []const u8) ![]u8 {
    if (needle.len == 0) return gpa.dupe(u8, haystack);
    return std.mem.replaceOwned(u8, gpa, haystack, needle, value);
}

/// Finds the repository root by traversing upward from `start` until it finds
/// a directory containing a `.root` marker file. This allows the seed to be
/// invoked from any subdirectory within the repository.
///
/// The `.root` file is a dedicated marker (not `.git`) because the seed may
/// run before Git is available or in contexts where `.git` is not present.
fn findRoot(io: std.Io, start: std.Io.Dir) !std.Io.Dir {
    var current = try start.openDir(io, ".", .{});
    errdefer current.close(io);
    while (true) {
        current.access(io, ".root", .{}) catch |err| switch (err) {
            error.FileNotFound => {
                var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const path_len = try current.realPath(io, &path_buf);
                if (std.mem.eql(u8, path_buf[0..path_len], "/")) return error.NoRootFound;
                const parent = try current.openDir(io, "..", .{});
                current.close(io);
                current = parent;
                continue;
            },
            else => return err,
        };
        return current;
    }
}

/// Reads and parses the seed lockfile from the repository root.
fn readLock(gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir) !Lock {
    var lock_buf: [4096]u8 = undefined;
    const lock_data = try root.readFile(io, "seed.zon", &lock_buf);
    const lock_z = try gpa.dupeSentinel(u8, lock_data, 0);
    defer gpa.free(lock_z);
    return std.zon.parse.fromSliceAlloc(Lock, gpa, lock_z, null, .{});
}

/// Builds the download URL from the lockfile pattern.
fn buildUrl(gpa: std.mem.Allocator, lock: Lock) ![]u8 {
    const url_v = try replaceAll(gpa, lock.url, "{v}", lock.version);
    defer gpa.free(url_v);
    return replaceAll(gpa, url_v, "{p}", platform);
}

/// Bounds the response body while reading, then verifies its SHA256.
fn fetch(gpa: std.mem.Allocator, io: std.Io, url: []const u8, expected_sha: []const u8, max_bytes: usize) ![]u8 {
    var client: std.http.Client = .{ .io = io, .allocator = gpa };
    defer client.deinit();

    var request = try client.request(.GET, try std.Uri.parse(url), .{
        .redirect_behavior = @enumFromInt(3),
        .keep_alive = false,
    });
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [8192]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (response.head.status != .ok) return error.HttpError;

    // Match the client's accepted encodings without linking its unused zstd decoder.
    const container: ?std.compress.flate.Container = switch (response.head.content_encoding) {
        .identity => null,
        .gzip => .gzip,
        .deflate => .zlib,
        .zstd, .compress => return error.HttpContentEncodingUnsupported,
    };
    const decompress_size: usize = if (container != null) std.compress.flate.max_window_len else 0;
    const decompress_buffer = try gpa.alloc(u8, decompress_size);
    defer gpa.free(decompress_buffer);
    var transfer_buffer: [64]u8 = undefined;
    const transfer_reader = response.reader(&transfer_buffer);
    var decompress: std.compress.flate.Decompress = undefined;
    const reader = if (container) |format| reader: {
        decompress = .init(transfer_reader, format, decompress_buffer);
        break :reader &decompress.reader;
    } else transfer_reader;
    // One byte of lookahead accepts an exact-size body and detects overflow.
    const data = reader.allocRemaining(gpa, .limited(max_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return error.ArchiveTooLarge,
        error.ReadFailed => return response.bodyErr() orelse error.ReadFailed,
        else => return err,
    };
    errdefer gpa.free(data);
    if (data.len > max_bytes) return error.ArchiveTooLarge;
    try verifyHash(data, expected_sha);
    return data;
}

/// Requires a full SHA256 encoding before comparing any digest bytes.
fn verifyHash(data: []const u8, expected_sha: []const u8) !void {
    if (expected_sha.len != 64) return error.InvalidHash;
    var expected: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, expected_sha) catch return error.InvalidHash;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    if (!std.mem.eql(u8, &digest, &expected)) return error.HashMismatch;
}

/// Reads only the expected regular file; archive paths never touch the filesystem.
fn extract(gpa: std.mem.Allocator, tarball: []const u8) ![]u8 {
    var reader: std.Io.Reader = .fixed(tarball);
    var decomp_buffer: [65536]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(&reader, .gzip, &decomp_buffer);
    var name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var archive = std.tar.Iterator.init(&decomp.reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
    });
    var binary: ?[]u8 = null;
    errdefer if (binary) |data| gpa.free(data);
    while (try archive.next()) |entry| {
        if (!std.mem.eql(u8, entry.name, "mise/bin/mise")) continue;
        if (entry.kind != .file) return error.InvalidBinaryEntry;
        if (binary != null) return error.DuplicateBinaryEntry;
        // Bound allocations from untrusted archive size metadata.
        if (entry.size > 256 * 1024 * 1024) return error.BinaryTooLarge;
        binary = try gpa.alloc(u8, @intCast(entry.size));
        try archive.reader.readSliceAll(binary.?);
        archive.unread_file_bytes = 0;
    }
    _ = try decomp.reader.discardRemaining();
    return binary orelse error.MissingBinary;
}

/// Verifies before writing, then publishes an executable replacement atomically.
fn install(io: std.Io, base: std.Io.Dir, dest_path: []const u8, binary: []const u8, expected_sha: []const u8) !void {
    verifyHash(binary, expected_sha) catch |err| switch (err) {
        error.HashMismatch => return error.ExtractedHashMismatch,
        else => return err,
    };
    const dest = try base.createDirPathOpen(io, dest_path, .{});
    defer dest.close(io);

    var pending = try dest.createFileAtomic(io, "mise", .{ .replace = true });
    defer pending.deinit(io);
    try pending.file.writeStreamingAll(io, binary);
    try pending.file.setPermissions(io, .fromMode(0o755));
    try pending.file.sync(io);
    try pending.replace(io);
}

pub fn main(init: std.process.Init.Minimal) !void {
    // Keep the allocator policy for single-threaded builds without unused process services.
    const use_debug_allocator = builtin.mode == .Debug or !builtin.link_libc;
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = if (use_debug_allocator) debug_allocator.allocator() else std.heap.c_allocator;
    defer if (use_debug_allocator) {
        _ = debug_allocator.deinit();
    };
    var threaded: std.Io.Threaded = .init(gpa, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer threaded.deinit();

    var args = init.args.iterate();
    _ = args.next();
    const dest_path = args.next();

    try bootstrap(gpa, threaded.io(), .cwd(), dest_path);
}

fn bootstrap(gpa: std.mem.Allocator, io: std.Io, start: std.Io.Dir, dest_path: ?[]const u8) !void {
    const root = try findRoot(io, start);
    defer root.close(io);
    const lock = try readLock(gpa, io, root);
    defer std.zon.parse.free(gpa, lock);

    const hashes = @field(lock.hashes, platform);
    const url = try buildUrl(gpa, lock);
    defer gpa.free(url);

    const binary = binary: {
        const tarball = try fetch(gpa, io, url, hashes.tarball, 256 * 1024 * 1024);
        defer gpa.free(tarball);
        break :binary try extract(gpa, tarball);
    };
    defer gpa.free(binary);

    try install(io, if (dest_path != null) start else root, dest_path orelse "bin", binary, hashes.binary);
}

// Tests

test "replace: single occurrence" {
    const gpa = std.testing.allocator;
    const result = try replaceAll(gpa, "hello {v} world", "{v}", "1.0");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("hello 1.0 world", result);
}

test "replace: multiple occurrences" {
    const gpa = std.testing.allocator;
    const result = try replaceAll(gpa, "{v}/mise-v{v}-{p}", "{v}", "2026.9.1");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("2026.9.1/mise-v2026.9.1-{p}", result);
}

test "replace: no match returns copy" {
    const gpa = std.testing.allocator;
    const result = try replaceAll(gpa, "no placeholders", "{v}", "1.0");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("no placeholders", result);
}

test "zon: repository manifest matches the seed contract" {
    const io = std.testing.io;
    var root = try findRoot(io, std.Io.Dir.cwd());
    defer root.close(io);
    const lock = try readLock(std.testing.allocator, io, root);
    defer std.zon.parse.free(std.testing.allocator, lock);
}

test "zon: parse valid lockfile" {
    const gpa = std.testing.allocator;
    const zon =
        \\.{
        \\    .url = "https://example.com/{v}/{p}",
        \\    .version = "1.0.0",
        \\    .hashes = .{
        \\        .@"linux-x64" = .{ .tarball = "abc123", .binary = "def456" },
        \\        .@"linux-arm64" = .{ .tarball = "ghi789", .binary = "jkl012" },
        \\        .@"macos-x64" = .{ .tarball = "mno345", .binary = "pqr678" },
        \\        .@"macos-arm64" = .{ .tarball = "stu901", .binary = "vwx234" },
        \\    },
        \\}
    ;
    const lock = try std.zon.parse.fromSliceAlloc(Lock, gpa, zon, null, .{});
    defer std.zon.parse.free(gpa, lock);
    try std.testing.expectEqualStrings("1.0.0", lock.version);
    try std.testing.expectEqualStrings("abc123", lock.hashes.@"linux-x64".tarball);
    try std.testing.expectEqualStrings("def456", lock.hashes.@"linux-x64".binary);
}

test "platform: is compile-time constant" {
    try std.testing.expect(platform.len > 0);
    if (builtin.os.tag == .macos and builtin.cpu.arch == .aarch64) {
        try std.testing.expectEqualStrings("macos-arm64", platform);
    }
}

test "replaceAll: empty needle returns copy" {
    const gpa = std.testing.allocator;
    const result = try replaceAll(gpa, "test", "", "x");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("test", result);
}

test "replaceAll: needle larger than haystack" {
    const gpa = std.testing.allocator;
    const result = try replaceAll(gpa, "ab", "abcdef", "x");
    defer gpa.free(result);
    try std.testing.expectEqualStrings("ab", result);
}

test "zon: parse fails on invalid structure" {
    const gpa = std.testing.allocator;
    const bad_zon = ".{ .version = 123 }"; // version should be string
    const result = std.zon.parse.fromSliceAlloc(Lock, gpa, bad_zon, null, .{});
    try std.testing.expectError(error.ParseZon, result);
}

test "zon: parse fails on missing required field" {
    const gpa = std.testing.allocator;
    const incomplete_zon =
        \\.{
        \\    .url = "https://example.com/{v}/{p}",
        \\}
    ;
    const result = std.zon.parse.fromSliceAlloc(Lock, gpa, incomplete_zon, null, .{});
    try std.testing.expectError(error.ParseZon, result);
}

fn digestHex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "hash: exact length, valid hex, and matching content are required" {
    const hash = digestHex("payload");
    try verifyHash("payload", &hash);
    try std.testing.expectError(error.HashMismatch, verifyHash("tampered", &hash));
    for ([_][]const u8{ "", "ab", &(@as([64]u8, @splat('g'))), &(@as([66]u8, @splat('0'))) }) |bad| {
        try std.testing.expectError(error.InvalidHash, verifyHash("payload", bad));
    }
}

test "root: nested discovery owns its handle and leaves the caller open" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".root", .data = "" });
    const nested = try tmp.dir.createDirPathOpen(io, "a/b", .{});
    defer nested.close(io);
    const root = try findRoot(io, nested);
    defer root.close(io);
    try root.access(io, ".root", .{});
    try nested.access(io, ".", .{});
}

test "root: filesystem root without a marker terminates" {
    const io = std.testing.io;
    const root = try std.Io.Dir.openDirAbsolute(io, "/", .{});
    defer root.close(io);
    root.access(io, ".root", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try std.testing.expectError(error.NoRootFound, findRoot(io, root));
            return;
        },
        else => return err,
    };
    return error.SkipZigTest;
}

fn allocationReplacement(gpa: std.mem.Allocator) !void {
    const replaced = try replaceAll(gpa, "{v}/{v}/{p}", "{v}", "version");
    defer gpa.free(replaced);
    try std.testing.expectEqualStrings("version/version/{p}", replaced);
}

test "replace: allocation failures release owned memory" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationReplacement, .{});
}

const ArchiveFixture = enum { valid, missing, duplicate, symlink, traversal };

fn fixtureArchive(gpa: std.mem.Allocator, kind: ArchiveFixture) ![]u8 {
    var output: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer output.deinit();
    var buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var gzip = try std.compress.flate.Compress.init(&output.writer, &buffer, .gzip, .fastest);
    var tar: std.tar.Writer = .{ .underlying_writer = &gzip.writer };
    try tar.writeFileBytes("mise/README", "ignored", .{});
    switch (kind) {
        .valid => try tar.writeFileBytes("mise/bin/mise", "payload", .{}),
        .missing => {},
        .duplicate => {
            try tar.writeFileBytes("mise/bin/mise", "first", .{});
            try tar.writeFileBytes("mise/bin/mise", "second", .{});
        },
        .symlink => try tar.writeLink("mise/bin/mise", "/bin/sh", .{}),
        .traversal => try tar.writeFileBytes("../../mise/bin/mise", "payload", .{}),
    }
    try tar.finishPedantically();
    try gzip.finish();
    return output.toOwnedSlice();
}

fn allocationExtract(gpa: std.mem.Allocator, archive: []const u8) !void {
    const binary = try extract(gpa, archive);
    defer gpa.free(binary);
    try std.testing.expectEqualStrings("payload", binary);
}

test "archive: reads expected file and handles allocation failure" {
    const gpa = std.testing.allocator;
    const archive = try fixtureArchive(gpa, .valid);
    defer gpa.free(archive);
    try std.testing.checkAllAllocationFailures(gpa, allocationExtract, .{archive});
}

test "archive: rejects missing, duplicate, symlink, and traversal substitutes" {
    const gpa = std.testing.allocator;
    const cases = .{
        .{ ArchiveFixture.missing, error.MissingBinary },
        .{ ArchiveFixture.duplicate, error.DuplicateBinaryEntry },
        .{ ArchiveFixture.symlink, error.InvalidBinaryEntry },
        .{ ArchiveFixture.traversal, error.MissingBinary },
    };
    inline for (cases) |case| {
        const archive = try fixtureArchive(gpa, case[0]);
        defer gpa.free(archive);
        try std.testing.expectError(case[1], extract(gpa, archive));
    }
}

test "archive: truncation fails without leaking a partially read binary" {
    const gpa = std.testing.allocator;
    const archive = try fixtureArchive(gpa, .valid);
    defer gpa.free(archive);
    for ([_]usize{ 0, 10, archive.len / 2, archive.len - 8 }) |end| {
        if (extract(gpa, archive[0..end])) |binary| {
            defer gpa.free(binary);
            return error.TestUnexpectedResult;
        } else |_| {
            // Any parser/decompressor error is acceptable for truncated input.
        }
    }
}

fn expectInstalled(dir: std.Io.Dir, expected: []const u8) !void {
    const gpa = std.testing.allocator;
    const data = try dir.readFileAlloc(std.testing.io, "mise", gpa, .unlimited);
    defer gpa.free(data);
    try std.testing.expectEqualStrings(expected, data);
    const stat = try dir.statFile(std.testing.io, "mise", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o755), stat.permissions.toMode() & 0o7777);
}

test "install: replaces stale content and repairs permissions on repeated runs" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path);
    try tmp.dir.writeFile(io, .{ .sub_path = "mise", .data = "old" });
    const hash = digestHex("payload");
    try install(io, .cwd(), path[0..path_len], "payload", &hash);
    try expectInstalled(tmp.dir, "payload");
    for ([_]std.posix.mode_t{ 0o600, 0o777 }) |mode| {
        const file = try tmp.dir.openFile(io, "mise", .{});
        defer file.close(io);
        try file.setPermissions(io, .fromMode(mode));
        try install(io, .cwd(), path[0..path_len], "payload", &hash);
        try expectInstalled(tmp.dir, "payload");
    }
}

test "install: bad hashes preserve an existing executable" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path);
    const hash = digestHex("old");
    try install(io, .cwd(), path[0..path_len], "old", &hash);
    try std.testing.expectError(error.ExtractedHashMismatch, install(io, .cwd(), path[0..path_len], "new", &hash));
    try std.testing.expectError(error.InvalidHash, install(io, .cwd(), path[0..path_len], "new", "ab"));
    try expectInstalled(tmp.dir, "old");
}

test "install: incompatible destination leaves an existing directory intact" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const occupied = try tmp.dir.createDirPathOpen(io, "mise", .{});
    defer occupied.close(io);
    try occupied.writeFile(io, .{ .sub_path = "sentinel", .data = "keep" });
    var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path);
    const hash = digestHex("payload");
    if (install(io, .cwd(), path[0..path_len], "payload", &hash)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {
        // Filesystem error details vary by host; preservation is the contract.
    }
    try occupied.access(io, "sentinel", .{});
}

fn fuzzReplacement(_: void, smith: *std.testing.Smith) !void {
    var input: [256]u8 = undefined;
    try checkReplacement(input[0..smith.slice(&input)]);
}

fn checkReplacement(bytes: []const u8) !void {
    const gpa = std.testing.allocator;
    const result = try replaceAll(gpa, bytes, "x", "yy");
    defer gpa.free(result);
    var expected: std.Io.Writer.Allocating = .init(gpa);
    defer expected.deinit();
    for (bytes) |byte| {
        if (byte == 'x') {
            try expected.writer.writeAll("yy");
        } else {
            try expected.writer.writeByte(byte);
        }
    }
    try std.testing.expectEqualStrings(expected.written(), result);
}

test "replace: deterministic randomized inputs match a bytewise reference" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    var input: [256]u8 = undefined;
    for (0..1000) |_| {
        const bytes = input[0..random.intRangeAtMost(usize, 0, input.len)];
        random.bytes(bytes);
        try checkReplacement(bytes);
    }
    try checkReplacement("xxxx");
    try checkReplacement("no matches");
}

test "replace: fuzz against a bytewise reference" {
    try std.testing.fuzz({}, fuzzReplacement, .{});
}

fn serveFixture(io: std.Io, server: *std.Io.net.Server, body: []const u8, options: std.http.Server.Request.RespondOptions) !void {
    const stream = try server.accept(io);
    defer stream.close(io);
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var writer = stream.writer(io, &write_buffer);
    var http = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try http.receiveHead();
    try request.respond(body, options);
}

test "fetch: bounds decoded bytes for content-length and chunked responses" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const payload = "x" ** 128;
    const hash = digestHex(payload);
    for ([_]std.http.ContentEncoding{ .identity, .gzip, .deflate }) |encoding| {
        var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 256);
        defer compressed.deinit();
        if (encoding == .identity) {
            try compressed.writer.writeAll(payload);
        } else {
            var buffer: [std.compress.flate.max_window_len]u8 = undefined;
            var encoder = try std.compress.flate.Compress.init(&compressed.writer, &buffer, if (encoding == .gzip) .gzip else .zlib, .fastest);
            try encoder.writer.writeAll(payload);
            try encoder.finish();
            try std.testing.expect(compressed.written().len < payload.len - 1);
        }
        for ([_]bool{ false, true }) |chunked| {
            for ([_]usize{ payload.len - 1, payload.len, payload.len + 1 }) |limit| {
                const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
                var server = try address.listen(io, .{});
                defer server.deinit(io);
                const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/archive", .{server.socket.address.getPort()});
                defer gpa.free(url);
                const options: std.http.Server.Request.RespondOptions = .{
                    .keep_alive = false,
                    .transfer_encoding = if (chunked) .chunked else null,
                    .extra_headers = if (encoding == .identity) &.{} else &.{.{ .name = "Content-Encoding", .value = @tagName(encoding) }},
                };
                var task = try io.concurrent(serveFixture, .{ io, &server, compressed.written(), options });
                defer task.cancel(io) catch |err| switch (err) {
                    error.Canceled => {},
                    else => std.log.err("fixture server failed: {t}", .{err}),
                };
                if (limit < payload.len) {
                    try std.testing.expectError(error.ArchiveTooLarge, fetch(gpa, io, url, &hash, limit));
                } else {
                    const data = try fetch(gpa, io, url, &hash, limit);
                    defer gpa.free(data);
                    try std.testing.expectEqualStrings(payload, data);
                }
                try task.await(io);
            }
        }
    }
}

test "fetch: rejects unsupported encodings and malformed compressed bodies" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cases = .{
        .{ "zstd", error.HttpContentEncodingUnsupported },
        .{ "compress", error.HttpContentEncodingUnsupported },
        .{ "gzip", error.ReadFailed },
        .{ "deflate", error.ReadFailed },
    };
    inline for (cases) |case| {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var server = try address.listen(io, .{});
        defer server.deinit(io);
        const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/archive", .{server.socket.address.getPort()});
        defer gpa.free(url);
        const body = "not compressed";
        const hash = digestHex(body);
        const options: std.http.Server.Request.RespondOptions = .{
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "Content-Encoding", .value = case[0] }},
        };
        var task = try io.concurrent(serveFixture, .{ io, &server, body, options });
        defer task.cancel(io) catch |err| switch (err) {
            error.Canceled => {},
            else => std.log.err("fixture server failed: {t}", .{err}),
        };
        try std.testing.expectError(case[1], fetch(gpa, io, url, &hash, body.len));
        try task.await(io);
    }
}

fn serveRedirectFixture(io: std.Io, server: *std.Io.net.Server, url: []const u8) !void {
    try serveFixture(io, server, "", .{
        .status = .found,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "Location", .value = url }},
    });
    try serveFixture(io, server, "payload", .{ .keep_alive = false });
}

test "fetch: follows release redirects and verifies the final body" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/release", .{server.socket.address.getPort()});
    defer gpa.free(url);
    var task = try io.concurrent(serveRedirectFixture, .{ io, &server, url });
    defer task.cancel(io) catch |err| switch (err) {
        error.Canceled => {},
        else => std.log.err("fixture server failed: {t}", .{err}),
    };
    const hash = digestHex("payload");
    const data = try fetch(gpa, io, url, &hash, 7);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("payload", data);
    try task.await(io);
}

test "bootstrap: local HTTP download, lockfile, extraction, and atomic install" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const archive = try fixtureArchive(gpa, .valid);
    defer gpa.free(archive);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".root", .data = "" });
    const nested = try tmp.dir.createDirPathOpen(io, "nested", .{});
    defer nested.close(io);
    const cases = .{
        .{ std.http.Status.ok, false, false, @as(?anyerror, null) },
        .{ std.http.Status.not_found, false, false, @as(?anyerror, error.HttpError) },
        .{ std.http.Status.ok, true, false, @as(?anyerror, error.HashMismatch) },
        .{ std.http.Status.ok, false, true, @as(?anyerror, error.ExtractedHashMismatch) },
    };
    inline for (cases) |case| {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var server = try address.listen(io, .{});
        defer server.deinit(io);
        const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/{{v}}/{{p}}.tar.gz", .{server.socket.address.getPort()});
        defer gpa.free(url);
        const tar_hash = digestHex(if (case[1]) "incorrect" else archive);
        const bin_hash = digestHex(if (case[2]) "incorrect" else "payload");
        const hashes: Hash = .{ .tarball = &tar_hash, .binary = &bin_hash };
        const lock: Lock = .{
            .url = url,
            .version = "fixture",
            .hashes = .{
                .@"linux-x64" = hashes,
                .@"linux-arm64" = hashes,
                .@"macos-x64" = hashes,
                .@"macos-arm64" = hashes,
            },
        };
        var zon: std.Io.Writer.Allocating = .init(gpa);
        defer zon.deinit();
        try std.zon.stringify.serialize(lock, .{}, &zon.writer);
        try tmp.dir.writeFile(io, .{ .sub_path = "seed.zon", .data = zon.written() });
        var task = try io.concurrent(serveFixture, .{ io, &server, archive, std.http.Server.Request.RespondOptions{ .status = case[0], .keep_alive = false } });
        defer task.cancel(io) catch |err| switch (err) {
            error.Canceled => {},
            else => std.log.err("fixture server failed: {t}", .{err}),
        };
        if (case[3]) |expected| {
            try std.testing.expectError(expected, bootstrap(gpa, io, nested, null));
        } else {
            try bootstrap(gpa, io, nested, null);
        }
        try task.await(io);
        const dest = try tmp.dir.openDir(io, "bin", .{});
        defer dest.close(io);
        // Later failed downloads and verification must preserve the first install.
        try expectInstalled(dest, "payload");
        try std.testing.expectError(error.FileNotFound, nested.access(io, "bin", .{}));
    }
}

test "install: replaces symlinks without changing their targets" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "target", .data = "payload" });
    const target = try tmp.dir.openFile(io, "target", .{});
    defer target.close(io);
    try target.setPermissions(io, .fromMode(0o600));
    const hash = digestHex("payload");
    const dest = try tmp.dir.createDirPathOpen(io, "bin", .{});
    defer dest.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "stale", .data = "old" });
    for ([_][]const u8{ "../target", "../stale", "../missing" }) |link_target| {
        try dest.symLink(io, link_target, "mise", .{});
        try install(io, tmp.dir, "bin", "payload", &hash);
        try expectInstalled(dest, "payload");
        const installed = try dest.statFile(io, "mise", .{ .follow_symlinks = false });
        try std.testing.expectEqual(std.Io.File.Kind.file, installed.kind);
        try dest.deleteFile(io, "mise");
    }
    const stat = try target.stat(io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o7777);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("payload", try tmp.dir.readFile(io, "target", &buf));
    try std.testing.expectEqualStrings("old", try tmp.dir.readFile(io, "stale", &buf));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "missing", .{}));
}
