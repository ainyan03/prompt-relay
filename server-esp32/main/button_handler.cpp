#include "button_handler.h"
#include "request_store.h"
#include "display_manager.h"
#include "wifi_setup.h"

#include <cstring>
#include <cstdio>
#include <M5Unified.h>
#include <esp_log.h>

static const char* TAG = "button";

static int s_current_index = 0;

// choice 番号で応答する
static void respond_with_choice(PermissionRequest* req, int choice_number) {
    char send_key[8];
    snprintf(send_key, sizeof(send_key), "%d", choice_number);

    // Question は全選択肢 allow、権限プロンプトは最後が deny
    const char* actual_response;
    if (strcmp(req->tool_name, "Question") == 0) {
        actual_response = "allow";
    } else {
        bool is_last = req->choice_count > 0 &&
                       choice_number == req->choices[req->choice_count - 1].number;
        actual_response = is_last ? "deny" : "allow";
    }

    bool ok = request_store_respond(req->id, actual_response);
    if (ok) {
        strncpy(req->send_key, send_key, sizeof(req->send_key) - 1);
        ESP_LOGI(TAG, "Responded %s: choice=%d send_key=%s (%s)",
            req->id, choice_number, send_key, actual_response);
    }

    // 画面更新
    display_notify_new_request();
}

void button_handler_update(void) {
    if (!display_available()) return;

    // 未応答リクエストを収集
    PermissionRequest* all[MAX_REQUESTS];
    int all_count = request_store_get_all(all, MAX_REQUESTS);

    PermissionRequest* pending[MAX_REQUESTS];
    int pending_count = 0;
    for (int i = 0; i < all_count; i++) {
        if (all[i]->response[0] == '\0') {
            pending[pending_count++] = all[i];
        }
    }

    // ボタン C: 次のリクエスト / 通知 OK
    if (M5.BtnC.wasPressed()) {
        if (pending_count > 0) {
            s_current_index = (s_current_index + 1) % pending_count;
            display_show_request(pending[s_current_index], s_current_index, pending_count);
        } else {
            // 通知表示中なら idle に戻る
            display_show_idle(wifi_get_ip_str());
        }
        return;
    }

    if (pending_count == 0) return;

    // インデックスの範囲チェック
    if (s_current_index >= pending_count) {
        s_current_index = 0;
    }

    PermissionRequest* current = pending[s_current_index];

    // ボタン A: 最初の選択肢で応答
    if (M5.BtnA.wasPressed() && current->choice_count > 0) {
        respond_with_choice(current, current->choices[0].number);
        s_current_index = 0;
    }

    // ボタン B: 最後の選択肢で応答
    if (M5.BtnB.wasPressed() && current->choice_count > 1) {
        respond_with_choice(current, current->choices[current->choice_count - 1].number);
        s_current_index = 0;
    }
}
