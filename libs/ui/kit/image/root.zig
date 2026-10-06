//! Image: the product logo or app icon at its declared token size; the renderer resolves the
//! source and draws a placeholder when the product has no image.

const paint = @import("../paint.zig");

const Env = paint.Env;
const Node = paint.Node;

pub fn measure(env: *const Env, n: *const Node, max_w: i32) paint.Size {
    _ = n;
    const side = @min(env.token(.logo), max_w);
    return .{ .w = side, .h = side };
}

pub fn emit(
    env: *const Env,
    n: *const Node,
    at: paint.Placement,
    list: *paint.DisplayList,
) paint.Error!void {
    _ = env;
    try list.add(.{ .image = .{ .rect = at.rect, .source = n.source } });
}
