const std = @import("std");

var stdout_buffer: [4096]u8 = undefined;
var stdout_writer: std.Io.File.Writer = undefined;

pub fn stdout(io: std.Io) *std.Io.Writer {
    stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    return &stdout_writer.interface;
}

pub fn readAlloc(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(gpa, .unlimited);
}
