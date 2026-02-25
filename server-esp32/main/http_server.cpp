#include "http_server.h"
#include "request_store.h"
#include "display_manager.h"

#include <cstring>
#include <cstdio>
#include <esp_log.h>
#include <esp_http_server.h>
#include <cJSON.h>

static const char* TAG = "httpd";

#define HTTP_PORT 3939
#define MAX_BODY_LEN 2048
#define MIN_KEY_LENGTH 8
#define MAX_KEY_LENGTH 128

// 認証チェック: Bearer トークンの長さバリデーション (8-128文字)
static bool check_auth(httpd_req_t* req) {
    char buf[256] = {0};
    if (httpd_req_get_hdr_value_str(req, "Authorization", buf, sizeof(buf)) != ESP_OK) {
        return false;
    }
    if (strncmp(buf, "Bearer ", 7) != 0) return false;
    const char* key = buf + 7;
    int len = strlen(key);
    return len >= MIN_KEY_LENGTH && len <= MAX_KEY_LENGTH;
}

static void send_json_error(httpd_req_t* req, int status, const char* error) {
    httpd_resp_set_status(req, status == 400 ? "400 Bad Request" :
                                status == 401 ? "401 Unauthorized" :
                                status == 404 ? "404 Not Found" :
                                status == 503 ? "503 Service Unavailable" :
                                                "500 Internal Server Error");
    httpd_resp_set_type(req, "application/json");
    char buf[128];
    snprintf(buf, sizeof(buf), "{\"error\":\"%s\"}", error);
    httpd_resp_sendstr(req, buf);
}

static void send_json_ok(httpd_req_t* req) {
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"ok\":true}");
}

// URI からリクエスト ID を抽出
// /permission-request/{uuid}/response → uuid 部分
static bool extract_request_id(const char* uri, char* out_id, int out_len) {
    // "/permission-request/" の後ろから UUID を取得
    const char* prefix = "/permission-request/";
    const char* start = strstr(uri, prefix);
    if (!start) return false;
    start += strlen(prefix);

    // 次の "/" か末尾までコピー
    const char* end = strchr(start, '/');
    int len = end ? (int)(end - start) : (int)strlen(start);
    if (len <= 0 || len >= out_len) return false;

    memcpy(out_id, start, len);
    out_id[len] = '\0';
    return true;
}

// POST body を読み込む
static int read_body(httpd_req_t* req, char* buf, int buf_len) {
    int content_len = req->content_len;
    if (content_len <= 0) return 0;
    if (content_len >= buf_len) content_len = buf_len - 1;

    int received = 0;
    while (received < content_len) {
        int ret = httpd_req_recv(req, buf + received, content_len - received);
        if (ret <= 0) {
            if (ret == HTTPD_SOCK_ERR_TIMEOUT) continue;
            return -1;
        }
        received += ret;
    }
    buf[received] = '\0';
    return received;
}

// 前方宣言
static esp_err_t handle_permission_request_response(httpd_req_t* req);
static esp_err_t handle_permission_request_respond(httpd_req_t* req);
static esp_err_t handle_permission_request_cancel(httpd_req_t* req);

// ── GET /health ──
static esp_err_t handle_health(httpd_req_t* req) {
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, "{\"status\":\"ok\"}");
    return ESP_OK;
}

// ── POST /permission-request ──
static esp_err_t handle_permission_request_create(httpd_req_t* req) {
    if (!check_auth(req)) {
        send_json_error(req, 401, "unauthorized");
        return ESP_OK;
    }

    char* body = (char*)malloc(MAX_BODY_LEN);
    if (!body) {
        send_json_error(req, 500, "out of memory");
        return ESP_OK;
    }

    int len = read_body(req, body, MAX_BODY_LEN);
    if (len <= 0) {
        free(body);
        send_json_error(req, 400, "empty body");
        return ESP_OK;
    }

    cJSON* root = cJSON_Parse(body);
    free(body);
    if (!root) {
        send_json_error(req, 400, "invalid json");
        return ESP_OK;
    }

    // フィールド取得
    const char* tool_name = cJSON_GetStringValue(cJSON_GetObjectItem(root, "tool_name"));
    const char* message = cJSON_GetStringValue(cJSON_GetObjectItem(root, "message"));
    const char* header = cJSON_GetStringValue(cJSON_GetObjectItem(root, "header"));
    const char* description = cJSON_GetStringValue(cJSON_GetObjectItem(root, "description"));
    const char* prompt_question = cJSON_GetStringValue(cJSON_GetObjectItem(root, "prompt_question"));
    const char* tmux_target = cJSON_GetStringValue(cJSON_GetObjectItem(root, "tmux_target"));
    const char* hostname = cJSON_GetStringValue(cJSON_GetObjectItem(root, "hostname"));
    cJSON* has_tmux_json = cJSON_GetObjectItem(root, "has_tmux");
    cJSON* tool_input_json = cJSON_GetObjectItem(root, "tool_input");
    cJSON* choices_json = cJSON_GetObjectItem(root, "choices");

    const char* tool_display = (tool_name && tool_name[0]) ? tool_name : "Unknown";
    const char* subtitle_text = (header && header[0]) ? header : tool_display;

    // detailText 構築 (index.ts ロジック移植)
    char detail_text[512] = {0};
    if (description && description[0]) {
        strncpy(detail_text, description, sizeof(detail_text) - 1);
    } else if (tool_input_json) {
        const char* command = cJSON_GetStringValue(cJSON_GetObjectItem(tool_input_json, "command"));
        const char* file_path = cJSON_GetStringValue(cJSON_GetObjectItem(tool_input_json, "file_path"));
        if (command && command[0]) {
            snprintf(detail_text, sizeof(detail_text), "$ %s", command);
        } else if (file_path && file_path[0]) {
            strncpy(detail_text, file_path, sizeof(detail_text) - 1);
        } else if (message && message[0]) {
            strncpy(detail_text, message, sizeof(detail_text) - 1);
        } else {
            snprintf(detail_text, sizeof(detail_text), "%s の実行を許可しますか？", tool_display);
        }
    } else if (message && message[0]) {
        strncpy(detail_text, message, sizeof(detail_text) - 1);
    } else {
        snprintf(detail_text, sizeof(detail_text), "%s の実行を許可しますか？", tool_display);
    }

    // prompt_question 追加
    if (prompt_question && prompt_question[0]) {
        int cur = strlen(detail_text);
        snprintf(detail_text + cur, sizeof(detail_text) - cur, "\n%s", prompt_question);
    }

    // 非 tmux の注記
    if (has_tmux_json && cJSON_IsFalse(has_tmux_json)) {
        int cur = strlen(detail_text);
        snprintf(detail_text + cur, sizeof(detail_text) - cur, "\n⚠ tmux未経由");
    }

    // choices パース
    Choice choices[MAX_CHOICES] = {};
    uint8_t choice_count = 0;
    if (cJSON_IsArray(choices_json)) {
        int arr_size = cJSON_GetArraySize(choices_json);
        for (int i = 0; i < arr_size && i < MAX_CHOICES; i++) {
            cJSON* item = cJSON_GetArrayItem(choices_json, i);
            cJSON* num = cJSON_GetObjectItem(item, "number");
            cJSON* txt = cJSON_GetObjectItem(item, "text");
            if (cJSON_IsNumber(num) && txt) {
                choices[choice_count].number = (uint8_t)num->valueint;
                const char* txt_str = cJSON_GetStringValue(txt);
                if (txt_str) {
                    strncpy(choices[choice_count].text, txt_str, sizeof(choices[choice_count].text) - 1);
                }
                choice_count++;
            }
        }
    }

    // リクエスト作成
    PermissionRequest* pr = request_store_create(
        tool_display, detail_text, subtitle_text,
        choices, choice_count,
        tmux_target, hostname
    );

    if (!pr) {
        cJSON_Delete(root);
        send_json_error(req, 500, "store full");
        return ESP_OK;
    }

    ESP_LOGI(TAG, "[permission] New: %s - %s: %s", pr->id, subtitle_text, detail_text);

    // レスポンス
    cJSON* resp = cJSON_CreateObject();
    cJSON_AddStringToObject(resp, "id", pr->id);
    cJSON_AddStringToObject(resp, "tool_name", tool_display);
    cJSON_AddStringToObject(resp, "message", detail_text);

    char* resp_str = cJSON_PrintUnformatted(resp);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, resp_str);
    free(resp_str);
    cJSON_Delete(resp);
    cJSON_Delete(root);

    // 画面に新着通知 + ビープ音
    display_notify_new_request();
    display_beep();

    return ESP_OK;
}

// ── GET /permission-request/* (キャッチオール: /response をディスパッチ) ──
static esp_err_t handle_permission_request_get_wildcard(httpd_req_t* req) {
    // URI 末尾で振り分け
    const char* uri = req->uri;
    if (strstr(uri, "/response")) {
        return handle_permission_request_response(req);
    }
    send_json_error(req, 404, "not found");
    return ESP_OK;
}

// ── POST /permission-request/* (キャッチオール: /respond, /cancel をディスパッチ) ──
static esp_err_t handle_permission_request_post_wildcard(httpd_req_t* req) {
    const char* uri = req->uri;
    if (strstr(uri, "/respond")) {
        return handle_permission_request_respond(req);
    }
    if (strstr(uri, "/cancel")) {
        return handle_permission_request_cancel(req);
    }
    send_json_error(req, 404, "not found");
    return ESP_OK;
}

static esp_err_t handle_permission_request_response(httpd_req_t* req) {
    if (!check_auth(req)) {
        send_json_error(req, 401, "unauthorized");
        return ESP_OK;
    }

    char id[UUID_STR_LEN] = {0};
    if (!extract_request_id(req->uri, id, sizeof(id))) {
        send_json_error(req, 400, "invalid uri");
        return ESP_OK;
    }

    PermissionRequest* pr = request_store_get(id);
    if (!pr) {
        send_json_error(req, 404, "not found");
        return ESP_OK;
    }

    cJSON* resp = cJSON_CreateObject();
    cJSON_AddStringToObject(resp, "id", pr->id);
    if (pr->response[0] != '\0') {
        cJSON_AddStringToObject(resp, "response", pr->response);
        cJSON_AddNumberToObject(resp, "responded_at", (double)pr->responded_at);
        if (pr->send_key[0] != '\0') {
            cJSON_AddStringToObject(resp, "send_key", pr->send_key);
        } else {
            cJSON_AddNullToObject(resp, "send_key");
        }
    } else {
        cJSON_AddNullToObject(resp, "response");
        cJSON_AddNullToObject(resp, "responded_at");
        cJSON_AddNullToObject(resp, "send_key");
    }

    char* resp_str = cJSON_PrintUnformatted(resp);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, resp_str);
    free(resp_str);
    cJSON_Delete(resp);
    return ESP_OK;
}

// ── POST /permission-request/*/respond ──
static esp_err_t handle_permission_request_respond(httpd_req_t* req) {
    if (!check_auth(req)) {
        send_json_error(req, 401, "unauthorized");
        return ESP_OK;
    }

    char id[UUID_STR_LEN] = {0};
    if (!extract_request_id(req->uri, id, sizeof(id))) {
        send_json_error(req, 400, "invalid uri");
        return ESP_OK;
    }

    char body[256] = {0};
    int len = read_body(req, body, sizeof(body));
    if (len <= 0) {
        send_json_error(req, 400, "empty body");
        return ESP_OK;
    }

    cJSON* root = cJSON_Parse(body);
    if (!root) {
        send_json_error(req, 400, "invalid json");
        return ESP_OK;
    }

    PermissionRequest* pr = request_store_get(id);
    if (!pr) {
        cJSON_Delete(root);
        send_json_error(req, 404, "not found");
        return ESP_OK;
    }

    char send_key[8] = {0};
    char actual_response[16] = {0};

    cJSON* choice_json = cJSON_GetObjectItem(root, "choice");
    cJSON* response_json = cJSON_GetObjectItem(root, "response");

    if (cJSON_IsNumber(choice_json)) {
        int choice = choice_json->valueint;
        snprintf(send_key, sizeof(send_key), "%d", choice);

        // Question は全選択肢が等価 → allow
        // 権限プロンプトは最後の選択肢 = deny
        if (strcmp(pr->tool_name, "Question") == 0) {
            strcpy(actual_response, "allow");
        } else {
            bool is_last = pr->choice_count > 0 &&
                           choice == pr->choices[pr->choice_count - 1].number;
            strcpy(actual_response, is_last ? "deny" : "allow");
        }
    } else if (response_json && cJSON_IsString(response_json)) {
        const char* resp_str = cJSON_GetStringValue(response_json);
        if (strcmp(resp_str, "allow") == 0 || strcmp(resp_str, "deny") == 0 || strcmp(resp_str, "allow_all") == 0) {
            request_store_resolve_send_key(pr, resp_str, send_key, sizeof(send_key));
            if (strcmp(resp_str, "allow_all") == 0) {
                strcpy(actual_response, "allow");
            } else {
                strncpy(actual_response, resp_str, sizeof(actual_response) - 1);
            }
        } else {
            cJSON_Delete(root);
            send_json_error(req, 400, "invalid response value");
            return ESP_OK;
        }
    } else {
        cJSON_Delete(root);
        send_json_error(req, 400, "response or choice is required");
        return ESP_OK;
    }

    bool ok = request_store_respond(id, actual_response);
    if (!ok) {
        cJSON_Delete(root);
        send_json_error(req, 404, "already responded");
        return ESP_OK;
    }

    // send_key を保存
    strncpy(pr->send_key, send_key, sizeof(pr->send_key) - 1);

    ESP_LOGI(TAG, "[respond] %s: send_key=%s (%s)", id, send_key, actual_response);

    cJSON_Delete(root);
    send_json_ok(req);

    // 画面更新
    display_notify_new_request();

    return ESP_OK;
}

// ── POST /permission-request/*/cancel ──
static esp_err_t handle_permission_request_cancel(httpd_req_t* req) {
    if (!check_auth(req)) {
        send_json_error(req, 401, "unauthorized");
        return ESP_OK;
    }

    char id[UUID_STR_LEN] = {0};
    if (!extract_request_id(req->uri, id, sizeof(id))) {
        send_json_error(req, 400, "invalid uri");
        return ESP_OK;
    }

    bool ok = request_store_cancel(id);
    if (!ok) {
        send_json_error(req, 404, "not found or already responded");
        return ESP_OK;
    }

    ESP_LOGI(TAG, "[cancel] %s", id);
    send_json_ok(req);

    display_notify_new_request();
    return ESP_OK;
}

// ── GET /permission-requests ──
static esp_err_t handle_permission_requests_list(httpd_req_t* req) {
    if (!check_auth(req)) {
        send_json_error(req, 401, "unauthorized");
        return ESP_OK;
    }

    PermissionRequest* reqs[MAX_REQUESTS];
    int count = request_store_get_all(reqs, MAX_REQUESTS);

    cJSON* arr = cJSON_CreateArray();
    for (int i = 0; i < count; i++) {
        PermissionRequest* r = reqs[i];
        cJSON* item = cJSON_CreateObject();
        cJSON_AddStringToObject(item, "id", r->id);
        cJSON_AddStringToObject(item, "tool_name", r->tool_name);
        cJSON_AddStringToObject(item, "message", r->message);

        if (r->choice_count > 0) {
            cJSON* choices = cJSON_CreateArray();
            for (int j = 0; j < r->choice_count; j++) {
                cJSON* c = cJSON_CreateObject();
                cJSON_AddNumberToObject(c, "number", r->choices[j].number);
                cJSON_AddStringToObject(c, "text", r->choices[j].text);
                cJSON_AddItemToArray(choices, c);
            }
            cJSON_AddItemToObject(item, "choices", choices);
        } else {
            cJSON_AddNullToObject(item, "choices");
        }

        cJSON_AddNumberToObject(item, "created_at", (double)r->created_at);

        if (r->response[0] != '\0') {
            cJSON_AddStringToObject(item, "response", r->response);
            cJSON_AddNumberToObject(item, "responded_at", (double)r->responded_at);
        } else {
            cJSON_AddNullToObject(item, "response");
            cJSON_AddNullToObject(item, "responded_at");
        }

        if (r->send_key[0] != '\0') {
            cJSON_AddStringToObject(item, "send_key", r->send_key);
        } else {
            cJSON_AddNullToObject(item, "send_key");
        }

        if (r->hostname[0] != '\0') {
            cJSON_AddStringToObject(item, "hostname", r->hostname);
        } else {
            cJSON_AddNullToObject(item, "hostname");
        }

        cJSON_AddItemToArray(arr, item);
    }

    char* json_str = cJSON_PrintUnformatted(arr);
    httpd_resp_set_type(req, "application/json");
    httpd_resp_sendstr(req, json_str);
    free(json_str);
    cJSON_Delete(arr);
    return ESP_OK;
}

// ── POST /notify ──
static esp_err_t handle_notify(httpd_req_t* req) {
    if (!check_auth(req)) {
        send_json_error(req, 401, "unauthorized");
        return ESP_OK;
    }

    char body[512] = {0};
    int len = read_body(req, body, sizeof(body));
    if (len <= 0) {
        send_json_error(req, 400, "empty body");
        return ESP_OK;
    }

    cJSON* root = cJSON_Parse(body);
    if (!root) {
        send_json_error(req, 400, "invalid json");
        return ESP_OK;
    }

    const char* title = cJSON_GetStringValue(cJSON_GetObjectItem(root, "title"));
    const char* message = cJSON_GetStringValue(cJSON_GetObjectItem(root, "message"));
    const char* hostname = cJSON_GetStringValue(cJSON_GetObjectItem(root, "hostname"));

    ESP_LOGI(TAG, "[notify] %s%s%s%s: %s",
        title ? title : "Claude Code",
        hostname ? " [" : "", hostname ? hostname : "", hostname ? "]" : "",
        message ? message : "(no message)");

    // 画面に通知表示
    display_show_notification(
        title ? title : "Claude Code",
        message ? message : "",
        hostname
    );

    cJSON_Delete(root);
    send_json_ok(req);
    return ESP_OK;
}

// ── ワイルドカード URI マッチング ──
// ESP-IDF の httpd_uri_match_wildcard を使うため、
// /permission-request/*/response 等をワイルドカード登録する

esp_err_t http_server_start(void) {

    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.server_port = HTTP_PORT;
    config.uri_match_fn = httpd_uri_match_wildcard;
    config.max_uri_handlers = 16;
    config.stack_size = 8192;
    config.recv_wait_timeout = 10;
    config.send_wait_timeout = 10;

    httpd_handle_t server = nullptr;
    esp_err_t err = httpd_start(&server, &config);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "httpd_start failed: %s", esp_err_to_name(err));
        return err;
    }

    // ルート登録 (順序重要: 具体的なパスを先に)

    // GET /health
    httpd_uri_t uri_health = {
        .uri = "/health",
        .method = HTTP_GET,
        .handler = handle_health,
        .user_ctx = nullptr,
    };
    httpd_register_uri_handler(server, &uri_health);

    // POST /permission-request (完全一致 — ワイルドカードより先に)
    httpd_uri_t uri_pr_create = {
        .uri = "/permission-request",
        .method = HTTP_POST,
        .handler = handle_permission_request_create,
        .user_ctx = nullptr,
    };
    httpd_register_uri_handler(server, &uri_pr_create);

    // GET /permission-requests (一覧)
    httpd_uri_t uri_pr_list = {
        .uri = "/permission-requests",
        .method = HTTP_GET,
        .handler = handle_permission_requests_list,
        .user_ctx = nullptr,
    };
    httpd_register_uri_handler(server, &uri_pr_list);

    // GET /permission-request/* (catch-all for /response)
    httpd_uri_t uri_pr_get_wild = {
        .uri = "/permission-request/*",
        .method = HTTP_GET,
        .handler = handle_permission_request_get_wildcard,
        .user_ctx = nullptr,
    };
    httpd_register_uri_handler(server, &uri_pr_get_wild);

    // POST /permission-request/* (catch-all for /respond, /cancel)
    httpd_uri_t uri_pr_post_wild = {
        .uri = "/permission-request/*",
        .method = HTTP_POST,
        .handler = handle_permission_request_post_wildcard,
        .user_ctx = nullptr,
    };
    httpd_register_uri_handler(server, &uri_pr_post_wild);

    // POST /notify
    httpd_uri_t uri_notify = {
        .uri = "/notify",
        .method = HTTP_POST,
        .handler = handle_notify,
        .user_ctx = nullptr,
    };
    httpd_register_uri_handler(server, &uri_notify);

    ESP_LOGI(TAG, "HTTP server started on port %d", HTTP_PORT);

    return ESP_OK;
}
