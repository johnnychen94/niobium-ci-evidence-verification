//! UI IR (docs/spec/ui-ir-v1.md): closed node vocabulary, ZON templates validated at
//! comptime, binding, layout, DisplayList, SemanticTree, focus and input. No IO.

pub const ir = @import("ir.zig");
pub const geometry = @import("geometry.zig");
pub const env = @import("env.zig");
pub const template = @import("template.zig");
pub const bind_mod = @import("bind.zig");
pub const text = @import("text.zig");
pub const layout = @import("layout.zig");
pub const display = @import("display.zig");
pub const semantics = @import("semantics.zig");
pub const input = @import("input.zig");
pub const frame = @import("frame.zig");
pub const order = @import("order.zig");
pub const testing = @import("testing.zig");

pub const Tree = ir.Tree;
pub const Node = ir.Node;
pub const Env = env.Env;
pub const TemplateNode = template.TemplateNode;
pub const compile = template.compile;
pub const bind = bind_mod.bind;
pub const Interaction = input.Interaction;
pub const Frame = frame.Frame;
pub const buildFrame = frame.build;

test {
    _ = ir;
    _ = geometry;
    _ = env;
    _ = template;
    _ = bind_mod;
    _ = text;
    _ = layout;
    _ = display;
    _ = semantics;
    _ = order;
    _ = input;
    _ = frame;
    _ = @import("template_test.zig");
    _ = @import("core_test.zig");
    _ = @import("input_test.zig");
}
