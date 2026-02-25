#pragma once

#include <cstdint>

#define MAX_REQUESTS 8
#define MAX_CHOICES 8
#define UUID_STR_LEN 37

struct Choice {
    uint8_t number;
    char text[32];
};

struct PermissionRequest {
    bool active;
    char id[UUID_STR_LEN];
    char tool_name[64];
    char message[512];
    char subtitle[64];
    uint8_t choice_count;
    Choice choices[MAX_CHOICES];
    char tmux_target[64];
    char hostname[64];
    int64_t created_at;         // ミリ秒 (boot 相対)
    char response[16];          // "" / "allow" / "deny" / "cancelled" / "expired"
    int64_t responded_at;       // 0 = 未応答
    char send_key[8];
};

// 初期化
void request_store_init(void);

// リクエスト作成 (cancelPendingByTarget 込み)
// 戻り値: 作成されたリクエストへのポインタ (nullptr = 空きなし)
PermissionRequest* request_store_create(
    const char* tool_name,
    const char* message,
    const char* subtitle,
    const Choice* choices, uint8_t choice_count,
    const char* tmux_target,
    const char* hostname
);

// ID でリクエスト取得 (expireIfStale 込み)
PermissionRequest* request_store_get(const char* id);

// 応答を記録
bool request_store_respond(const char* id, const char* response);

// キャンセル
bool request_store_cancel(const char* id);

// 全リクエスト取得 (created_at 降順)
// 戻り値: 取得数
int request_store_get_all(PermissionRequest** out, int max_count);

// send_key を決定
void request_store_resolve_send_key(PermissionRequest* req, const char* response, char* out_key, int out_key_len);

// 古いリクエストをクリーンアップ (5分超過で非アクティブ化)
void request_store_cleanup(void);

// タイムアウトチェック (メインループから呼ぶ)
void request_store_tick(void);

// UUID v4 生成
void generate_uuid_v4(char* out);

// 未応答のリクエスト数を取得
int request_store_pending_count(void);
