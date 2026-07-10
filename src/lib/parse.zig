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
// global_def ::= leb128(name_length) name leb128(init)
//
// global_section ::=
//     0x06 leb128(length)
//     leb128(global_count)
//     global_def*
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

    pub fn allowedLast(self: ?SectionTag) bool {
        return self == .code or self == .data;
    }
};

pub const Sig = struct { in: u32, out: u32 };

pub const InstrTag = enum(u8) {
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

    pub fn Payload(comptime self: InstrTag) type {
        return switch (self) {
            .block, .loop, .@"if" => Sig,
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

    pub fn signature(self: InstrTag) ?Sig {
        return switch (self) {
            .nop => .{ .in = 0, .out = 0 },
            .@"const",
            .self,
            .east,
            .northeast,
            .north,
            .northwest,
            .west,
            .southwest,
            .south,
            .southeast,
            .time,
            .age,
            .row,
            .col,
            => .{ .in = 0, .out = 1 },
            .drop => .{ .in = 1, .out = 0 },
            .load,
            .load8_s,
            .load8_u,
            .load16_s,
            .load16_u,
            .read,
            .read8_s,
            .read8_u,
            .read16_s,
            .read16_u,
            .eqz,
            .clz,
            .ctz,
            .popcnt,
            => .{ .in = 1, .out = 1 },
            .store, .store8, .store16 => .{ .in = 2, .out = 0 },
            .eq,
            .ne,
            .lt_s,
            .lt_u,
            .gt_s,
            .gt_u,
            .le_s,
            .le_u,
            .ge_s,
            .ge_u,
            .add,
            .sub,
            .mul,
            .div_s,
            .div_u,
            .rem_s,
            .rem_u,
            .@"and",
            .@"or",
            .xor,
            .shl,
            .shr_s,
            .shr_u,
            .rotl,
            .rotr,
            => .{ .in = 2, .out = 1 },
            .copy, .move => .{ .in = 3, .out = 0 },
            .select => .{ .in = 3, .out = 1 },
            .@"unreachable",
            .block,
            .loop,
            .@"if",
            .@"else",
            .end,
            .br,
            .br_if,
            .@"return",
            .call,
            .get_local,
            .set_local,
            .get_global,
            .set_global,
            => null,
        };
    }
};

pub const Instr = blk: {
    const names = std.meta.fieldNames(InstrTag);
    var types = [_]type{undefined} ** names.len;
    const attrs = [_]std.builtin.Type.UnionField.Attributes{.{}} ** names.len;
    for (names, 0..) |name, i| {
        types[i] = @field(InstrTag, name).Payload();
    }
    break :blk @Union(.auto, InstrTag, names, &types, &attrs);
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

pub const GlobalDef = struct {
    name: []const u8,
    init: u32,
};

pub const FunctionDef = struct {
    locals: u32,
    reader: InstrReader,
};

const Reader = struct {
    reader: std.Io.Reader,
    base: usize,
    error_offset: usize = 0,

    fn init(bytes: []const u8, base: usize) Reader {
        const reader = std.Io.Reader.fixed(bytes);
        return .{ .reader = reader, .base = base };
    }

    fn slice(self: *Reader, length: usize) !Reader {
        const base = self.offset();
        self.error_offset = base;
        const bytes = try mapErr(self.reader.take(length));
        return Reader.init(bytes, base);
    }

    fn rest(self: Reader) []const u8 {
        return self.reader.buffer[self.reader.seek..];
    }

    fn remaining(self: Reader) usize {
        return self.rest().len;
    }

    fn empty(self: Reader) bool {
        return self.remaining() == 0;
    }

    fn offset(self: Reader) usize {
        return self.base + self.reader.seek;
    }

    fn MapErr(comptime T: type) type {
        return error{InvalidBytecode}!@typeInfo(T).error_union.payload;
    }

    fn mapErr(value: anytype) MapErr(@TypeOf(value)) {
        // TODO: use multiple, more descriptive errors
        return value catch error.InvalidBytecode;
    }

    fn errorOffset(self: Reader) usize {
        return self.error_offset;
    }

    fn take(self: *Reader, n: usize) ![]const u8 {
        self.error_offset = self.offset();
        return mapErr(self.reader.take(n));
    }

    fn takeUtf8(self: *Reader, n: usize) ![]const u8 {
        const bytes = try self.take(n);
        if (!std.unicode.utf8ValidateSlice(bytes))
            return error.InvalidBytecode;
        return bytes;
    }

    fn takeU32(self: *Reader) !u32 {
        self.error_offset = self.offset();
        return mapErr(self.reader.takeLeb128(u32));
    }

    fn takeEnum(self: *Reader, comptime Enum: type) !Enum {
        comptime std.debug.assert(@sizeOf(Enum) == 1);
        self.error_offset = self.offset();
        return mapErr(self.reader.takeEnum(Enum, .little));
    }

    fn takeU32Section(self: *Reader) !u32 {
        const value = try self.takeU32();
        if (!self.empty()) return error.InvalidBytecode;
        return value;
    }
};

pub const ModuleReader = struct {
    reader: Reader,
    prev_section: ?SectionTag = null,
    function_count: ?u32 = null,

    pub fn errorOffset(self: ModuleReader) usize {
        return self.reader.errorOffset();
    }

    pub fn init(bytes: []const u8) !ModuleReader {
        const expected = magic ++ version;

        var reader = Reader.init(bytes, 0);
        const header = try reader.take(expected.len);
        if (!std.mem.eql(u8, header, &expected))
            return error.InvalidBytecode;
        return .{ .reader = reader };
    }

    pub fn next(self: *ModuleReader) !?Section {
        const sec = try self.nextSection() orelse {
            if (!SectionTag.allowedLast(self.prev_section))
                return error.InvalidBytecode;
            return null;
        };
        if (!sec.section.allowedAfter(self.prev_section))
            return error.InvalidBytecode;
        self.prev_section = sec.section;
        switch (sec.section) {
            .function => {
                const reader = try FunctionReader.init(sec.reader);
                self.function_count = reader.remaining;
                return .{ .function = .{ .reader = reader, .function_count = reader.remaining } };
            },
            .memory => {
                var reader = sec.reader;
                const size = try reader.takeU32Section();
                return .{ .memory = .{ .memory_size = size } };
            },
            .global => {
                const reader = try GlobalReader.init(sec.reader);
                return .{ .global = .{ .reader = reader, .global_count = reader.remaining } };
            },
            .start => {
                var reader = sec.reader;
                const id = try reader.takeU32Section();
                return .{ .start = .{ .function_id = id } };
            },
            .code => {
                const reader = try CodeReader.init(sec.reader);
                if (reader.remaining != self.function_count.?)
                    return error.InvalidBytecode;
                return .{ .code = .{ .reader = reader, .function_count = reader.remaining } };
            },
            .data => return .{ .data = .{ .data = sec.reader.rest() } },
        }
    }

    const SectionReader = struct {
        section: SectionTag,
        reader: Reader,
    };

    fn nextSection(self: *ModuleReader) !?SectionReader {
        if (self.reader.empty()) return null;
        const tag = try self.reader.takeEnum(SectionTag);
        const length = try self.reader.takeU32();
        const reader = try self.reader.slice(length);
        return .{ .section = tag, .reader = reader };
    }
};

fn GenericReader(comptime Item: type) type {
    return struct {
        reader: Reader,
        remaining: u32,

        pub fn errorOffset(self: @This()) usize {
            return self.reader.errorOffset();
        }

        fn init(reader: Reader) !@This() {
            var reader_copy = reader;
            const count = try reader_copy.takeU32();
            return .{ .reader = reader_copy, .remaining = count };
        }

        pub fn next(self: *@This()) !?Item {
            if (self.reader.empty() != (self.remaining == 0))
                return error.InvalidBytecode;
            if (self.remaining == 0) return null;
            const name_length = try self.reader.takeU32();
            const name = try self.reader.takeUtf8(@intCast(name_length));
            self.remaining -= 1;
            if (Item == FunctionDecl) {
                const in = try self.reader.takeU32();
                const out = try self.reader.takeU32();
                return .{ .name = name, .in = in, .out = out };
            } else {
                const initializer = try self.reader.takeU32();
                return .{ .name = name, .init = initializer };
            }
        }
    };
}

pub const FunctionReader = GenericReader(FunctionDecl);

pub const GlobalReader = GenericReader(GlobalDef);

pub const CodeReader = struct {
    reader: Reader,
    remaining: u32,

    pub fn errorOffset(self: CodeReader) usize {
        return self.reader.errorOffset();
    }

    fn init(reader: Reader) !CodeReader {
        var reader_copy = reader;
        const function_count = try reader_copy.takeU32();
        return .{ .reader = reader_copy, .remaining = function_count };
    }

    pub fn next(self: *CodeReader) !?FunctionDef {
        if (self.reader.empty() != (self.remaining == 0))
            return error.InvalidBytecode;
        if (self.remaining == 0) return null;
        const length = try self.reader.takeU32();
        const reader = try self.reader.slice(@intCast(length));
        const function_def = try InstrReader.init(reader);
        self.remaining -= 1;
        return function_def;
    }
};

pub const InstrReader = struct {
    reader: Reader,

    pub fn errorOffset(self: InstrReader) usize {
        return self.reader.errorOffset();
    }

    fn init(reader: Reader) !FunctionDef {
        var reader_copy = reader;
        const locals = try reader_copy.takeU32();
        return .{ .locals = locals, .reader = .{ .reader = reader_copy } };
    }

    pub fn next(self: *InstrReader) !?Instr {
        if (self.reader.empty()) {
            return null;
        }
        const tag = try self.reader.takeEnum(InstrTag);
        switch (tag) {
            inline else => |t| {
                const payload = t.Payload();
                if (payload == void) {
                    return @unionInit(Instr, @tagName(t), {});
                } else if (payload == u32) {
                    const value = try self.reader.takeU32();
                    return @unionInit(Instr, @tagName(t), value);
                } else {
                    const in = try self.reader.takeU32();
                    const out = try self.reader.takeU32();
                    return @unionInit(Instr, @tagName(t), .{ .in = in, .out = out });
                }
            },
        }
    }
};

fn leb128(comptime value: u64) []const u8 {
    comptime {
        var v: u64 = value;
        var out: []const u8 = &.{};
        while (v >= 0x80) : (v >>= 7) {
            out = out ++ &[_]u8{@as(u8, @intCast(v & 0x7f)) | 0x80};
        }
        return out ++ &[_]u8{@as(u8, @intCast(v))};
    }
}

fn lengthPrefix(comptime bytes: []const u8) []const u8 {
    return leb128(bytes.len) ++ bytes;
}

fn section(comptime tag: u8, comptime content: []const u8) []const u8 {
    return &[_]u8{tag} ++ lengthPrefix(content);
}

fn functionDecl(comptime name: []const u8, comptime in: u64, comptime out: u64) []const u8 {
    return lengthPrefix(name) ++ leb128(in) ++ leb128(out);
}

fn globalDef(comptime name: []const u8, comptime init: u64) []const u8 {
    return lengthPrefix(name) ++ leb128(init);
}

fn functionBody(comptime locals: u64, comptime ops: []const u8) []const u8 {
    return lengthPrefix(leb128(locals) ++ ops ++ &[_]u8{0x0b});
}

fn module(comptime parts: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = &(magic ++ version);
        for (parts) |p| out = out ++ p;
        return out;
    }
}

fn encodeOps(comptime ops: []const Instr) []const u8 {
    comptime {
        var out: []const u8 = &.{};
        for (ops) |op| switch (op) {
            inline else => |payload, tag| {
                out = out ++ &[_]u8{@intFromEnum(tag)};
                const Payload = @TypeOf(payload);
                if (Payload == u32) {
                    out = out ++ leb128(payload);
                } else if (Payload == Sig) {
                    out = out ++ leb128(payload.in) ++ leb128(payload.out);
                }
            },
        };
        return out;
    }
}

const function_main = section(0x03, leb128(1) ++ functionDecl("main", 0, 1));
const function_unary = section(0x03, leb128(1) ++ functionDecl("run", 1, 1));
const function_void = section(0x03, leb128(1) ++ functionDecl("f", 0, 0));
const function_binary = section(0x03, leb128(1) ++ functionDecl("add", 2, 1));
const function_triple = section(0x03, leb128(3) ++
    functionDecl("add", 2, 1) ++ functionDecl("dupe", 1, 2) ++ functionDecl("main", 0, 1));

const memory_zero = section(0x05, leb128(0));
const memory_small = section(0x05, leb128(16));
const memory_large = section(0x05, leb128(9999));

const global_zero = section(0x06, leb128(0));
const global_one = section(0x06, leb128(1) ++ globalDef("g", 0));
const global_two = section(0x06, leb128(2) ++
    globalDef("count", 0xffffffff) ++ globalDef("limit", 0x7fffffff));

const start_first = section(0x08, leb128(0));
const start_second = section(0x08, leb128(1));
const start_third = section(0x08, leb128(2));

const code_const = section(0x0a, leb128(1) ++ functionBody(0, &.{ 0x41, 0x01 }));
const code_empty = section(0x0a, leb128(1) ++ functionBody(0, &.{}));
const code_locals = section(0x0a, leb128(1) ++ functionBody(500, &.{ 0x41, 0x00 }));
const code_arith = section(0x0a, leb128(1) ++ functionBody(24, &.{ 0x20, 0x00, 0x20, 0x01, 0x6a, 0x0f }));
const code_memops = section(0x0a, leb128(1) ++ functionBody(0, &.{ 0x41, 0x00, 0x28 }));
const code_block = section(0x0a, leb128(1) ++ functionBody(6, &.{ 0x02, 0x00, 0x00, 0x01, 0x0b }));
const code_loop = section(0x0a, leb128(1) ++ functionBody(0, &.{ 0x03, 0x00, 0x00, 0x01, 0x0b }));
const code_if = section(0x0a, leb128(1) ++ functionBody(0, &.{ 0x04, 0x00, 0x00, 0x01, 0x0b }));
const code_nested = section(0x0a, leb128(1) ++ functionBody(0, &.{ 0x02, 0x00, 0x00, 0x02, 0x00, 0x00, 0x01, 0x0b, 0x0b }));
const code_triple = section(0x0a, leb128(3) ++
    functionBody(0, &.{ 0x20, 0x00, 0x20, 0x01, 0x6a }) ++
    functionBody(0, &.{ 0x20, 0x00, 0x20, 0x00 }) ++
    functionBody(0, &.{ 0x41, 0x02, 0x10, 0x01, 0x10, 0x00 }));

const data_empty = section(0x0b, &.{});
const data_small = section(0x0b, "abcd");
const data_large = section(0x0b, "a" ** 70582);

const valid_modules = [_][]const u8{
    module(&.{ function_main, start_first, code_const }),
    module(&.{ function_unary, start_first, code_arith }),
    module(&.{ function_void, start_first, code_empty }),
    module(&.{ function_binary, start_first, code_locals }),
    module(&.{ function_main, memory_zero, start_first, code_const }),
    module(&.{ function_main, memory_small, start_first, code_memops }),
    module(&.{ function_main, memory_large, start_first, code_block }),
    module(&.{ function_unary, global_one, start_first, code_loop }),
    module(&.{ function_main, global_two, start_first, code_if }),
    module(&.{ function_main, memory_small, global_one, start_first, code_nested }),
    module(&.{ function_main, start_first, code_const, data_small }),
    module(&.{ function_void, start_first, code_empty, data_empty }),
    module(&.{ function_main, memory_small, global_two, start_first, code_arith, data_large }),
    module(&.{ function_triple, start_third, code_triple }),
};

const leb_overflow: []const u8 = &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f };
const leb_truncated: []const u8 = &.{0x80};

const invalid_modules = [_]struct { bytes: []const u8, offset: usize }{
    // Invalid headers
    .{ .bytes = &[_]u8{}, .offset = 0 },
    .{ .bytes = &[_]u8{ 'g', 'v', 'm' }, .offset = 0 },
    .{ .bytes = &[_]u8{ 'g', 'v', 'm', 0x00, 1, 0x00, 0x00 }, .offset = 0 },
    .{ .bytes = &[_]u8{ 'g', 'v', 'm', 0x01, 1, 0x00, 0x00, 0x00 }, .offset = 0 },
    .{ .bytes = &[_]u8{ 'g', 'v', 'm', 0x00, 2, 0x00, 0x00, 0x00 }, .offset = 0 },

    // Missing a required section
    .{ .bytes = module(&.{}), .offset = 0 },
    .{ .bytes = module(&.{function_main}), .offset = 10 },
    .{ .bytes = module(&.{ function_main, start_first }), .offset = 20 },
    .{ .bytes = module(&.{ function_main, code_const }), .offset = 20 },

    // Sections out of order
    .{ .bytes = module(&.{memory_small}), .offset = 10 },
    .{ .bytes = module(&.{global_one}), .offset = 10 },
    .{ .bytes = module(&.{start_first}), .offset = 10 },
    .{ .bytes = module(&.{code_const}), .offset = 10 },
    .{ .bytes = module(&.{data_small}), .offset = 10 },
    .{ .bytes = module(&.{ function_main, global_one, memory_small, start_first, code_const }), .offset = 26 },
    .{ .bytes = module(&.{ function_main, start_first, global_one, code_const }), .offset = 23 },
    .{ .bytes = module(&.{ function_main, start_first, data_small, code_const }), .offset = 23 },

    // Duplicate sections
    .{ .bytes = module(&.{ function_main, function_main, start_first, code_const }), .offset = 20 },
    .{ .bytes = module(&.{ function_main, memory_small, memory_small, start_first, code_const }), .offset = 23 },
    .{ .bytes = module(&.{ function_main, global_one, global_one, start_first, code_const }), .offset = 26 },
    .{ .bytes = module(&.{ function_main, start_first, start_second, code_const }), .offset = 23 },
    .{ .bytes = module(&.{ function_main, start_first, code_const, code_const }), .offset = 31 },
    .{ .bytes = module(&.{ function_main, start_first, code_const, data_small, data_small }), .offset = 37 },

    // Counts that don't match the section contents
    .{ .bytes = module(&.{section(0x03, leb128(2) ++ functionDecl("main", 0, 1))}), .offset = 17 },
    .{ .bytes = module(&.{section(0x03, leb128(0) ++ functionDecl("main", 0, 1))}), .offset = 10 },
    .{ .bytes = module(&.{section(0x03, leb128(5) ++ functionDecl("main", 0, 1))}), .offset = 17 },
    .{ .bytes = module(&.{
        function_main,
        start_first,
        section(0x0a, leb128(2) ++ functionBody(0, &.{ 0x41, 0x01 }) ++ functionBody(0, &.{ 0x41, 0x01 })),
    }), .offset = 23 },
    .{ .bytes = module(&.{
        section(0x03, leb128(2) ++ functionDecl("a", 0, 0) ++ functionDecl("b", 0, 0)), start_first,
        section(0x0a, leb128(2) ++ functionBody(0, &.{})),
    }), .offset = 26 },
    .{ .bytes = module(&.{
        function_main,
        section(0x06, leb128(2) ++ globalDef("g", 0)),
        start_first,
        code_const,
    }), .offset = 23 },
    .{ .bytes = module(&.{
        function_main,
        section(0x06, leb128(0) ++ globalDef("g", 0)),
        start_first,
        code_const,
    }), .offset = 20 },

    // leb128 integers that overflow u32 (one at every position a leb128 appears)
    .{ .bytes = module(&.{&[_]u8{ 0x03, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f }}), .offset = 9 }, // section length
    .{ .bytes = module(&.{&[_]u8{ 0x03, 0x06, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f }}), .offset = 10 },
    .{ .bytes = module(&.{section(0x03, leb128(1) ++ leb_overflow)}), .offset = 11 },
    .{ .bytes = module(&.{section(0x03, leb128(1) ++ lengthPrefix("f") ++ leb_overflow)}), .offset = 13 },
    .{ .bytes = module(&.{section(0x03, leb128(1) ++ lengthPrefix("f") ++ leb128(0) ++ leb_overflow)}), .offset = 14 },
    .{ .bytes = module(&.{ function_main, section(0x05, leb_overflow) }), .offset = 20 },
    .{ .bytes = module(&.{ function_main, section(0x06, leb_overflow), start_first, code_const }), .offset = 20 },
    .{ .bytes = module(&.{ function_main, section(0x06, leb128(1) ++ leb_overflow), start_first, code_const }), .offset = 21 },
    .{ .bytes = module(&.{
        function_main,
        section(0x06, leb128(1) ++ lengthPrefix("g") ++ leb_overflow),
        start_first,
        code_const,
    }), .offset = 23 },
    .{ .bytes = module(&.{ function_main, section(0x08, leb_overflow) }), .offset = 20 },
    .{ .bytes = module(&.{ function_main, start_first, section(0x0a, leb_overflow) }), .offset = 23 },
    .{ .bytes = module(&.{ function_main, start_first, section(0x0a, leb128(1) ++ leb_overflow) }), .offset = 24 },
    .{ .bytes = module(&.{
        function_main,
        start_first,
        section(0x0a, leb128(1) ++ leb128(7) ++ leb_overflow ++ &[_]u8{0x0b}),
    }), .offset = 25 },
    .{ .bytes = module(&.{
        function_main,
        start_first,
        section(0x0a, leb128(1) ++ functionBody(0, &[_]u8{ 0x41, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f })),
    }), .offset = 27 },
    .{ .bytes = module(&.{
        function_main,
        start_first,
        section(0x0a, leb128(1) ++ functionBody(0, &[_]u8{ 0x10, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f })),
    }), .offset = 27 },
    .{ .bytes = module(&.{
        function_main,
        start_first,
        section(0x0a, leb128(1) ++ functionBody(0, &[_]u8{ 0x20, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f })),
    }), .offset = 27 },
    .{ .bytes = module(&.{
        function_main,
        start_first,
        section(0x0a, leb128(1) ++ functionBody(0, &[_]u8{ 0x0c, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f })),
    }), .offset = 27 },
    .{ .bytes = module(&.{
        function_main,
        start_first,
        section(0x0a, leb128(1) ++ functionBody(0, &[_]u8{ 0x02, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f })),
    }), .offset = 27 },
    .{ .bytes = module(&.{
        function_main,
        start_first,
        section(0x0a, leb128(1) ++ functionBody(0, &[_]u8{ 0x02, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f })),
    }), .offset = 28 },

    // leb128 integers truncated mid-stream
    .{ .bytes = module(&.{&[_]u8{ 0x03, 0x80 }}), .offset = 9 },
    .{ .bytes = module(&.{ function_main, section(0x05, leb_truncated) }), .offset = 20 },
    .{ .bytes = module(&.{ function_main, section(0x08, leb_truncated) }), .offset = 20 },
    .{ .bytes = module(&.{ function_main, start_first, section(0x0a, &[_]u8{ 0x01, 0x03, 0x00, 0x41, 0x80 }) }), .offset = 27 },

    // Malformed section framing
    .{ .bytes = module(&.{&[_]u8{0xff}}), .offset = 8 },
    .{ .bytes = module(&.{&[_]u8{ 0x03, 0x0f, 0x00 }}), .offset = 10 },
    .{ .bytes = module(&.{&[_]u8{ 0x03, 0x05, 0x01, 0x01, 0xff, 0x00, 0x00 }}), .offset = 12 },
    .{ .bytes = module(&.{section(0x03, leb128(1) ++ leb128(10) ++ &[_]u8{ 'a', 'b' })}), .offset = 12 },
    .{ .bytes = module(&.{ function_main, section(0x08, &[_]u8{ 0x00, 0x00 }) }), .offset = 20 },
    .{ .bytes = module(&.{ function_main, section(0x05, &[_]u8{ 0x10, 0x00 }) }), .offset = 20 },

    // Malformed instruction streams
    .{ .bytes = module(&.{ function_main, start_first, section(0x0a, leb128(1) ++ functionBody(0, &[_]u8{0x60})) }), .offset = 26 },
};

fn parseErrorOffset(bytes: []const u8) ?usize {
    var mr = ModuleReader.init(bytes) catch return 0;
    while (mr.next() catch return mr.errorOffset()) |sec| {
        switch (sec) {
            .function => |f| {
                var r = f.reader;
                while (r.next() catch return r.errorOffset()) |_| {}
            },
            .global => |g| {
                var r = g.reader;
                while (r.next() catch return r.errorOffset()) |_| {}
            },
            .code => |c| {
                var r = c.reader;
                while (r.next() catch return r.errorOffset()) |def| {
                    var ops = def.reader;
                    while (ops.next() catch return ops.errorOffset()) |_| {}
                }
            },
            else => {},
        }
    }
    return null;
}

test "parse: valid modules" {
    for (valid_modules) |m| {
        try std.testing.expectEqual(parseErrorOffset(m), null);
    }
}

test "parse: error offsets" {
    for (invalid_modules) |m| {
        try std.testing.expectEqual(parseErrorOffset(m.bytes), m.offset);
    }
}

test "parse: round-trip" {
    const void_ops = comptime ops: {
        var ops: []const Instr = &.{};
        for (std.meta.fields(InstrTag)) |f| {
            const tag: InstrTag = @enumFromInt(f.value);
            if (tag == .end or tag.Payload() != void) continue;
            ops = ops ++ &[_]Instr{@unionInit(Instr, f.name, {})};
        }
        break :ops ops;
    };
    const operand_ops = [_]Instr{
        .{ .br = 3 },                        .{ .br_if = 7 },                      .{ .call = 1 },
        .{ .get_local = 0 },                 .{ .set_local = 4 },                  .{ .get_global = 2 },
        .{ .set_global = 5 },                .{ .@"const" = 0xdeadbeef },          .{ .block = .{ .in = 1, .out = 2 } },
        .{ .loop = .{ .in = 0, .out = 0 } }, .{ .@"if" = .{ .in = 3, .out = 1 } }, .@"else",
        .end,                                .end,                                 .end,
        .end,
    };
    const body0_ops = void_ops ++ &operand_ops;
    const body1_ops = [_]Instr{ .{ .get_local = 0 }, .{ .get_local = 1 }, .{ .add = {} }, .{ .@"return" = {} } };
    const body2_ops = [_]Instr{ .{ .@"const" = 42 }, .{ .drop = {} } };

    const mod = comptime module(&.{
        section(0x03, leb128(3) ++
            functionDecl("alpha", 2, 1) ++ functionDecl("beta", 0, 3) ++ functionDecl("gamma", 1, 1)),
        section(0x05, leb128(4096)),
        section(0x06, leb128(3) ++
            globalDef("width", 0) ++ globalDef("height", 256) ++ globalDef("seed", 0xdeadbeef)),
        section(0x08, leb128(2)),
        section(0x0a, leb128(3) ++
            functionBody(7, encodeOps(body0_ops)) ++
            functionBody(0, encodeOps(&body1_ops)) ++
            functionBody(3, encodeOps(&body2_ops))),
        section(0x0b, &[_]u8{ 0x00, 0x01, 0x02, 0xfe, 0xff }),
    });

    const expectEqual = std.testing.expectEqual;
    const expectEqualStrings = std.testing.expectEqualStrings;
    const expectEqualSlices = std.testing.expectEqualSlices;
    var mr = try ModuleReader.init(mod);

    {
        const s = (try mr.next()).?.function;
        try expectEqual(3, s.function_count);
        var r = s.reader;
        for ([_]FunctionDecl{
            .{ .name = "alpha", .in = 2, .out = 1 },
            .{ .name = "beta", .in = 0, .out = 3 },
            .{ .name = "gamma", .in = 1, .out = 1 },
        }) |expected| {
            const actual = (try r.next()).?;
            try expectEqualStrings(expected.name, actual.name);
            try expectEqual(expected.in, actual.in);
            try expectEqual(expected.out, actual.out);
        }
        try expectEqual(null, try r.next());
    }

    {
        const s = (try mr.next()).?.memory;
        try expectEqual(4096, s.memory_size);
    }

    {
        const s = (try mr.next()).?.global;
        try expectEqual(3, s.global_count);
        var r = s.reader;
        for ([_]GlobalDef{
            .{ .name = "width", .init = 0 },
            .{ .name = "height", .init = 256 },
            .{ .name = "seed", .init = 0xdeadbeef },
        }) |expected| {
            const actual = (try r.next()).?;
            try expectEqualStrings(expected.name, actual.name);
            try expectEqual(expected.init, actual.init);
        }
        try expectEqual(null, try r.next());
    }

    {
        const s = (try mr.next()).?.start;
        try expectEqual(2, s.function_id);
    }

    {
        const s = (try mr.next()).?.code;
        try expectEqual(3, s.function_count);
        var r = s.reader;
        for ([_]struct { locals: u32, ops: []const Instr }{
            .{ .locals = 7, .ops = body0_ops },
            .{ .locals = 0, .ops = &body1_ops },
            .{ .locals = 3, .ops = &body2_ops },
        }) |expected| {
            const def = (try r.next()).?;
            try expectEqual(expected.locals, def.locals);
            var ops = def.reader;
            for (expected.ops) |op| {
                try expectEqual(op, try ops.next());
            }
            try expectEqual(.end, try ops.next());
            try expectEqual(null, try ops.next());
        }
        try expectEqual(null, try r.next());
    }

    {
        const s = (try mr.next()).?.data;
        try expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x02, 0xfe, 0xff }, s.data);
    }

    try expectEqual(null, try mr.next());
}
