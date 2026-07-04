const std = @import("std");

// magic ::= 0x67 0x76 0x6d 0x00
// version ::= 0x01 0x00 0x00 0x00
//
// function_decl ::=
//     leb128(name_length) name
//     leb128(params) leb128(returns)
//
// function_section ::=
//     0x03 leb128(length)
//     leb128(function_count)
//     function_decl*
//
// memory_section ::=
//     0x05 leb128(length)
//     leb128(memory_size)
//
// global_delc ::= leb128(name_length) name leb128(init)
//
// global_section ::=
//     0x06 leb128(length)
//     leb128(global_count)
//     global_decl*
//
// start_section ::=
//     0x08 leb128(length)
//     leb128(func_id)
//
// block_type ::= leb128(in) leb128(out)
//
// instr ::=
//     0x02 blocktype instr* 0x0b               => block
//     0x03 blocktype instr* 0x0b               => loop
//     0x04 blocktype instr* 0x0b               => if
//     0x04 blocktype instr* 0x05 instr* 0x0b   => if else
//     0x0c leb128(label)                       => br
//     0x0d leb128(label)                       => br_if
//     0x0f                                     => return
//     0x10 leb128(func_id)                     => call
//     0x20 leb128(local_id)                    => get_local
//     0x21 leb128(local_id)                    => set_local
//     0x23 leb128(global_id)                   => get_global
//     0x24 leb128(global_id)                   => set_global
//     0x28                                     => load
//     0x29                                     => load8_s
//     0x2a                                     => load8_u
//     0x2b                                     => load16_s
//     0x2c                                     => load16_u
//     0x2d                                     => store
//     0x2e                                     => store8
//     0x2f                                     => store16
//     0x30                                     => read
//     0x31                                     => read8_s
//     0x32                                     => read8_u
//     0x33                                     => read16_s
//     0x34                                     => read16_u
//     0x35                                     => copy
//     0x36                                     => move
//     0x41 leb128(value)                       => const
//     0x45                                     => eqz
//     0x46                                     => eq
//     0x47                                     => ne
//     0x48                                     => lt_s
//     0x49                                     => lt_u
//     0x4a                                     => gt_s
//     0x4b                                     => gt_u
//     0x4c                                     => le_s
//     0x4d                                     => le_u
//     0x4e                                     => ge_s
//     0x4f                                     => ge_u
//     0x67                                     => clz
//     0x68                                     => ctz
//     0x69                                     => popcnt
//     0x6a                                     => add
//     0x6b                                     => sub
//     0x6c                                     => mul
//     0x6d                                     => div_s
//     0x6e                                     => div_u
//     0x6f                                     => rem_s
//     0x70                                     => rem_u
//     0x71                                     => and
//     0x72                                     => or
//     0x73                                     => xor
//     0x74                                     => shl
//     0x75                                     => shr_s
//     0x76                                     => shr_u
//     0x77                                     => rotl
//     0x78                                     => rotr
//     0x8b                                     => self
//     0x8c                                     => east
//     0x8d                                     => northeast
//     0x8e                                     => north
//     0x8f                                     => northwest
//     0x90                                     => west
//     0x91                                     => southwest
//     0x92                                     => south
//     0x93                                     => southeast
//     0x94                                     => time
//     0x95                                     => age
//     0x96                                     => row
//     0x97                                     => col
//
// function_def ::=
//     leb128(length) leb128(locals)
//     instr*
//     0x0b
//
// code_section ::=
//     0x0a leb128(length)
//     leb128(function_count)
//     function_def*
//
// data_section ::=
//     0x0b leb128(length)
//     data
//
// module ::=
//     magic version
//     function_section
//     memory_section?
//     global_section?
//     start_section
//     code_section
//     data_section?

const magic = [4]u8{ 'g', 'v', 'm', 0 };
const version = [4]u8{ 1, 0, 0, 0 };

pub const SectionTag = enum(u8) {
    function = 0x03,
    memory = 0x05,
    global = 0x06,
    start = 0x08,
    code = 0x0a,
    data = 0x0b,

    pub fn allowedAfter(self: SectionTag, prev: ?SectionTag) bool {
        return switch (self) {
            .function => prev == null,
            .memory => prev == .function,
            .global => prev == .function or prev == .memory,
            .start => prev == .function or prev == .memory or prev == .global,
            .code => prev == .start,
            .data => prev == .code,
        };
    }
};

pub const BlockType = struct { in: u32, out: u32 };

pub const OpTag = enum(u8) {
    @"unreachable" = 0x00,
    nop = 0x01,
    block = 0x02,
    loop = 0x03,
    @"if" = 0x04,
    @"else" = 0x05,

    end = 0x0b,
    br = 0x0c,
    br_if = 0x0d,

    @"return" = 0x0f,

    call = 0x10,

    drop = 0x1a,
    select = 0x1b,

    get_local = 0x20,
    set_local = 0x21,

    get_global = 0x23,
    set_global = 0x24,

    load = 0x28,
    load8_s = 0x29,
    load8_u = 0x2a,
    load16_s = 0x2b,
    load16_u = 0x2c,
    store = 0x2d,
    store8 = 0x2e,
    store16 = 0x2f,
    read = 0x30,
    read8_s = 0x31,
    read8_u = 0x32,
    read16_s = 0x33,
    read16_u = 0x34,
    copy = 0x35,
    move = 0x36,

    @"const" = 0x41,

    eqz = 0x45,
    eq = 0x46,
    ne = 0x47,
    lt_s = 0x48,
    lt_u = 0x49,
    gt_s = 0x4a,
    gt_u = 0x4b,
    le_s = 0x4c,
    le_u = 0x4d,
    ge_s = 0x4e,
    ge_u = 0x4f,

    clz = 0x67,
    ctz = 0x68,
    popcnt = 0x69,

    add = 0x6a,
    sub = 0x6b,
    mul = 0x6c,
    div_s = 0x6d,
    div_u = 0x6e,
    rem_s = 0x6f,
    rem_u = 0x70,
    @"and" = 0x71,
    @"or" = 0x72,
    xor = 0x73,
    shl = 0x74,
    shr_s = 0x75,
    shr_u = 0x76,
    rotl = 0x77,
    rotr = 0x78,

    self = 0x8b,
    east = 0x8c,
    northeast = 0x8d,
    north = 0x8e,
    northwest = 0x8f,
    west = 0x90,
    southwest = 0x91,
    south = 0x92,
    southeast = 0x93,
    time = 0x94,
    age = 0x95,
    row = 0x96,
    col = 0x97,

    pub fn Payload(comptime self: OpTag) type {
        return switch (self) {
            .block, .loop, .@"if", .@"else" => BlockType,
            .br,
            .br_if,
            .call,
            .get_local,
            .set_local,
            .get_global,
            .set_global,
            .@"const",
            => u32,
            else => void,
        };
    }
};

pub const Op = blk: {
    const names = std.meta.fieldNames(OpTag);
    var types = [_]type{undefined} ** names.len;
    const attrs = [_]std.builtin.Type.UnionField.Attributes{.{}} ** names.len;
    for (names, 0..) |name, i| {
        types[i] = @field(OpTag, name).Payload();
    }
    break :blk @Union(.auto, OpTag, names, &types, &attrs);
};

pub const Section = union(SectionTag) {
    function: struct {
        function_count: u32,
        reader: FunctionReader,
    },
    memory: struct { memory_size: u32 },
    global: struct {
        global_count: u32,
        reader: GlobalReader,
    },
    start: struct { function_id: u32 },
    code: struct {
        function_count: u32,
        reader: CodeReader,
    },
    data: struct { data: []const u8 },
};

pub const FunctionDecl = struct {
    name: []const u8,
    in: u32,
    out: u32,
};

pub const GlobalDecl = struct {
    name: []const u8,
    init: u32,
};

pub const FunctionDef = struct {
    locals: u32,
    reader: OpReader,
};

fn remaining(reader: std.Io.Reader) usize {
    return reader.buffer.len - reader.seek;
}

fn empty(reader: std.Io.Reader) bool {
    return remaining(reader) == 0;
}

fn parseIntSection(bytes: []const u8) !u32 {
    var reader = std.Io.Reader.fixed(bytes);
    const value = try reader.takeLeb128(u32);
    if (!empty(reader)) return error.InvalidBytecode;
    return value;
}

// TODO: Wrap std.Io.Reader with a custom Reader type that
// 1. produces better errors
// 2. keeps track of the offset within the byecode file
// 3. has a slice function that returns another Reader

pub const ModuleReader = struct {
    reader: std.Io.Reader,
    prev_section: ?SectionTag = null,
    function_count: ?u32 = null,

    pub fn init(bytes: []const u8) !ModuleReader {
        const expected = magic ++ version;

        var reader = std.Io.Reader.fixed(bytes);
        const header = try reader.take(expected.len);
        if (!std.mem.eql(u8, header, &expected))
            return error.InvalidBytecode;
        return .{ .reader = reader };
    }

    pub fn next(self: *ModuleReader) !?Section {
        const section = try self.nextSection() orelse return null;
        if (!section.section.allowedAfter(self.prev_section))
            return error.InvalidBytecode;
        self.prev_section = section.section;
        switch (section.section) {
            .function => {
                const reader = try FunctionReader.init(section.bytes);
                self.function_count = reader.remaining;
                return .{ .function = .{ .reader = reader, .function_count = reader.remaining } };
            },
            .memory => {
                const size = try parseIntSection(section.bytes);
                return .{ .memory = .{ .memory_size = size } };
            },
            .global => {
                const reader = try GlobalReader.init(section.bytes);
                return .{ .global = .{ .reader = reader, .global_count = reader.remaining } };
            },
            .start => {
                const id = try parseIntSection(section.bytes);
                return .{ .start = .{ .function_id = id } };
            },
            .code => {
                const reader = try CodeReader.init(section.bytes);
                if (reader.remaining != self.function_count.?)
                    return error.InvalidBytecode;
                return .{ .code = .{ .reader = reader, .function_count = reader.remaining } };
            },
            .data => return .{ .data = .{ .data = section.bytes } },
        }
    }

    const SectionBytes = struct {
        section: SectionTag,
        bytes: []const u8,
    };

    fn nextSection(self: *ModuleReader) !?SectionBytes {
        if (empty(self.reader)) return null;
        const section = try self.reader.takeEnum(SectionTag, .little);
        const length = try self.reader.takeLeb128(u32);
        const bytes = try self.reader.take(@intCast(length));
        return .{ .section = section, .bytes = bytes };
    }
};

// TODO: Share code with GlobalReader?
pub const FunctionReader = struct {
    reader: std.Io.Reader,
    remaining: u32,

    fn init(bytes: []const u8) !FunctionReader {
        var reader = std.Io.Reader.fixed(bytes);
        const function_count = try reader.takeLeb128(u32);
        if (function_count == 0) return error.InvalidBytecode;
        return .{ .reader = reader, .remaining = function_count };
    }

    pub fn next(self: *FunctionReader) !?FunctionDecl {
        if (empty(self.reader) != (self.remaining == 0))
            return error.InvalidBytecode;
        if (self.remaining == 0) return null;
        const name_length = try self.reader.takeLeb128(u32);
        const name = try self.reader.take(@intCast(name_length));
        const in = try self.reader.takeLeb128(u32);
        const out = try self.reader.takeLeb128(u32);
        self.remaining -= 1;
        return .{ .name = name, .in = in, .out = out };
    }
};

pub const GlobalReader = struct {
    reader: std.Io.Reader,
    remaining: u32,

    fn init(bytes: []const u8) !GlobalReader {
        var reader = std.Io.Reader.fixed(bytes);
        const global_count = try reader.takeLeb128(u32);
        return .{ .reader = reader, .remaining = global_count };
    }

    pub fn next(self: *GlobalReader) !?GlobalDecl {
        if (empty(self.reader) != (self.remaining == 0))
            return error.InvalidBytecode;
        if (self.remaining == 0) return null;
        const name_length = try self.reader.takeLeb128(u32);
        const name = try self.reader.take(@intCast(name_length));
        const initializer = try self.reader.takeLeb128(u32);
        self.remaining -= 1;
        return .{ .name = name, .init = initializer };
    }
};

pub const CodeReader = struct {
    reader: std.Io.Reader,
    remaining: u32,

    fn init(bytes: []const u8) !CodeReader {
        var reader = std.Io.Reader.fixed(bytes);
        const function_count = try reader.takeLeb128(u32);
        return .{ .reader = reader, .remaining = function_count };
    }

    pub fn next(self: *CodeReader) !?FunctionDef {
        if (empty(self.reader) != (self.remaining == 0))
            return error.InvalidBytecode;
        if (self.remaining == 0) return null;
        const length = try self.reader.takeLeb128(u32);
        const bytes = try self.reader.take(@intCast(length));
        const reader = try OpReader.init(bytes);
        self.remaining -= 1;
        return reader;
    }
};

pub const OpReader = struct {
    reader: std.Io.Reader,
    depth: u32 = 0,

    fn init(bytes: []const u8) !FunctionDef {
        var reader = std.Io.Reader.fixed(bytes);
        const locals = try reader.takeLeb128(u32);
        return .{ .locals = locals, .reader = .{ .reader = reader } };
    }

    pub fn next(self: *OpReader) !?Op {
        if (remaining(self.reader) == 0) {
            return null;
        } else if (remaining(self.reader) == 1) {
            if (try self.reader.takeByte() != @intFromEnum(OpTag.end))
                return error.InvalidBytecode;
            if (self.depth != 0)
                return error.InvalidBytecode;
            return null;
        }
        const tag = try self.reader.takeEnum(OpTag, .little);
        switch (tag) {
            inline else => |t| {
                const payload = t.Payload();
                if (payload == void) {
                    if (t == .end) {
                        if (self.depth == 0) return error.InvalidBytecode;
                        self.depth -= 1;
                    }
                    return @unionInit(Op, @tagName(t), {});
                } else if (payload == u32) {
                    const value = try self.reader.takeLeb128(u32);
                    return @unionInit(Op, @tagName(t), value);
                } else {
                    const in = try self.reader.takeLeb128(u32);
                    const out = try self.reader.takeLeb128(u32);
                    self.depth += 1;
                    return @unionInit(Op, @tagName(t), .{ .in = in, .out = out });
                }
            },
        }
    }
};
