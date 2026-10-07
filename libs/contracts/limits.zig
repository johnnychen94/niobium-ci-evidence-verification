//! Every external input has a maximum (TigerStyle: put a limit on everything). Values are u32/u64,
//! never usize, so the contract is identical on every target. Exceeding a limit is an error
//! (`LimitExceeded` families per module), never a panic.

pub const Limits = struct {
    manifest_bytes: u32 = 1 << 20,
    json_depth: u8 = 32,
    json_string_bytes: u32 = 64 << 10,
    components: u16 = 64,
    integrations_per_kind: u16 = 32,
    icon_png_bytes: u32 = 256 << 10,
    dependencies_per_component: u16 = 64,
    capabilities_per_component: u16 = 64,

    files_per_artifact: u32 = 65_536,
    path_bytes: u16 = 1024,
    path_components: u16 = 64,
    expanded_bytes: u64 = 8 << 30,
    compression_ratio: u16 = 200,
    /// Tiny artifacts compress tar padding extremely well; the ratio applies above this floor.
    compression_ratio_floor_bytes: u64 = 1 << 20,
    archive_entry_bytes: u64 = 2 << 30,

    tuf_metadata_bytes: u32 = 4 << 20,
    tuf_timestamp_bytes: u32 = 16 << 10,
    tuf_signatures: u16 = 64,
    tuf_keys: u16 = 64,
    tuf_targets: u32 = 10_000,
    tuf_root_rotations: u16 = 128,

    http_body_bytes: u64 = 8 << 30,
    http_redirects: u8 = 5,
    ipc_message_bytes: u32 = 1 << 20,
    journal_record_bytes: u32 = 64 << 10,
    journal_records: u32 = 1_000_000,
    plan_ops: u32 = 200_000,
    bootstrap_output_bytes: u32 = 64 << 10,
    bootstrap_timeout_ms: u32 = 120_000,
    helper_idle_timeout_ms: u32 = 600_000,
    test_report_bytes: u32 = 1 << 20,
    test_string_bytes: u16 = 4096,
    test_output_bytes: u32 = 4 << 20,
    test_attachment_bytes: u32 = 64 << 20,
    test_attachments: u16 = 1024,
    test_archive_workers: u8 = 4,
    test_workflow_zip_bytes: u32 = 256 << 20,
    test_workflow_unpacked_bytes: u32 = 1 << 30,
    test_workflow_files: u32 = 16_384,
    test_cases: u16 = 256,
    test_timeout_ms: u32 = 600_000,
    test_bundle_bytes: u32 = 256 << 20,
    test_zip_bytes: u32 = 128 << 20,
    test_bundle_files: u16 = 8192,
    test_bundle_depth: u8 = 5,
    test_github_pages: u8 = 10,
    test_github_items: u8 = 100,
    retry_attempts: u8 = 5,
    ui_nodes: u32 = 4096,
    ui_template_bytes: u32 = 256 << 10,
    png_pixels: u32 = 4096 * 4096,
};

pub const default: Limits = .{};

test "limits are internally consistent" {
    const std = @import("std");
    try std.testing.expect(default.path_bytes >= 260);
    try std.testing.expect(default.expanded_bytes >= default.archive_entry_bytes);
    try std.testing.expect(default.compression_ratio > 1);
    try std.testing.expect(default.ipc_message_bytes <= default.manifest_bytes);
}
