//! Hand-written extern bindings for the libzstd v1.5.7 compressor.
//! Linked only into the packager (nbpack); runtime decompression uses std.compress.zstd.

const std = @import("std");

pub const CCtx = opaque {};

pub const c_compression_level: c_int = 100;
pub const c_window_log: c_int = 101;
pub const c_content_size_flag: c_int = 200;
pub const c_checksum_flag: c_int = 201;

pub extern fn ZSTD_createCCtx() ?*CCtx;
pub extern fn ZSTD_freeCCtx(cctx: *CCtx) usize;
pub extern fn ZSTD_CCtx_setParameter(cctx: *CCtx, param: c_int, value: c_int) usize;
pub extern fn ZSTD_compress2(
    cctx: *CCtx,
    dst: [*]u8,
    dst_cap: usize,
    src: [*]const u8,
    src_len: usize,
) usize;
pub extern fn ZSTD_compressBound(src_len: usize) usize;
pub extern fn ZSTD_isError(code: usize) c_uint;
pub extern fn ZSTD_getErrorName(code: usize) [*:0]const u8;

pub const Error = error{ OutOfMemory, CompressFailed };

/// Runtime decompression (std.compress.zstd) defaults to an 8 MiB window; keep frames inside it.
pub const window_log_max: c_int = 23;

/// Compresses `src` into a newly allocated frame. Caller owns the result.
pub fn compress(gpa: std.mem.Allocator, src: []const u8, level: c_int) Error![]u8 {
    const cctx = ZSTD_createCCtx() orelse return error.OutOfMemory;
    // lint-allow(no-discard-call): ZSTD_freeCCtx only fails on a null context.
    defer _ = ZSTD_freeCCtx(cctx);
    try check(ZSTD_CCtx_setParameter(cctx, c_compression_level, level));
    try check(ZSTD_CCtx_setParameter(cctx, c_window_log, window_log_max));
    try check(ZSTD_CCtx_setParameter(cctx, c_content_size_flag, 1));
    try check(ZSTD_CCtx_setParameter(cctx, c_checksum_flag, 0));
    const bound = ZSTD_compressBound(src.len);
    const dst = try gpa.alloc(u8, bound);
    defer gpa.free(dst);
    const written = ZSTD_compress2(cctx, dst.ptr, dst.len, src.ptr, src.len);
    try check(written);
    return gpa.dupe(u8, dst[0..written]);
}

fn check(code: usize) Error!void {
    if (ZSTD_isError(code) != 0) return error.CompressFailed;
}

test "compress round-trips through std zstd" {
    const gpa = std.testing.allocator;
    var input_buf: [8 * 512]u8 = undefined;
    for (0..512) |i| @memcpy(input_buf[i * 8 ..][0..8], "niobium ");
    const input: []const u8 = &input_buf;
    const frame = try compress(gpa, input, 19);
    defer gpa.free(frame);
    var in: std.Io.Reader = .fixed(frame);
    const window = try gpa.alloc(
        u8,
        std.compress.zstd.default_window_len + std.compress.zstd.block_size_max,
    );
    defer gpa.free(window);
    var dec: std.compress.zstd.Decompress = .init(&in, window, .{});
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = try dec.reader.streamRemaining(&out.writer);
    try std.testing.expectEqualStrings(input, out.written());
}
