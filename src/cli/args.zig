const std = @import("std");

pub const PrintArgs = struct { _path: [:0]const u8, color: bool = false };
pub const RunArgs = struct {
    _path: [:0]const u8,
    self: u4 = 0,
    east: u4 = 0,
    northeast: u4 = 0,
    north: u4 = 0,
    northwest: u4 = 0,
    west: u4 = 0,
    southwest: u4 = 0,
    south: u4 = 0,
    southeast: u4 = 0,
    time: u32 = 0,
    age: u32 = 0,
    row: u4 = 0,
    col: u4 = 0,
};

pub const Cmd = union(enum) {
    check: PrintArgs,
    print: PrintArgs,
    run: RunArgs,
};

pub fn parse(args: []const [:0]const u8) !Cmd {
    if (args.len < 2) return error.InvalidArgs;
    const rest = args[2..];
    inline for (std.meta.fields(Cmd)) |field| {
        if (std.mem.eql(u8, args[1], field.name)) {
            if (field.type == void) {
                if (rest.len != 0) return error.InvalidArgs;
                return @unionInit(Cmd, field.name, {});
            }
            return @unionInit(Cmd, field.name, try parseStruct(field.type, rest));
        }
    }
    return error.InvalidArgs;
}

fn parseStruct(comptime T: type, args: []const [:0]const u8) !T {
    const fields = std.meta.fields(T);
    var result: T = undefined;
    const Status = enum { default, seen, not_seen };
    var status = [_]Status{.not_seen} ** fields.len;

    inline for (fields, 0..) |field, i| {
        if (field.defaultValue()) |default| {
            @field(result, field.name) = default;
            status[i] = .default;
        }
    }

    var positional_seen: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--")) {
            const name = arg[2..];
            var matched = false;
            inline for (fields, 0..) |field, fi| {
                if (field.name[0] != '_' and std.mem.eql(u8, name, field.name)) {
                    matched = true;
                    if (status[fi] == .seen) return error.InvalidArguments;
                    if (field.type == bool) {
                        @field(result, field.name) = true;
                    } else {
                        i += 1;
                        if (i >= args.len) return error.InvalidArgs;
                        @field(result, field.name) = try parseValue(field.type, args[i]);
                    }
                    status[fi] = .seen;
                }
            }
            if (!matched) return error.InvalidArgs;
        } else {
            var matched = false;
            var positional_index: usize = 0;
            inline for (fields, 0..) |field, fi| {
                if (field.name[0] == '_') {
                    if (positional_index == positional_seen) {
                        @field(result, field.name) = try parseValue(field.type, arg);
                        status[fi] = .seen;
                        matched = true;
                    }
                    positional_index += 1;
                }
            }
            if (!matched) return error.InvalidArgs;
            positional_seen += 1;
        }
    }

    for (status) |s| {
        if (s == .not_seen) return error.InvalidArgs;
    }

    return result;
}

fn parseValue(comptime T: type, arg: [:0]const u8) !T {
    return switch (@typeInfo(T)) {
        .int => std.fmt.parseInt(T, arg, 10) catch return error.InvalidArgs,
        .pointer => |p| if (p.size == .slice and p.child == u8)
            arg
        else
            @compileError("unsupported argument type: " ++ @typeName(T)),
        else => @compileError("unsupported argument type: " ++ @typeName(T)),
    };
}
