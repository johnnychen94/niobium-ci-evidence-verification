//! Wire contracts: manifest, TUF, journal, IPC, bootstrap, CLI events, limits, strict JSON,
//! and the GUI ViewModel.
//! Pure data and codecs; no IO beyond std.Io.Reader/Writer arguments.

pub const limits = @import("limits.zig");
pub const json = @import("json.zig");
pub const canonical = @import("canonical.zig");
pub const ids = @import("ids.zig");
pub const time = @import("time.zig");
pub const manifest = @import("manifest.zig");
pub const tuf = @import("tuf.zig");
pub const journal = @import("journal.zig");
pub const ipc = @import("ipc.zig");
pub const bootstrap = @import("bootstrap.zig");
pub const events = @import("events.zig");
pub const installation = @import("installation.zig");
pub const plan = @import("plan.zig");
pub const ui = @import("ui.zig");

pub const Limits = limits.Limits;
pub const Platform = ids.Platform;
pub const Scope = ids.Scope;
pub const Channel = ids.Channel;
pub const Digest = ids.Digest;

test {
    _ = limits;
    _ = json;
    _ = canonical;
    _ = ids;
    _ = time;
    _ = manifest;
    _ = tuf;
    _ = journal;
    _ = ipc;
    _ = bootstrap;
    _ = events;
    _ = installation;
    _ = plan;
    _ = ui;
}
