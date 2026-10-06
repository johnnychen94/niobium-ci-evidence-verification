//! Repository checks (zig build check): module graph, sources, schemas, catalog goldens.

const std = @import("std");
const repo = @import("repo");
const graph = @import("graph.zig");
const sources = @import("sources.zig");
const schemas = @import("schemas.zig");
const catalog = @import("catalog.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const files = try repo.list(arena, io);
    var report: repo.Report = .{ .arena = arena, .tool = "check" };
    try graph.check(&report, io, files);
    try sources.check(&report, io, files);
    try schemas.check(&report, io, files);
    try catalog.check(&report, io);
    try report.finish(io);
}

test {
    _ = graph;
    _ = sources;
    _ = schemas;
    _ = catalog;
}
