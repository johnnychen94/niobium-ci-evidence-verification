//! Platform capability interface, VirtualPlatform and host backends.

pub const api = @import("api.zig");
pub const fault = @import("fault.zig");
pub const local = @import("local.zig");
pub const virtual = @import("virtual.zig");
pub const host = @import("host.zig");
pub const names = @import("names.zig");

pub const Platform = api.Platform;
pub const Error = api.Error;
pub const Env = api.Env;
pub const Os = api.Os;
pub const FaultPlan = fault.FaultPlan;
pub const Virtual = virtual.Virtual;
pub const Host = host.Host;

test {
    _ = api;
    _ = fault;
    _ = local;
    _ = virtual;
    _ = host;
    _ = names;
    _ = @import("files.zig");
    _ = @import("command.zig");
    _ = @import("space.zig");
    // Renderers of every OS are pure and tested on every host.
    _ = @import("macos.zig");
    _ = @import("linux.zig");
    _ = @import("windows.zig");
    _ = @import("windows_registry.zig");
    _ = @import("windows_service.zig");
}
