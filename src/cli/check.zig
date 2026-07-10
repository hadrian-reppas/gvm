const std = @import("std");
const gvm = @import("gvm");
const common = @import("common.zig");

const Args = @import("args.zig").PrintArgs;

// TODO: add configurable limits on memory size, number of globals/functions, etc
// TODO: share code with print.zig and run.zig
pub fn main(gpa: std.mem.Allocator, io: std.Io, args: Args) !u8 {
    const bytes = try common.readAlloc(gpa, io, args._path);
    defer gpa.free(bytes);
    const reader = try gvm.parse.ModuleReader.init(bytes);
    try checkModule(gpa, reader);
    return 0;
}

// TODO: print more details if there's an error
fn checkModule(gpa: std.mem.Allocator, module_reader: gvm.parse.ModuleReader) !void {
    var reader = module_reader;
    var validator = gvm.validate.Validator.init(gpa);
    defer validator.deinit();
    while (try reader.next()) |item| {
        switch (item) {
            .function => |f| {
                try validator.declareFunctionCount(f.function_count);
                var function_reader = f.reader;
                while (try function_reader.next()) |decl| {
                    validator.declareFunction(decl);
                }
            },
            .memory => {}, // TODO: compare against limits
            .global => |g| {
                // TODO: compare against limits
                validator.declareGlobalCount(g.global_count);
                var global_reader = g.reader;
                while (try global_reader.next()) |_| {}
            },
            .start => |s| try validator.validateStart(s.function_id),
            .code => |c| {
                var code_reader = c.reader;
                var i: usize = 0;
                while (try code_reader.next()) |def| : (i += 1) {
                    const sig = validator.function_signatures.items[i];
                    try checkFunctionDef(&validator, def, sig);
                }
            },
            .data => {}, // TODO: compare against limits
        }
    }
}

fn checkFunctionDef(
    validator: *gvm.validate.Validator,
    def: gvm.parse.FunctionDef,
    sig: gvm.parse.Sig,
) !void {
    var reader = def.reader;
    try validator.enterFunctionBody(sig.in + def.locals, sig.out);
    std.debug.print("====\n", .{});
    while (try reader.next()) |instr| {
        try validator.validateInstr(instr);
    }
    try validator.exitFunctionBody();
}
