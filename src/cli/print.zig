const std = @import("std");
const gvm = @import("gvm");
const common = @import("common.zig");

const Args = @import("args.zig").PrintArgs;

pub fn main(gpa: std.mem.Allocator, io: std.Io, args: Args) !u8 {
    const stdout = common.stdout(io);

    const bytes = try common.readAlloc(gpa, io, args._path);
    defer gpa.free(bytes);

    const reader = try gvm.parse.ModuleReader.init(bytes);

    try printModule(stdout, reader);

    try stdout.flush();
    return 0;
}

fn printModule(stdout: *std.Io.Writer, module_reader: gvm.parse.ModuleReader) !void {
    var reader = module_reader;
    try stdout.writeAll("(module\n");
    while (try reader.next()) |item| {
        switch (item) {
            .function => |f| try printFunction(stdout, f.reader),
            .memory => |m| {
                try stdout.print("  (memory {})\n", .{m.memory_size});
            },
            .global => |g| if (g.global_count == 0)
                try stdout.writeAll("  (global)\n")
            else
                try printGlobal(stdout, g.reader),
            .start => |s| {
                try stdout.print("  (start {})\n", .{s.function_id});
            },
            .code => |c| try printCode(stdout, c.reader),
            .data => |d| {
                try stdout.writeAll("  (data ");
                try printBytes(stdout, d.data);
                try stdout.writeAll(")\n");
            },
        }
    }
    try stdout.writeAll(")\n");
}

fn printFunction(stdout: *std.Io.Writer, function_reader: gvm.parse.FunctionReader) !void {
    var reader = function_reader;
    try stdout.writeAll("  (function\n");
    while (try reader.next()) |decl| {
        try stdout.writeAll("    (func ");
        try printBytes(stdout, decl.name);
        try stdout.print(" {} {})\n", .{ decl.in, decl.out });
    }
    try stdout.writeAll("  )\n");
}

fn printGlobal(stdout: *std.Io.Writer, global_reader: gvm.parse.GlobalReader) !void {
    var reader = global_reader;
    try stdout.writeAll("  (global\n");
    while (try reader.next()) |decl| {
        try stdout.writeAll("    (");
        try printBytes(stdout, decl.name);
        try stdout.print(" {})\n", .{decl.init});
    }
    try stdout.writeAll("  )\n");
}

fn printCode(stdout: *std.Io.Writer, code_reader: gvm.parse.CodeReader) !void {
    var reader = code_reader;
    try stdout.writeAll("  (code \n");
    while (try reader.next()) |def| {
        try stdout.print("    (func (locals {})\n", .{def.locals});
        var op_reader = def.reader;
        while (try op_reader.next()) |op| {
            switch (op) {
                inline else => |payload, tag| {
                    if (@TypeOf(payload) == void) {
                        try stdout.print("      {s}\n", .{@tagName(tag)});
                    } else if (@TypeOf(payload) == u32) {
                        try stdout.print("      {s} {}\n", .{ @tagName(tag), payload });
                    } else {
                        try stdout.print(
                            "      {s} {} {}\n",
                            .{ @tagName(tag), payload.in, payload.out },
                        );
                    }
                },
            }
        }
        try stdout.writeAll("    )\n");
    }
    try stdout.writeAll("  )\n");
}

fn printBytes(stdout: *std.Io.Writer, bytes: []const u8) !void {
    try stdout.writeAll("\"");
    for (bytes) |byte| {
        switch (byte) {
            '"' => try stdout.writeAll("\\\""),
            '\\' => try stdout.writeAll("\\\\"),
            ' '...'!', '#'...'[', ']'...'~' => try stdout.writeByte(byte),
            else => try stdout.print("\\x{x:0>2}", .{byte}),
        }
    }
    try stdout.writeAll("\"");
}
