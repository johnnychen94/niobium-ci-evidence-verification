/*
 * C ABI smoke (N1-AC-10): compiled by zig cc against api/c/distribution.h and the static
 * libdistribution. Without arguments it checks the table and the error statuses; with
 * `<repository> <root.json> <product> <install-dir> <work-dir>` it also installs the product
 * through check_update -> resolve -> fetch -> stage -> transaction_commit.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "distribution.h"

static int failures = 0;

#define EXPECT(cond)                                                    \
    do {                                                                \
        if (!(cond)) {                                                  \
            fprintf(stderr, "c-smoke: %s:%d: %s\n", __FILE__, __LINE__, #cond); \
            failures++;                                                 \
        }                                                               \
    } while (0)

static void DIST_CALL on_event(void *user, const uint8_t *json, size_t len) {
    int *count = (int *)user;
    (*count)++;
    fprintf(stderr, "event: %.*s\n", (int)len, (const char *)json);
}

static uint8_t *read_file(const char *path, size_t *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    uint8_t *data = NULL;
    size_t len = 0;
    if (fseek(f, 0, SEEK_END) == 0) {
        long size = ftell(f);
        if (size > 0 && fseek(f, 0, SEEK_SET) == 0) {
            data = malloc((size_t)size);
            if (data) len = fread(data, 1, (size_t)size, f);
        }
    }
    fclose(f);
    *out_len = len;
    return data;
}

static void check_errors(const dist_api_v1 *api) {
    dist_context *ctx = NULL;
    EXPECT(api->context_create(NULL, &ctx) == DIST_E_USAGE);
    EXPECT(ctx == NULL);
    static const uint8_t root[] = "{}";
    dist_config_v1 config;
    memset(&config, 0, sizeof config);
    config.struct_size = sizeof config;
    config.repository = "/nonexistent/niobium-repository";
    config.trust_root = root;
    config.trust_root_len = sizeof root - 1;
    config.product_id = "Not An Id";
    config.scope = DIST_SCOPE_USER;
    EXPECT(api->context_create(&config, &ctx) == DIST_E_USAGE);
    config.product_id = "com.example.hello";
    config.scope = 7;
    EXPECT(api->context_create(&config, &ctx) == DIST_E_USAGE);
    config.scope = DIST_SCOPE_USER;
    EXPECT(api->context_create(&config, &ctx) == DIST_E_NETWORK);
    EXPECT(api->resolve(NULL) == DIST_E_USAGE);
    api->context_destroy(NULL);
}

static int install(const dist_api_v1 *api, char **argv) {
    size_t root_len = 0;
    uint8_t *root = read_file(argv[2], &root_len);
    if (!root) {
        fprintf(stderr, "c-smoke: cannot read %s\n", argv[2]);
        return 1;
    }
    dist_config_v1 config;
    memset(&config, 0, sizeof config);
    config.struct_size = sizeof config;
    config.repository = argv[1];
    config.trust_root = root;
    config.trust_root_len = root_len;
    config.product_id = argv[3];
    config.scope = DIST_SCOPE_USER;
    config.install_dir = argv[4];
    config.work_dir = argv[5];
    dist_context *ctx = NULL;
    int32_t status = api->context_create(&config, &ctx);
    EXPECT(status == DIST_OK);
    if (status != DIST_OK) {
        free(root);
        return 1;
    }
    int events = 0;
    EXPECT(api->event_subscribe(ctx, on_event, &events) == DIST_OK);
    dist_update_info_v1 info;
    memset(&info, 0, sizeof info);
    info.struct_size = sizeof info;
    EXPECT(api->check_update(ctx, &info) == DIST_OK);
    printf("offer: available=%d sequence=%llu installed=%llu version=%s\n",
           info.update_available, (unsigned long long)info.release_sequence,
           (unsigned long long)info.installed_release_sequence, info.version);
    EXPECT(api->resolve(ctx) == DIST_OK);
    EXPECT(api->fetch(ctx) == DIST_OK);
    EXPECT(api->stage(ctx) == DIST_OK);
    status = api->transaction_commit(ctx);
    if (status != DIST_OK) {
        dist_buffer error = {0};
        api->last_error(ctx, &error);
        fprintf(stderr, "c-smoke: commit %d: %.*s\n", status, (int)error.len,
                (const char *)error.data);
    }
    EXPECT(status == DIST_OK);
    EXPECT(events > 0);
    api->context_destroy(ctx);
    free(root);
    return 0;
}

int main(int argc, char **argv) {
    const dist_api_v1 *api = NULL;
    EXPECT(dist_get_api(DIST_ABI_V1 + 1, &api) == DIST_E_USAGE);
    if (dist_get_api(DIST_ABI_V1, &api) != DIST_OK || api == NULL) {
        fprintf(stderr, "c-smoke: dist_get_api failed\n");
        return 1;
    }
    EXPECT(api->struct_size >= sizeof(dist_api_v1));
    check_errors(api);
    if (argc == 6) install(api, argv);
    else if (argc != 1) {
        fprintf(stderr, "usage: c-smoke [<repository> <root.json> <product> <install> <work>]\n");
        return 2;
    }
    if (failures == 0) printf("c-smoke: ok\n");
    return failures == 0 ? 0 : 1;
}
