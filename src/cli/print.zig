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

fn printModule(out: *std.Io.Writer, module_reader: gvm.parse.ModuleReader) !void {
    var reader = module_reader;
    try out.writeAll("(module\n");
    while (try reader.next()) |item| {
        switch (item) {
            .function => |f| try printFunction(out, f.reader),
            .memory => |m| {
                try out.print("  (memory {})\n", .{m.memory_size});
            },
            .global => |g| if (g.global_count == 0)
                try out.writeAll("  (global)\n")
            else
                try printGlobal(out, g.reader),
            .start => |s| {
                try out.print("  (start {})\n", .{s.function_id});
            },
            .code => |c| try printCode(out, c.reader),
            .data => |d| {
                try out.writeAll("  (data ");
                try printBytes(out, d.data);
                try out.writeAll(")\n");
            },
        }
    }
    try out.writeAll(")\n");
}

fn printFunction(out: *std.Io.Writer, function_reader: gvm.parse.FunctionReader) !void {
    var reader = function_reader;
    try out.writeAll("  (function\n");
    while (try reader.next()) |decl| {
        try out.writeAll("    (func ");
        try printBytes(out, decl.name);
        try out.print(" {} {})\n", .{ decl.in, decl.out });
    }
    try out.writeAll("  )\n");
}

fn printGlobal(out: *std.Io.Writer, global_reader: gvm.parse.GlobalReader) !void {
    var reader = global_reader;
    try out.writeAll("  (global\n");
    while (try reader.next()) |def| {
        try out.writeAll("    (");
        try printBytes(out, def.name);
        try out.print(" {})\n", .{def.init});
    }
    try out.writeAll("  )\n");
}

fn printCode(out: *std.Io.Writer, code_reader: gvm.parse.CodeReader) !void {
    var reader = code_reader;
    try out.writeAll("  (code \n");
    while (try reader.next()) |def| {
        try out.print("    (func (locals {})\n", .{def.locals});
        var op_reader = def.reader;
        while (try op_reader.next()) |op| {
            switch (op) {
                inline else => |payload, tag| {
                    if (@TypeOf(payload) == void) {
                        try out.print("      {s}\n", .{@tagName(tag)});
                    } else if (@TypeOf(payload) == u32) {
                        try out.print("      {s} {}\n", .{ @tagName(tag), payload });
                    } else {
                        try out.print(
                            "      {s} {} {}\n",
                            .{ @tagName(tag), payload.in, payload.out },
                        );
                    }
                },
            }
        }
        try out.writeAll("    )\n");
    }
    try out.writeAll("  )\n");
}

fn printBytes(out: *std.Io.Writer, bytes: []const u8) !void {
    try out.writeAll("\"");
    for (bytes) |byte| {
        switch (byte) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            ' '...'!', '#'...'[', ']'...'~' => try out.writeByte(byte),
            else => try out.print("\\x{x:0>2}", .{byte}),
        }
    }
    try out.writeAll("\"");
}
