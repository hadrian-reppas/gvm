const std = @import("std");
const gvm = @import("gvm");
const common = @import("common.zig");

const Args = @import("args.zig").PrintArgs;

pub fn main(gpa: std.mem.Allocator, io: std.Io, args: Args) !u8 {
    const stdout = common.stdout(io);

    const bytes = try common.readAlloc(gpa, io, args._path);
    defer gpa.free(bytes);

    try stdout.writeAll("(module\n");
    var module_reader = try gvm.parse.ModuleReader.init(bytes);
    while (try module_reader.next()) |item| {
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
                try stdout.print("  (data {s})\n", .{d.data});
            },
        }
    }

    try stdout.writeAll(")\n");
    try stdout.flush();
    return 0;
}

fn printFunction(stdout: *std.Io.Writer, function_reader: gvm.parse.FunctionReader) !void {
    var reader = function_reader;
    try stdout.writeAll("  (function\n");
    while (try reader.next()) |decl| {
        try stdout.print("    (func {s} {} {})\n", .{ decl.name, decl.in, decl.out });
    }
    try stdout.writeAll("  )\n");
}

fn printGlobal(stdout: *std.Io.Writer, global_reader: gvm.parse.GlobalReader) !void {
    var reader = global_reader;
    try stdout.writeAll("  (global\n");
    while (try reader.next()) |decl| {
        try stdout.print("    ({s} {})\n", .{ decl.name, decl.init });
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
