const std = @import("std");
const gvm = @import("gvm");
const args = @import("args.zig");
const print = @import("print.zig");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var arg_arena = std.heap.ArenaAllocator.init(gpa);
    defer arg_arena.deinit();
    const arena = arg_arena.allocator();
    const arg_slice = try init.minimal.args.toSlice(arena);
    const cmd = try args.parse(arg_slice);

    return switch (cmd) {
        .check => @panic("todo"),
        .print => |print_args| print.main(gpa, io, print_args),
        .run => @panic("todo"),
    };
}
