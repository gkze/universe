const std = @import("std");
const options = @import("options");

test "committed native seed rejects malformed input before installation" {
    const io = std.testing.io;
    var fixture = std.testing.tmpDir(.{});
    defer fixture.cleanup();
    try fixture.dir.writeFile(io, .{ .sub_path = ".root", .data = "" });
    try fixture.dir.writeFile(io, .{ .sub_path = "seed.zon", .data = "invalid manifest\n" });
    const result = try std.process.run(std.testing.allocator, io, .{
        .argv = &.{options.launcher},
        .cwd = .{ .dir = fixture.dir },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited != 0);
    try std.testing.expect(std.mem.find(u8, result.stderr, "ParseZon") != null);
    try std.testing.expectError(error.FileNotFound, fixture.dir.access(io, "bin/mise", .{}));
}
