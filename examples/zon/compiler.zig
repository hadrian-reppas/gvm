const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    cwd.createDir(io, "out", .default_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var dir = try std.Io.Dir.cwd().openDir(io, "in", .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zon")) {
            const name = std.mem.cutSuffix(u8, entry.name, ".zon").?;
            var buffer: [4096]u8 = undefined;

            const in_path = try std.fmt.allocPrint(gpa, "in/{s}", .{entry.name});
            defer gpa.free(in_path);
            const in_file = try cwd.openFile(io, in_path, .{});
            defer in_file.close(io);
            var in_reader = in_file.reader(io, &buffer);
            const source = try in_reader.interface.allocRemainingAlignedSentinel(gpa, .unlimited, .@"1", 0);
            defer gpa.free(source);

            const module = try std.zon.parse.fromSliceAlloc(Module, gpa, source, null, .{});
            defer std.zon.parse.free(gpa, module);
            const bytes = try translateModule(gpa, module);
            defer gpa.free(bytes);

            const out_path = try std.fmt.allocPrint(gpa, "out/{s}.gvm", .{name});
            defer gpa.free(out_path);
            const out_file = try cwd.createFile(io, out_path, .{});
            defer out_file.close(io);
            try out_file.writeStreamingAll(io, bytes);
        }
    }
}

const Allocator = std.mem.Allocator;
const Buffer = std.ArrayList(u8);

const FunctionDecl = struct { name: []const u8, in: u32, out: u32 };
const FunctionDef = struct { locals: u32, ops: []const []const u8 };
const GlobalDecl = struct { name: []const u8, init: u32 };

const Module = struct {
    function: []const FunctionDecl,
    memory: ?u32 = null,
    global: ?[]const GlobalDecl = null,
    start: u32,
    code: []const FunctionDef,
    data: ?[]const u8 = null,
};

fn emitLeb128(gpa: Allocator, out: *Buffer, value: u32) !void {
    try out.ensureUnusedCapacity(gpa, 5);
    var val = value;
    while (true) {
        var byte: u8 = @intCast(val & 0x7f);
        val >>= 7;
        if (val != 0) byte |= 0x80;
        out.appendAssumeCapacity(byte);
        if (val == 0) return;
    }
}

fn emitSection(gpa: Allocator, out: *Buffer, section: u8, bytes: []const u8) !void {
    try out.append(gpa, section);
    try emitLeb128(gpa, out, @intCast(bytes.len));
    try out.appendSlice(gpa, bytes);
}

fn emitIntSection(gpa: Allocator, out: *Buffer, section: u8, value: u32) !void {
    var buffer: [256]u8 = undefined;
    var alloc = std.heap.FixedBufferAllocator.init(&buffer);

    var valueLeb128: Buffer = .empty;
    try emitLeb128(alloc.allocator(), &valueLeb128, value);

    try emitSection(gpa, out, section, valueLeb128.items);
}

fn translateModule(gpa: Allocator, module: Module) ![]u8 {
    var out: Buffer = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &[_]u8{ 'g', 'v', 'm', 0, 1, 0, 0, 0 });

    const function = try translateFunction(gpa, module.function);
    defer gpa.free(function);
    try emitSection(gpa, &out, Sections.function, function);

    if (module.memory) |size|
        try emitIntSection(gpa, &out, Sections.memory, size);

    if (module.global) |decls| {
        const global = try translateGlobal(gpa, decls);
        defer gpa.free(global);
        try emitSection(gpa, &out, Sections.global, global);
    }

    try emitIntSection(gpa, &out, Sections.start, module.start);

    const code = try translateCode(gpa, module.code);
    defer gpa.free(code);
    try emitSection(gpa, &out, Sections.code, code);

    if (module.data) |data|
        try emitSection(gpa, &out, Sections.data, data);

    return out.toOwnedSlice(gpa);
}

fn translateFunction(gpa: Allocator, decls: []const FunctionDecl) ![]u8 {
    var out: Buffer = .empty;
    errdefer out.deinit(gpa);
    try emitLeb128(gpa, &out, @intCast(decls.len));
    for (decls) |decl| {
        try emitLeb128(gpa, &out, @intCast(decl.name.len));
        try out.appendSlice(gpa, decl.name);
        try emitLeb128(gpa, &out, decl.in);
        try emitLeb128(gpa, &out, decl.out);
    }
    return out.toOwnedSlice(gpa);
}

fn translateGlobal(gpa: Allocator, decls: []const GlobalDecl) ![]u8 {
    var out: Buffer = .empty;
    errdefer out.deinit(gpa);
    try emitLeb128(gpa, &out, @intCast(decls.len));
    for (decls) |decl| {
        try emitLeb128(gpa, &out, @intCast(decl.name.len));
        try out.appendSlice(gpa, decl.name);
        try emitLeb128(gpa, &out, decl.init);
    }
    return out.toOwnedSlice(gpa);
}

fn translateCode(gpa: Allocator, defs: []const FunctionDef) ![]u8 {
    var out: Buffer = .empty;
    errdefer out.deinit(gpa);
    try emitLeb128(gpa, &out, @intCast(defs.len));
    for (defs) |def| {
        const body = try translateBody(gpa, def.locals, def.ops);
        defer gpa.free(body);
        try emitLeb128(gpa, &out, @intCast(body.len));
        try out.appendSlice(gpa, body);
    }
    return out.toOwnedSlice(gpa);
}

fn translateBody(gpa: Allocator, locals: u32, ops: []const []const u8) ![]u8 {
    var out: Buffer = .empty;
    errdefer out.deinit(gpa);
    try emitLeb128(gpa, &out, locals);
    for (ops) |op| {
        var matched = false;
        inline for (@typeInfo(Ops).@"struct".decls) |decl| {
            if (std.mem.eql(u8, op, decl.name)) {
                try out.append(gpa, @field(Ops, decl.name));
                matched = true;
            }
        }
        if (matched) continue;
        if (std.fmt.parseInt(u32, op, 10) catch null) |int| {
            try emitLeb128(gpa, &out, int);
        } else if (std.fmt.parseInt(i32, op, 10) catch null) |int| {
            try emitLeb128(gpa, &out, @bitCast(int));
        } else {
            return error.InvalidOp;
        }
    }
    try out.append(gpa, Ops.end);
    return out.toOwnedSlice(gpa);
}

const Sections = struct {
    pub const function: u8 = 0x03;
    pub const memory: u8 = 0x05;
    pub const global: u8 = 0x06;
    pub const start: u8 = 0x08;
    pub const code: u8 = 0x0a;
    pub const data: u8 = 0x0b;
};

const Ops = struct {
    pub const @"unreachable": u8 = 0x00;
    pub const nop: u8 = 0x01;
    pub const block: u8 = 0x02;
    pub const loop: u8 = 0x03;
    pub const @"if": u8 = 0x04;
    pub const @"else": u8 = 0x05;
    pub const end: u8 = 0x0b;
    pub const br: u8 = 0x0c;
    pub const br_if: u8 = 0x0d;
    pub const @"return": u8 = 0x0f;
    pub const call: u8 = 0x10;
    pub const drop: u8 = 0x1a;
    pub const select: u8 = 0x1b;
    pub const get_local: u8 = 0x20;
    pub const set_local: u8 = 0x21;
    pub const get_global: u8 = 0x23;
    pub const set_global: u8 = 0x24;
    pub const load: u8 = 0x28;
    pub const load8_s: u8 = 0x29;
    pub const load8_u: u8 = 0x2a;
    pub const load16_s: u8 = 0x2b;
    pub const load16_u: u8 = 0x2c;
    pub const store: u8 = 0x2d;
    pub const store8: u8 = 0x2e;
    pub const store16: u8 = 0x2f;
    pub const read: u8 = 0x30;
    pub const read8_s: u8 = 0x31;
    pub const read8_u: u8 = 0x32;
    pub const read16_s: u8 = 0x33;
    pub const read16_u: u8 = 0x34;
    pub const copy: u8 = 0x35;
    pub const move: u8 = 0x36;
    pub const @"const": u8 = 0x41;
    pub const eqz: u8 = 0x45;
    pub const eq: u8 = 0x46;
    pub const ne: u8 = 0x47;
    pub const lt_s: u8 = 0x48;
    pub const lt_u: u8 = 0x49;
    pub const gt_s: u8 = 0x4a;
    pub const gt_u: u8 = 0x4b;
    pub const le_s: u8 = 0x4c;
    pub const le_u: u8 = 0x4d;
    pub const ge_s: u8 = 0x4e;
    pub const ge_u: u8 = 0x4f;
    pub const clz: u8 = 0x67;
    pub const ctz: u8 = 0x68;
    pub const popcnt: u8 = 0x69;
    pub const add: u8 = 0x6a;
    pub const sub: u8 = 0x6b;
    pub const mul: u8 = 0x6c;
    pub const div_s: u8 = 0x6d;
    pub const div_u: u8 = 0x6e;
    pub const rem_s: u8 = 0x6f;
    pub const rem_u: u8 = 0x70;
    pub const @"and": u8 = 0x71;
    pub const @"or": u8 = 0x72;
    pub const xor: u8 = 0x73;
    pub const shl: u8 = 0x74;
    pub const shr_s: u8 = 0x75;
    pub const shr_u: u8 = 0x76;
    pub const rotl: u8 = 0x77;
    pub const rotr: u8 = 0x78;
    pub const self: u8 = 0x8b;
    pub const east: u8 = 0x8c;
    pub const northeast: u8 = 0x8d;
    pub const north: u8 = 0x8e;
    pub const northwest: u8 = 0x8f;
    pub const west: u8 = 0x90;
    pub const southwest: u8 = 0x91;
    pub const south: u8 = 0x92;
    pub const southeast: u8 = 0x93;
    pub const time: u8 = 0x94;
    pub const age: u8 = 0x95;
    pub const row: u8 = 0x96;
    pub const col: u8 = 0x97;
};
