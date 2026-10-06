/*
 * Niobium Distribution C ABI v1 (docs/spec/abi-v1.md).
 *
 * Every function returns DIST_OK (0) or a negative status whose magnitude equals the CLI exit
 * code (docs/spec/cli-v1.md). No Zig error, allocator or slice crosses this boundary.
 * Buffers returned through dist_buffer are owned by the library and stay valid until the next
 * call on the same context.
 */
#ifndef NIOBIUM_DISTRIBUTION_H
#define NIOBIUM_DISTRIBUTION_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define DIST_CALL __cdecl
#if defined(DIST_BUILD_DLL)
#define DIST_EXPORT __declspec(dllexport)
#else
#define DIST_EXPORT
#endif
#else
#define DIST_CALL
#define DIST_EXPORT __attribute__((visibility("default")))
#endif

#define DIST_ABI_V1 1u

enum {
    DIST_OK = 0,
    DIST_E_INTERNAL = -1,
    DIST_E_USAGE = -2,
    DIST_E_VALIDATION = -3,
    DIST_E_TRUST = -4,
    DIST_E_NETWORK = -5,
    DIST_E_FILESYSTEM = -6,
    DIST_E_PERMISSION = -7,
    DIST_E_BOOTSTRAP_PENDING = -8,
    DIST_E_CANCELLED = -9,
    DIST_E_BUSY = -10,
    DIST_E_UNSUPPORTED_SCHEMA = -11,
    DIST_E_NOT_INSTALLED = -12,
    DIST_E_UNSUPPORTED_PLATFORM = -13
};

enum {
    DIST_SCOPE_USER = 0,
    DIST_SCOPE_MACHINE = 1
};

typedef struct dist_context dist_context;

typedef struct dist_buffer {
    const uint8_t *data;
    size_t len;
} dist_buffer;

typedef struct dist_config_v1 {
    /* sizeof(dist_config_v1); lets later versions append fields. */
    uint32_t struct_size;
    /* Repository URL (http/https) or directory path, NUL-terminated UTF-8. */
    const char *repository;
    /* Trusted root metadata bytes (<N>.root.json). */
    const uint8_t *trust_root;
    size_t trust_root_len;
    const char *product_id;
    /* "stable", "beta" or "nightly"; NULL means "stable". */
    const char *channel;
    /* DIST_SCOPE_USER or DIST_SCOPE_MACHINE. */
    int32_t scope;
    /* Install root override; NULL uses the platform default for the scope. */
    const char *install_dir;
    /* Working directory for downloads and staging; NULL uses the platform cache dir. */
    const char *work_dir;
} dist_config_v1;

typedef struct dist_update_info_v1 {
    uint32_t struct_size;
    /* 1 when the channel offers a release_sequence above the installed one. */
    int32_t update_available;
    uint64_t release_sequence;
    uint64_t installed_release_sequence;
    /* NUL-terminated app_version of the offered release. */
    char version[64];
} dist_update_info_v1;

/* Receives one JSON event (docs/spec/cli-v1.md, schema 1); bytes are not NUL-terminated. */
typedef void (DIST_CALL *dist_event_fn)(void *user, const uint8_t *json, size_t len);

typedef struct dist_api_v1 {
    uint32_t struct_size;
    int32_t (DIST_CALL *context_create)(const dist_config_v1 *config, dist_context **out_context);
    void (DIST_CALL *context_destroy)(dist_context *context);
    int32_t (DIST_CALL *check_update)(dist_context *context, dist_update_info_v1 *out_info);
    int32_t (DIST_CALL *resolve)(dist_context *context);
    int32_t (DIST_CALL *fetch)(dist_context *context);
    int32_t (DIST_CALL *stage)(dist_context *context);
    int32_t (DIST_CALL *transaction_commit)(dist_context *context);
    int32_t (DIST_CALL *portable_resolve)(dist_context *context, const char *target,
                                          dist_buffer *out_path);
    /* argv: NULL-terminated arguments after the program name, or NULL for none. */
    int32_t (DIST_CALL *portable_run)(dist_context *context, const char *target,
                                      const char *const *argv, int32_t *out_exit_code);
    int32_t (DIST_CALL *event_subscribe)(dist_context *context, dist_event_fn callback, void *user);
    int32_t (DIST_CALL *cancel)(dist_context *context);
    int32_t (DIST_CALL *last_error)(dist_context *context, dist_buffer *out_json);
} dist_api_v1;

DIST_EXPORT int32_t DIST_CALL dist_get_api(uint32_t requested_version, const dist_api_v1 **out_api);

#ifdef __cplusplus
}
#endif

#endif /* NIOBIUM_DISTRIBUTION_H */
