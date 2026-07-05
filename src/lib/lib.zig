pub const parse = @import("parse.zig");

pub fn add(x: i32, y: i32) i32 {
    return x + y;
}

test {
    // Pull imported files' tests (e.g. the parser fuzz target) into the test
    // binary; a `pub const` re-export alone doesn't include them.
    _ = parse;
}
