const std = @import("std");
const execute = @import("execute.zig");
const store = @import("store.zig");
const archive = @import("archive.zig");
const ingest = @import("ingest.zig");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "run")) return execute.run(init, args);
    if (args.len != 3) return error.ExpectedActionAndInput;
    if (std.mem.eql(u8, args[1], "validate")) {
        const report = try store.load(a, init.io, args[2]);
        std.debug.print("valid {t}: {t}\n", .{ report.suite, report.verdict });
    } else if (std.mem.eql(u8, args[1], "publish")) {
        const client = try archive.Client.init(init);
        defer std.Io.Dir.cwd().deleteTree(init.io, client.scratch) catch |err|
            std.debug.print("publisher cleanup: {t}\n", .{err});
        if (init.environ_map.get("ARCHIVE_RUN_ID") != null) {
            try ingest.publish(client, args[2]);
        } else try archive.publish(client, args[2]);
    } else return error.InvalidAction;
}

test {
    std.testing.refAllDecls(@import("model.zig"));
    std.testing.refAllDecls(@import("process.zig"));
    std.testing.refAllDecls(@import("test_catalog"));
    std.testing.refAllDecls(archive);
    std.testing.refAllDecls(ingest);
    std.testing.refAllDecls(@import("report_test.zig"));
    std.testing.refAllDecls(@import("live_test.zig"));
}
