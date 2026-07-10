const std = @import("std");
const parse = @import("parse.zig");

const Frame = struct {
    const Kind = enum { function, block, loop, @"if", @"else" };

    kind: Kind,
    sig: parse.Sig,
    stack_size: u32,
    @"unreachable": bool,

    fn jumpValues(self: Frame) u32 {
        return if (self.kind == .loop) self.sig.in else self.sig.out;
    }
};

pub const Validator = struct {
    gpa: std.mem.Allocator,
    function_signatures: std.ArrayList(parse.Sig),
    globals: u32,

    total_locals: u32,
    return_values: u32,
    stack_size: u32,
    max_stack_size: u32,
    control_frames: std.ArrayList(Frame),

    pub fn init(gpa: std.mem.Allocator) Validator {
        return .{
            .gpa = gpa,
            .function_signatures = .empty,
            .globals = 0,
            .total_locals = undefined,
            .return_values = undefined,
            .stack_size = undefined,
            .max_stack_size = undefined,
            .control_frames = .empty,
        };
    }

    pub fn deinit(self: *Validator) void {
        self.function_signatures.deinit(self.gpa);
        self.control_frames.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn declareFunctionCount(self: *Validator, count: u32) !void {
        if (count > 0) {
            self.function_signatures = try .initCapacity(self.gpa, @intCast(count));
        }
    }

    pub fn declareFunction(self: *Validator, decl: parse.FunctionDecl) void {
        self.function_signatures.appendAssumeCapacity(.{ .in = decl.in, .out = decl.out });
    }

    pub fn declareGlobalCount(self: *Validator, count: u32) void {
        self.globals = count;
    }

    pub fn validateStart(self: *const Validator, start_function_id: u32) !void {
        if (@as(usize, @intCast(start_function_id)) >= self.function_signatures.items.len) {
            return error.InvalidBytecode; // TODO: Use multiple, more descriptive errors
        }
    }

    pub fn enterFunctionBody(self: *Validator, total_locals: u32, returns: u32) !void {
        self.total_locals = total_locals;
        self.return_values = returns;
        self.stack_size = 0;
        self.max_stack_size = 0;
        try self.pushFrame(.function, .{ .in = 0, .out = returns });
    }

    pub fn exitFunctionBody(self: *Validator) !void {
        if (self.control_frames.items.len != 0)
            return error.InvalidBytecode;
        self.total_locals = undefined;
        self.return_values = undefined;
        self.stack_size = undefined;
        self.max_stack_size = undefined;
    }

    pub fn validateInstr(self: *Validator, instr: parse.Instr) !void {
        _ = try self.peekFrame();

        if (std.meta.activeTag(instr).signature()) |sig| {
            try self.popValues(sig.in);
            try self.pushValues(sig.out);
            return;
        }

        switch (instr) {
            .@"unreachable" => try self.markUnreachable(),
            .block => |sig| {
                try self.popValues(sig.in);
                try self.pushFrame(.block, sig);
            },
            .loop => |sig| {
                try self.popValues(sig.in);
                try self.pushFrame(.loop, sig);
            },
            .@"if" => |sig| {
                try self.popValues(sig.in + 1);
                try self.pushFrame(.@"if", sig);
            },
            .@"else" => {
                const frame = try self.popFrame();
                if (frame.kind != .@"if")
                    return error.InvalidBytecode;
                try self.pushFrame(.@"else", frame.sig);
            },
            .end => {
                const frame = try self.popFrame();
                if (frame.kind == .@"if" and frame.sig.in != frame.sig.out)
                    return error.InvalidBytecode;
                if (self.control_frames.items.len > 0)
                    try self.pushValues(frame.sig.out);
            },
            .br => |l| {
                const frame = try self.frameForLabel(l);
                try self.popValues(frame.jumpValues());
                try self.markUnreachable();
            },
            .br_if => |l| {
                const frame = try self.frameForLabel(l);
                try self.popValues(frame.jumpValues() + 1);
                try self.pushValues(frame.jumpValues());
            },
            .@"return" => {
                try self.popValues(self.return_values);
                try self.markUnreachable();
            },
            .call => |i| if (i < self.function_signatures.items.len) {
                const sig = self.function_signatures.items[i];
                try self.popValues(sig.in);
                try self.pushValues(sig.out);
            } else {
                return error.InvalidBytecode;
            },
            .get_local => |i| {
                if (i >= self.total_locals) return error.InvalidBytecode;
                try self.pushValues(1);
            },
            .set_local => |i| {
                if (i >= self.total_locals) return error.InvalidBytecode;
                try self.popValues(1);
            },
            .get_global => |i| {
                if (i >= self.globals) return error.InvalidBytecode;
                try self.pushValues(1);
            },
            .set_global => |i| {
                if (i >= self.globals) return error.InvalidBytecode;
                try self.popValues(1);
            },
            else => unreachable,
        }
    }

    fn markUnreachable(self: *Validator) !void {
        const frame = try self.peekFrame();
        frame.@"unreachable" = true;
        self.stack_size = frame.stack_size;
    }

    fn pushFrame(self: *Validator, kind: Frame.Kind, sig: parse.Sig) !void {
        try self.control_frames.append(self.gpa, .{
            .kind = kind,
            .sig = sig,
            .stack_size = self.stack_size,
            .@"unreachable" = false,
        });
        try self.pushValues(sig.in);
    }

    fn popFrame(self: *Validator) !Frame {
        const frame = try self.peekFrame();
        try self.popValues(frame.sig.out);
        if (self.stack_size != frame.stack_size)
            return error.InvalidBytecode;
        return self.control_frames.pop().?;
    }

    fn peekFrame(self: *Validator) !*Frame {
        return self.frameForLabel(0);
    }

    fn frameForLabel(self: *Validator, l: u32) !*Frame {
        if (l < self.control_frames.items.len) {
            return &self.control_frames.items[self.control_frames.items.len - @as(usize, @intCast(l)) - 1];
        } else {
            return error.InvalidBytecode;
        }
    }

    fn pushValues(self: *Validator, n: u32) !void {
        self.stack_size += n;
        if (self.stack_size > self.max_stack_size)
            self.max_stack_size = self.stack_size;
    }

    fn popValues(self: *Validator, n: u32) !void {
        const frame = try self.peekFrame();
        if (frame.@"unreachable") {
            self.stack_size -= @min(n, self.stack_size - frame.stack_size);
            return;
        }
        if (n > self.stack_size or self.stack_size - n < frame.stack_size) {
            return error.InvalidBytecode;
        }
        self.stack_size -= n;
    }
};

const Test = struct {
    functions: []const parse.Sig = &.{},
    globals: u32 = 0,
    in: u32 = 0,
    out: u32 = 0,
    locals: u32 = 0,
    instrs: []const parse.Instr,
};

fn invalidInstructionIndex(t: Test) !?usize {
    var validator = Validator.init(std.testing.allocator);
    defer validator.deinit();
    try validator.declareFunctionCount(@intCast(t.functions.len));
    for (t.functions) |f| {
        validator.declareFunction(.{ .name = "", .in = f.in, .out = f.out });
    }
    validator.declareGlobalCount(t.globals);
    try validator.enterFunctionBody(t.in + t.locals, t.out);
    for (t.instrs, 0..) |instr, i| {
        validator.validateInstr(instr) catch |err| switch (err) {
            error.InvalidBytecode => return i,
            else => return err,
        };
    }
    validator.exitFunctionBody() catch |err| switch (err) {
        error.InvalidBytecode => return t.instrs.len,
    };
    return null;
}

fn expectValid(t: Test) !void {
    const index = try invalidInstructionIndex(t);
    try std.testing.expectEqual(null, index);
}

fn expectInvalid(invalid_index: usize, t: Test) !void {
    const index = try invalidInstructionIndex(t);
    try std.testing.expectEqual(invalid_index, index);
}

test "validate: simple" {
    try expectValid(.{ .instrs = &.{.end} });
    try expectValid(.{ .instrs = &.{ .{ .@"const" = 1 }, .{ .@"const" = 2 }, .add, .drop, .end } });
    try expectValid(.{ .instrs = &.{ .row, .col, .add, .self, .mul, .drop, .end } });
    try expectValid(.{ .out = 1, .instrs = &.{ .time, .end } });
    try expectValid(.{ .out = 2, .instrs = &.{ .north, .south, .end } });
    try expectValid(.{ .out = 1, .instrs = &.{ .age, .eqz, .end } });
    try expectValid(.{ .out = 1, .instrs = &.{ .row, .{ .br = 0 }, .end } });

    try expectInvalid(0, .{ .instrs = &.{} });
    try expectInvalid(1, .{ .instrs = &.{.{ .@"const" = 1 }} });
    try expectInvalid(1, .{ .instrs = &.{ .{ .@"const" = 1 }, .end } });
    try expectInvalid(1, .{ .instrs = &.{ .end, .add } });
    try expectInvalid(1, .{ .instrs = &.{ .end, .end } });
    try expectInvalid(0, .{ .instrs = &.{ .sub, .end } });
    try expectInvalid(0, .{ .instrs = &.{ .drop, .end } });
    try expectInvalid(1, .{ .instrs = &.{ .northeast, .mul, .end } });
    try expectInvalid(0, .{ .out = 1, .instrs = &.{.end} });
    try expectInvalid(1, .{ .out = 2, .instrs = &.{ .southeast, .end } });
    try expectInvalid(2, .{ .out = 1, .instrs = &.{ .southwest, .northwest, .end } });
    try expectInvalid(2, .{ .instrs = &.{ .west, .drop } });
    try expectInvalid(1, .{ .out = 2, .instrs = &.{ .row, .{ .br = 0 }, .end } });
}

test "validate: block" {
    try expectValid(.{
        .instrs = &.{ .{ .block = .{ .in = 0, .out = 0 } }, .end, .end },
    });
    try expectValid(.{ .out = 1, .instrs = &.{
        .{ .block = .{ .in = 0, .out = 1 } }, .{ .@"const" = 1 }, .end, .end,
    } });
    try expectValid(.{ .instrs = &.{
        .{ .@"const" = 1 },
        .{ .@"const" = 2 },
        .{ .block = .{ .in = 2, .out = 1 } },
        .add,
        .end,
        .drop,
        .end,
    } });
    try expectValid(.{ .out = 1, .instrs = &.{
        .{ .block = .{ .in = 0, .out = 1 } },
        .{ .block = .{ .in = 0, .out = 1 } },
        .{ .@"const" = 1 },
        .end,
        .end,
        .end,
    } });
    try expectValid(.{ .out = 1, .instrs = &.{
        .{ .block = .{ .in = 0, .out = 1 } },
        .{ .@"const" = 1 },
        .{ .br = 0 },
        .add,
        .end,
        .end,
    } });
    try expectValid(.{ .out = 99, .instrs = &.{
        .{ .block = .{ .in = 0, .out = 99 } }, .@"unreachable", .end, .end,
    } });
    try expectValid(.{ .instrs = &.{
        .{ .block = .{ .in = 0, .out = 0 } }, .@"unreachable", .select, .add, .drop, .end, .end,
    } });

    try expectInvalid(2, .{ .instrs = &.{
        .{ .block = .{ .in = 0, .out = 0 } }, .{ .@"const" = 1 }, .end, .end,
    } });
    try expectInvalid(0, .{ .instrs = &.{
        .{ .block = .{ .in = 1, .out = 0 } }, .drop, .end, .end,
    } });
    try expectInvalid(1, .{ .out = 1, .instrs = &.{
        .{ .block = .{ .in = 0, .out = 1 } }, .end, .drop, .end,
    } });
    try expectInvalid(1, .{ .instrs = &.{
        .{ .block = .{ .in = 0, .out = 0 } }, .{ .br = 5 }, .end, .end,
    } });
    try expectInvalid(2, .{ .instrs = &.{
        .{ .block = .{ .in = 0, .out = 0 } }, .end,
    } });
    try expectInvalid(3, .{ .instrs = &.{
        .{ .block = .{ .in = 0, .out = 0 } }, .@"unreachable", .end, .add, .end,
    } });
    try expectInvalid(3, .{ .instrs = &.{
        .{ .block = .{ .in = 0, .out = 0 } }, .@"unreachable", .{ .@"const" = 1 }, .end, .end,
    } });
}

test "validate: loop" {
    try expectValid(.{ .instrs = &.{
        .{ .loop = .{ .in = 0, .out = 0 } }, .end, .end,
    } });
    try expectValid(.{ .out = 1, .instrs = &.{
        .{ .loop = .{ .in = 0, .out = 1 } }, .{ .@"const" = 1 }, .end, .end,
    } });
    try expectValid(.{ .out = 1, .instrs = &.{
        .{ .@"const" = 1 },
        .{ .loop = .{ .in = 1, .out = 1 } },
        .end,
        .end,
    } });
    try expectValid(.{ .out = 1, .instrs = &.{
        .{ .loop = .{ .in = 0, .out = 1 } },
        .{ .loop = .{ .in = 0, .out = 1 } },
        .self,
        .end,
        .end,
        .end,
    } });
    try expectValid(.{ .instrs = &.{
        .{ .loop = .{ .in = 0, .out = 0 } }, .{ .br = 0 }, .end, .end,
    } });
    try expectValid(.{ .instrs = &.{
        .{ .@"const" = 1 },
        .{ .loop = .{ .in = 1, .out = 0 } },
        .{ .br = 0 },
        .end,
        .end,
    } });
    try expectValid(.{ .instrs = &.{
        .time,
        .{ .loop = .{ .in = 1, .out = 0 } },
        .age,
        .{ .loop = .{ .in = 2, .out = 0 } },
        .{ .br_if = 1 },
        .drop,
        .end,
        .end,
        .end,
    } });
    try expectValid(.{ .out = 1, .instrs = &.{
        .{ .loop = .{ .in = 0, .out = 1 } }, .@"unreachable", .end, .end,
    } });
    try expectValid(.{ .instrs = &.{
        .{ .@"const" = 1 },
        .{ .loop = .{ .in = 1, .out = 0 } },
        .{ .br = 0 },
        .add,
        .drop,
        .end,
        .end,
    } });

    try expectInvalid(2, .{ .instrs = &.{
        .{ .loop = .{ .in = 0, .out = 0 } }, .{ .@"const" = 1 }, .end, .end,
    } });
    try expectInvalid(0, .{ .instrs = &.{
        .{ .loop = .{ .in = 2, .out = 0 } }, .end, .end,
    } });
    try expectInvalid(3, .{ .instrs = &.{
        .{ .@"const" = 1 },
        .{ .loop = .{ .in = 1, .out = 0 } },
        .drop,
        .{ .br = 0 },
        .end,
        .end,
    } });
    try expectInvalid(2, .{ .instrs = &.{ .{ .loop = .{ .in = 0, .out = 0 } }, .end } });
}

test "validate: if" {
    try expectValid(.{ .instrs = &.{
        .age, .{ .@"if" = .{ .in = 0, .out = 0 } }, .end, .end,
    } });
    try expectValid(.{ .out = 1, .instrs = &.{
        .{ .@"const" = 7 },
        .{ .@"const" = 1 },
        .{ .@"if" = .{ .in = 1, .out = 1 } },
        .end,
        .end,
    } });
    try expectValid(.{ .out = 1, .instrs = &.{
        .{ .@"const" = 1 },
        .{ .@"if" = .{ .in = 0, .out = 1 } },
        .{ .@"const" = 10 },
        .@"else",
        .{ .@"const" = 20 },
        .end,
        .end,
    } });
    try expectValid(.{ .out = 1, .instrs = &.{
        .{ .@"const" = 7 },
        .{ .@"const" = 1 },
        .{ .@"if" = .{ .in = 1, .out = 1 } },
        .eqz,
        .@"else",
        .clz,
        .end,
        .end,
    } });
    try expectValid(.{ .instrs = &.{
        .{ .@"const" = 1 },
        .{ .@"if" = .{ .in = 0, .out = 0 } },
        .{ .@"const" = 1 },
        .{ .@"if" = .{ .in = 0, .out = 0 } },
        .end,
        .end,
        .end,
    } });
    try expectValid(.{ .instrs = &.{
        .{ .@"const" = 1 },
        .{ .@"if" = .{ .in = 0, .out = 0 } },
        .{ .@"const" = 2 },
        .{ .@"const" = 3 },
        .{ .@"if" = .{ .in = 1, .out = 1 } },
        .{ .br_if = 1 },
        .self,
        .end,
        .drop,
        .end,
        .end,
    } });
    try expectValid(.{ .out = 1, .instrs = &.{
        .{ .@"const" = 1 },
        .{ .@"if" = .{ .in = 0, .out = 1 } },
        .@"unreachable",
        .@"else",
        .{ .@"const" = 20 },
        .end,
        .end,
    } });
    try expectValid(.{ .out = 1, .instrs = &.{
        .{ .@"const" = 1 },
        .{ .@"if" = .{ .in = 0, .out = 1 } },
        .{ .@"const" = 10 },
        .@"else",
        .@"unreachable",
        .end,
        .end,
    } });

    try expectInvalid(3, .{ .out = 1, .instrs = &.{
        .{ .@"const" = 1 }, .{ .@"if" = .{ .in = 0, .out = 1 } }, .{ .@"const" = 10 }, .end,
        .end,
    } });
    try expectInvalid(0, .{ .instrs = &.{
        .{ .@"if" = .{ .in = 0, .out = 0 } }, .end, .end,
    } });
    try expectInvalid(0, .{ .instrs = &.{
        .@"else", .end,
    } });
    try expectInvalid(2, .{ .out = 1, .instrs = &.{
        .{ .@"const" = 1 }, .{ .@"if" = .{ .in = 0, .out = 1 } }, .@"else", .{ .@"const" = 10 }, .end,
        .end,
    } });
    try expectInvalid(3, .{ .instrs = &.{
        .{ .@"const" = 1 }, .{ .@"if" = .{ .in = 0, .out = 0 } }, .end,
    } });
}

test "validate: call" {
    const sigs = [_]parse.Sig{
        .{ .in = 0, .out = 0 },
        .{ .in = 2, .out = 1 },
        .{ .in = 1, .out = 2 },
    };

    try expectValid(.{ .functions = &sigs, .instrs = &.{
        .{ .call = 0 }, .end,
    } });
    try expectValid(.{ .functions = &sigs, .instrs = &.{
        .{ .@"const" = 1 }, .{ .@"const" = 2 }, .{ .call = 1 }, .drop, .end,
    } });
    try expectValid(.{ .functions = &sigs, .out = 2, .instrs = &.{
        .{ .@"const" = 1 }, .{ .call = 2 }, .end,
    } });

    try expectInvalid(1, .{ .functions = &sigs, .instrs = &.{
        .{ .@"const" = 1 }, .{ .call = 1 }, .drop, .end,
    } });
    try expectInvalid(2, .{ .functions = &sigs, .instrs = &.{
        .{ .@"const" = 1 }, .{ .call = 2 }, .end,
    } });
    try expectInvalid(0, .{ .instrs = &.{
        .{ .call = 0 }, .end,
    } });
    try expectInvalid(0, .{ .functions = &sigs, .instrs = &.{
        .{ .call = 3 }, .end,
    } });
}

test "validate: unreachable" {
    try expectValid(.{ .instrs = &.{ .@"unreachable", .end } });
    try expectValid(.{ .out = 2, .instrs = &.{ .@"unreachable", .end } });
    try expectValid(.{ .instrs = &.{ .@"unreachable", .add, .drop, .end } });
    try expectInvalid(2, .{ .instrs = &.{ .@"unreachable", .{ .@"const" = 1 }, .end } });

    try expectValid(.{ .instrs = &.{ .@"return", .end } });
    try expectValid(.{ .out = 1, .instrs = &.{ .{ .@"const" = 1 }, .@"return", .end } });
    try expectValid(.{ .out = 2, .instrs = &.{ .{ .@"const" = 1 }, .north, .@"return", .end } });
    try expectValid(.{ .out = 1, .instrs = &.{ .{ .@"const" = 1 }, .{ .@"const" = 2 }, .@"return", .add, .end } });
    try expectInvalid(1, .{ .out = 2, .instrs = &.{ .{ .@"const" = 1 }, .@"return", .end } });
    try expectInvalid(0, .{ .out = 1, .instrs = &.{ .@"return", .end } });

    try expectValid(.{ .instrs = &.{ .{ .br = 0 }, .end } });
    try expectValid(.{ .out = 1, .instrs = &.{ .{ .@"const" = 1 }, .{ .br = 0 }, .end } });
    try expectInvalid(0, .{ .out = 1, .instrs = &.{ .{ .br = 0 }, .end } });
    try expectInvalid(0, .{ .instrs = &.{ .{ .br = 1 }, .end } });

    try expectValid(.{ .instrs = &.{ .{ .@"const" = 1 }, .{ .br_if = 0 }, .end } });
    try expectValid(.{ .out = 1, .instrs = &.{ .{ .@"const" = 1 }, .{ .@"const" = 2 }, .{ .br_if = 0 }, .end } });
    try expectInvalid(2, .{ .instrs = &.{ .{ .@"const" = 1 }, .{ .br_if = 0 }, .add, .end } });
    try expectInvalid(0, .{ .instrs = &.{ .{ .br_if = 0 }, .end } });
    try expectInvalid(1, .{ .instrs = &.{ .{ .@"const" = 1 }, .{ .br_if = 1 }, .end } });
}

test "validate: locals" {
    try expectValid(.{ .locals = 1, .instrs = &.{ .{ .get_local = 0 }, .drop, .end } });
    try expectValid(.{ .locals = 1, .instrs = &.{ .{ .@"const" = 1 }, .{ .set_local = 0 }, .end } });
    try expectValid(.{ .out = 1, .locals = 1, .instrs = &.{ .{ .get_local = 0 }, .end } });
    try expectValid(.{ .locals = 1, .instrs = &.{ .{ .@"const" = 1 }, .{ .@"const" = 2 }, .{ .set_local = 0 }, .drop, .end } });
    try expectValid(.{ .locals = 1, .instrs = &.{ .{ .get_local = 0 }, .{ .set_local = 0 }, .end } });
    try expectValid(.{ .in = 2, .instrs = &.{ .{ .get_local = 0 }, .{ .get_local = 1 }, .drop, .drop, .end } });
    try expectValid(.{ .in = 2, .locals = 1, .instrs = &.{ .{ .get_local = 2 }, .drop, .end } });

    try expectInvalid(0, .{ .instrs = &.{ .{ .get_local = 0 }, .end } });
    try expectInvalid(0, .{ .in = 2, .instrs = &.{ .{ .get_local = 2 }, .end } });
    try expectInvalid(0, .{ .locals = 1, .instrs = &.{ .{ .get_local = 1 }, .end } });
    try expectInvalid(1, .{ .locals = 1, .instrs = &.{ .{ .@"const" = 1 }, .{ .set_local = 5 }, .end } });
    try expectInvalid(0, .{ .locals = 1, .instrs = &.{ .{ .set_local = 0 }, .end } });
    try expectInvalid(1, .{ .locals = 1, .instrs = &.{ .{ .get_local = 0 }, .end } });
}

test "validate: globals" {
    try expectValid(.{ .globals = 1, .instrs = &.{ .{ .get_global = 0 }, .drop, .end } });
    try expectValid(.{ .globals = 1, .instrs = &.{ .{ .@"const" = 1 }, .{ .set_global = 0 }, .end } });
    try expectValid(.{ .out = 1, .globals = 1, .instrs = &.{ .{ .get_global = 0 }, .end } });
    try expectValid(.{ .globals = 1, .instrs = &.{ .{ .@"const" = 1 }, .{ .@"const" = 2 }, .{ .set_global = 0 }, .drop, .end } });
    try expectValid(.{ .globals = 3, .instrs = &.{ .{ .get_global = 2 }, .{ .set_global = 2 }, .end } });

    try expectInvalid(0, .{ .instrs = &.{ .{ .get_global = 0 }, .end } });
    try expectInvalid(0, .{ .globals = 1, .instrs = &.{ .{ .get_global = 1 }, .end } });
    try expectInvalid(1, .{ .globals = 1, .instrs = &.{ .{ .@"const" = 1 }, .{ .set_global = 3 }, .end } });
    try expectInvalid(0, .{ .globals = 1, .instrs = &.{ .{ .set_global = 0 }, .end } });
    try expectInvalid(1, .{ .globals = 1, .instrs = &.{ .{ .get_global = 0 }, .end } });
}

test "validate: nested" {
    try expectValid(.{
        .out = 1,
        .instrs = &.{
            .{ .block = .{ .in = 0, .out = 1 } }, // br target block
            .{ .block = .{ .in = 0, .out = 2 } },
            .{ .@"const" = 7 },
            .{ .br = 1 }, // stack size: 1
            .end,
            .drop,
            .end, // br target
            .end,
        },
    });
    try expectInvalid(3, .{
        .out = 1,
        .instrs = &.{
            .{ .block = .{ .in = 0, .out = 1 } },
            .{ .block = .{ .in = 0, .out = 2 } }, // br target block
            .{ .@"const" = 7 },
            .{ .br = 0 }, // stack size: 1
            .end, // br target
            .drop,
            .end,
            .end,
        },
    });

    try expectValid(.{
        .instrs = &.{
            .{ .block = .{ .in = 0, .out = 0 } },
            .{ .block = .{ .in = 0, .out = 1 } }, // br target block
            .{ .block = .{ .in = 0, .out = 2 } },
            .{ .@"const" = 1 },
            .{ .br = 1 }, // stack size: 1
            .end,
            .drop,
            .end, // br target
            .drop,
            .end,
            .end,
        },
    });
    try expectInvalid(4, .{
        .instrs = &.{
            .{ .block = .{ .in = 0, .out = 0 } },
            .{ .block = .{ .in = 0, .out = 1 } },
            .{ .block = .{ .in = 0, .out = 2 } }, // br target block
            .{ .@"const" = 1 },
            .{ .br = 0 }, // stack size: 1
            .end, // br target
            .drop,
            .end,
            .drop,
            .end,
            .end,
        },
    });

    try expectValid(.{
        .instrs = &.{
            .{ .@"const" = 1 },
            .{ .@"const" = 2 }, // stack size: 2
            .{ .loop = .{ .in = 2, .out = 0 } },
            .{ .block = .{ .in = 0, .out = 0 } }, // br_if target block
            .{ .@"const" = 0 },
            .{ .br_if = 0 }, // stack size: 2
            .end, // br_if target
            .drop,
            .drop,
            .end,
            .end,
        },
    });
    try expectInvalid(5, .{
        .instrs = &.{
            .{ .@"const" = 1 },
            .{ .@"const" = 2 }, // stack size: 2
            .{ .loop = .{ .in = 2, .out = 0 } }, // br_if target
            .{ .block = .{ .in = 0, .out = 0 } },
            .{ .@"const" = 0 },
            .{ .br_if = 1 }, // can't pop the 2 loop inputs
            .end,
            .drop,
            .drop,
            .end,
            .end,
        },
    });

    try expectInvalid(3, .{ .instrs = &.{
        .{ .@"const" = 5 },
        .{ .loop = .{ .in = 1, .out = 0 } },
        .{ .block = .{ .in = 0, .out = 0 } },
        .{ .br = 1 },
        .end,
        .end,
        .end,
    } });
    try expectValid(.{
        .instrs = &.{
            .{ .@"const" = 5 },
            .{ .loop = .{ .in = 1, .out = 0 } },
            .{ .block = .{ .in = 1, .out = 1 } },
            .{ .br = 1 },
            .end,
            .drop,
            .end,
            .end,
        },
    });

    try expectValid(.{
        .out = 1,
        .instrs = &.{
            .{ .@"const" = 1 },
            .{ .@"if" = .{ .in = 0, .out = 1 } },
            .{ .block = .{ .in = 0, .out = 2 } },
            .{ .@"const" = 4 },
            .{ .br = 1 },
            .end,
            .drop,
            .@"else",
            .{ .@"const" = 5 },
            .end,
            .end,
        },
    });

    try expectValid(.{
        .out = 2,
        .instrs = &.{
            .{ .block = .{ .in = 0, .out = 2 } },
            .{ .@"const" = 1 },
            .{ .@"if" = .{ .in = 0, .out = 1 } },
            .{ .@"const" = 8 },
            .{ .@"const" = 9 },
            .{ .br = 1 },
            .@"else",
            .{ .@"const" = 7 },
            .end,
            .{ .@"const" = 6 },
            .end,
            .end,
        },
    });

    try expectValid(.{
        .out = 1,
        .instrs = &.{
            .{ .@"const" = 1 },
            .{ .@"if" = .{ .in = 0, .out = 1 } },
            .{ .@"const" = 2 },
            .{ .block = .{ .in = 1, .out = 2 } },
            .{ .@"const" = 0 },
            .{ .br_if = 1 },
            .{ .@"const" = 3 },
            .end,
            .drop,
            .@"else",
            .{ .loop = .{ .in = 0, .out = 1 } },
            .{ .@"const" = 4 },
            .end,
            .end,
            .end,
        },
    });
    try expectInvalid(5, .{
        .out = 1,
        .instrs = &.{
            .{ .@"const" = 1 },
            .{ .@"if" = .{ .in = 0, .out = 1 } },
            .{ .@"const" = 2 },
            .{ .block = .{ .in = 0, .out = 1 } },
            .{ .@"const" = 0 },
            .{ .br_if = 1 },
            .{ .@"const" = 3 },
            .end,
            .drop,
            .@"else",
            .{ .loop = .{ .in = 0, .out = 1 } },
            .{ .@"const" = 4 },
            .end,
            .end,
            .end,
        },
    });

    try expectInvalid(4, .{ .instrs = &.{
        .{ .block = .{ .in = 0, .out = 0 } },
        .{ .block = .{ .in = 0, .out = 1 } },
        .@"unreachable",
        .end,
        .end,
        .end,
    } });
}

test "validate: coverage" {
    const instrs = [_]parse.Instr{
        .nop, // 0 -> 0

        .self, // 0 -> 1
        .east, .add, // 1 -> 1
        .north, .sub, // 1 -> 1
        .south, .mul, // 1 -> 1
        .west, .div_s, // 1 -> 1
        .northeast, .div_u, // 1 -> 1
        .northwest, .rem_s, // 1 -> 1
        .southeast, .rem_u, // 1 -> 1
        .southwest, .@"and", // 1 -> 1
        .time, .@"or", // 1 -> 1
        .age, .xor, // 1 -> 1
        .row, .shl, // 1 -> 1
        .col, .shr_s, // 1 -> 1
        .{ .@"const" = 5 }, .shr_u, // 1 -> 1
        .{ .@"const" = 1 }, .rotl, // 1 -> 1
        .{ .@"const" = 2 }, .rotr, // 1 -> 1

        .clz, // 1 -> 1
        .ctz, // 1 -> 1
        .popcnt, // 1 -> 1
        .eqz, // 1 -> 1

        .{ .get_local = 0 }, .eq, // 1 -> 1
        .{ .get_global = 0 }, .ne, // 1 -> 1
        .{ .@"const" = 3 }, .lt_s, // 1 -> 1
        .{ .@"const" = 4 }, .lt_u, // 1 -> 1
        .{ .@"const" = 5 }, .gt_s, // 1 -> 1
        .{ .@"const" = 6 }, .gt_u, // 1 -> 1
        .{ .@"const" = 7 }, .le_s, // 1 -> 1
        .{ .@"const" = 8 }, .le_u, // 1 -> 1
        .{ .@"const" = 9 }, .ge_s, // 1 -> 1
        .{ .@"const" = 10 }, .ge_u, // 1 -> 1

        .load, // 1 -> 1
        .load8_s, // 1 -> 1
        .load8_u, // 1 -> 1
        .load16_s, // 1 -> 1
        .load16_u, // 1 -> 1
        .read, // 1 -> 1
        .read8_s, // 1 -> 1
        .read8_u, // 1 -> 1
        .read16_s, // 1 -> 1
        .read16_u, // 1 -> 1

        .{ .@"const" = 100 }, .store, // 1 -> 0
        .{ .@"const" = 1 }, .{ .@"const" = 2 }, .store8, // 0 -> 0
        .{ .@"const" = 1 }, .{ .@"const" = 2 }, .store16, // 0 -> 0

        .row, .col, .time, .copy, // 0 -> 0
        .col, .row, .age, .move, // 0 -> 0

        .east, .west, .{ .@"const" = 0 }, .select, // 0 -> 1

        .{ .set_local = 0 }, // 1 -> 0
        .{ .get_global = 0 }, // 0 -> 1
        .{ .set_global = 0 }, // 1 -> 0
        .{ .get_local = 0 }, // 0 -> 1
        .drop, // 1 -> 0

        .{ .@"const" = 7 }, // 0 -> 1
        .{ .call = 0 }, // 1 -> 1
        .drop, // 1 -> 0

        // 0 -> 0
        .{ .block = .{ .in = 0, .out = 0 } },
        .{ .@"const" = 0 },
        .{ .br_if = 0 },
        .{ .br = 0 },
        .end,

        // 0 -> 0
        .{ .loop = .{ .in = 0, .out = 0 } },
        .{ .@"const" = 0 },
        .{ .br_if = 0 },
        .end,

        // 0 -> 1
        .{ .@"const" = 1 },
        .{ .@"if" = .{ .in = 0, .out = 1 } },
        .{ .@"const" = 2 },
        .@"else",
        .@"unreachable",
        .end,

        .@"return",
        .end,
    };
    try expectValid(.{
        .functions = &.{.{ .in = 1, .out = 1 }},
        .globals = 1,
        .in = 0,
        .out = 1,
        .locals = 1,
        .instrs = &instrs,
    });
}
