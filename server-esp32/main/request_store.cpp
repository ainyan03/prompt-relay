#include "request_store.h"

#include <cstring>
#include <cstdio>
#include <algorithm>
#include <esp_log.h>
#include <esp_timer.h>
#include <esp_random.h>

static const char* TAG = "store";

static const int64_t PENDING_TIMEOUT_MS = 120 * 1000;  // 120秒で expired
static const int64_t CLEANUP_AGE_MS = 5 * 60 * 1000;   // 5分で削除

static PermissionRequest s_requests[MAX_REQUESTS];

static int64_t now_ms(void) {
    return esp_timer_get_time() / 1000;
}

void generate_uuid_v4(char* out) {
    uint8_t bytes[16];
    esp_fill_random(bytes, sizeof(bytes));
    // version 4
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // variant 1
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    snprintf(out, UUID_STR_LEN,
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5],
        bytes[6], bytes[7],
        bytes[8], bytes[9],
        bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]);
}

void request_store_init(void) {
    memset(s_requests, 0, sizeof(s_requests));
    ESP_LOGI(TAG, "Request store initialized (max %d slots)", MAX_REQUESTS);
}

// 同じ tmux ペインの未応答リクエストをキャンセル
static void cancel_pending_by_target(const char* tmux_target) {
    if (!tmux_target || tmux_target[0] == '\0') return;
    int64_t ts = now_ms();
    for (int i = 0; i < MAX_REQUESTS; i++) {
        PermissionRequest* r = &s_requests[i];
        if (r->active && r->response[0] == '\0' &&
            strcmp(r->tmux_target, tmux_target) == 0) {
            strncpy(r->response, "cancelled", sizeof(r->response) - 1);
            r->responded_at = ts;
            ESP_LOGI(TAG, "Auto-cancelled %s (same tmux target)", r->id);
        }
    }
}

static void expire_if_stale(PermissionRequest* req) {
    if (req->response[0] == '\0' && (now_ms() - req->created_at) > PENDING_TIMEOUT_MS) {
        strncpy(req->response, "expired", sizeof(req->response) - 1);
        req->responded_at = now_ms();
    }
}

PermissionRequest* request_store_create(
    const char* tool_name,
    const char* message,
    const char* subtitle,
    const Choice* choices, uint8_t choice_count,
    const char* tmux_target,
    const char* hostname
) {
    // 同じ tmux ペインからの未応答リクエストをキャンセル
    cancel_pending_by_target(tmux_target);

    // 空きスロットを探す
    PermissionRequest* slot = nullptr;
    for (int i = 0; i < MAX_REQUESTS; i++) {
        if (!s_requests[i].active) {
            slot = &s_requests[i];
            break;
        }
    }
    if (!slot) {
        // 最も古い応答済みリクエストを上書き
        int64_t oldest = INT64_MAX;
        for (int i = 0; i < MAX_REQUESTS; i++) {
            if (s_requests[i].response[0] != '\0' && s_requests[i].created_at < oldest) {
                oldest = s_requests[i].created_at;
                slot = &s_requests[i];
            }
        }
    }
    if (!slot) {
        ESP_LOGW(TAG, "Request store full, dropping oldest");
        // 最も古いものを上書き
        int64_t oldest = INT64_MAX;
        for (int i = 0; i < MAX_REQUESTS; i++) {
            if (s_requests[i].created_at < oldest) {
                oldest = s_requests[i].created_at;
                slot = &s_requests[i];
            }
        }
    }

    memset(slot, 0, sizeof(PermissionRequest));
    slot->active = true;
    generate_uuid_v4(slot->id);

    if (tool_name) strncpy(slot->tool_name, tool_name, sizeof(slot->tool_name) - 1);
    if (message) strncpy(slot->message, message, sizeof(slot->message) - 1);
    if (subtitle) strncpy(slot->subtitle, subtitle, sizeof(slot->subtitle) - 1);
    if (tmux_target) strncpy(slot->tmux_target, tmux_target, sizeof(slot->tmux_target) - 1);
    if (hostname) strncpy(slot->hostname, hostname, sizeof(slot->hostname) - 1);

    slot->choice_count = (choice_count > MAX_CHOICES) ? MAX_CHOICES : choice_count;
    for (int i = 0; i < slot->choice_count; i++) {
        slot->choices[i] = choices[i];
    }

    slot->created_at = now_ms();

    ESP_LOGI(TAG, "Created request %s: %s", slot->id, slot->tool_name);
    return slot;
}

PermissionRequest* request_store_get(const char* id) {
    for (int i = 0; i < MAX_REQUESTS; i++) {
        if (s_requests[i].active && strcmp(s_requests[i].id, id) == 0) {
            expire_if_stale(&s_requests[i]);
            return &s_requests[i];
        }
    }
    return nullptr;
}

bool request_store_respond(const char* id, const char* response) {
    PermissionRequest* req = request_store_get(id);
    if (!req || req->response[0] != '\0') return false;
    strncpy(req->response, response, sizeof(req->response) - 1);
    req->responded_at = now_ms();
    ESP_LOGI(TAG, "Responded to %s: %s", id, response);
    return true;
}

bool request_store_cancel(const char* id) {
    PermissionRequest* req = request_store_get(id);
    if (!req || req->response[0] != '\0') return false;
    strncpy(req->response, "cancelled", sizeof(req->response) - 1);
    req->responded_at = now_ms();
    ESP_LOGI(TAG, "Cancelled %s", id);
    return true;
}

int request_store_get_all(PermissionRequest** out, int max_count) {
    int count = 0;
    for (int i = 0; i < MAX_REQUESTS && count < max_count; i++) {
        if (s_requests[i].active) {
            expire_if_stale(&s_requests[i]);
            out[count++] = &s_requests[i];
        }
    }
    // created_at 降順ソート
    std::sort(out, out + count, [](const PermissionRequest* a, const PermissionRequest* b) {
        return a->created_at > b->created_at;
    });
    return count;
}

void request_store_resolve_send_key(PermissionRequest* req, const char* response, char* out_key, int out_key_len) {
    if (req->choice_count == 0) {
        // choices がない場合のフォールバック
        snprintf(out_key, out_key_len, "%s", strcmp(response, "deny") == 0 ? "3" : "1");
        return;
    }

    if (strcmp(response, "allow") == 0) {
        // 最初の選択肢
        snprintf(out_key, out_key_len, "%d", req->choices[0].number);
        return;
    }

    if (strcmp(response, "allow_all") == 0) {
        // "don't ask again" / "always" / "省略" を含む選択肢を探す
        for (int i = 0; i < req->choice_count; i++) {
            const char* t = req->choices[i].text;
            if (strcasestr(t, "don't ask") || strcasestr(t, "always") || strstr(t, "省略")) {
                snprintf(out_key, out_key_len, "%d", req->choices[i].number);
                return;
            }
        }
        // 見つからなければ最初の選択肢
        snprintf(out_key, out_key_len, "%d", req->choices[0].number);
        return;
    }

    // deny: 最後の選択肢
    snprintf(out_key, out_key_len, "%d", req->choices[req->choice_count - 1].number);
}

void request_store_cleanup(void) {
    int64_t cutoff = now_ms() - CLEANUP_AGE_MS;
    for (int i = 0; i < MAX_REQUESTS; i++) {
        if (s_requests[i].active && s_requests[i].created_at < cutoff) {
            ESP_LOGI(TAG, "Cleaned up %s", s_requests[i].id);
            s_requests[i].active = false;
        }
    }
}

void request_store_tick(void) {
    // expire チェック + cleanup を定期的に実行
    static int64_t last_cleanup = 0;
    int64_t now = now_ms();

    for (int i = 0; i < MAX_REQUESTS; i++) {
        if (s_requests[i].active) {
            expire_if_stale(&s_requests[i]);
        }
    }

    if (now - last_cleanup > 60000) {
        request_store_cleanup();
        last_cleanup = now;
    }
}

int request_store_pending_count(void) {
    int count = 0;
    for (int i = 0; i < MAX_REQUESTS; i++) {
        if (s_requests[i].active && s_requests[i].response[0] == '\0') {
            count++;
        }
    }
    return count;
}
