#include "display_manager.h"

#include <cstdio>
#include <cstring>
#include <M5Unified.h>
#include <esp_timer.h>

static bool s_available = false;
static bool s_dirty = true;

enum DisplayState {
    IDLE,
    SHOWING_REQUEST,
    SHOWING_NOTIFICATION,
};

static DisplayState s_state = IDLE;
static char s_ip_str[32] = {0};
static const PermissionRequest* s_current_req = nullptr;
static int s_current_idx = 0;
static int s_current_total = 0;
static int64_t s_notification_time = 0;

// ディスプレイ参照 (短縮用)
static M5GFX* s_lcd = nullptr;

// 色定義 (RGB888)
static constexpr uint32_t COL_BG        = 0x1a1a2eu;
static constexpr uint32_t COL_HEADER_BG = 0x16213eu;
static constexpr uint32_t COL_TEXT      = 0xeeeeeeu;
static constexpr uint32_t COL_DIM       = 0x888888u;
static constexpr uint32_t COL_ACCENT    = 0xe94560u;
static constexpr uint32_t COL_GREEN     = 0x4caf50u;
static constexpr uint32_t COL_BTN_BG    = 0x333333u;

// レイアウト定数
static int s_font_h = 16;
static int s_header_h = 22;
static int s_btn_bar_h = 22;
static int s_disp_w = 320;
static int s_disp_h = 240;

void display_init(void) {
    if (M5.Display.width() == 0 || M5.Display.height() == 0) {
        s_available = false;
        return;
    }
    s_available = true;
    s_lcd = &M5.Display;

    s_lcd->setRotation(1);
    s_disp_w = s_lcd->width();
    s_disp_h = s_lcd->height();

    // 日本語フォント設定
    s_lcd->setFont(&fonts::efontJA_14);
    s_lcd->setTextSize(1);
    s_font_h = s_lcd->fontHeight();
    s_header_h = s_font_h + 6;
    s_btn_bar_h = s_font_h + 6;

    // 起動画面
    s_lcd->startWrite();
    s_lcd->fillScreen(COL_BG);
    s_lcd->setTextColor(COL_TEXT, COL_BG);
    s_lcd->setTextDatum(middle_center);
    s_lcd->drawString("Prompt Relay", s_disp_w / 2, s_disp_h / 2 - 12);
    s_lcd->drawString("Starting...", s_disp_w / 2, s_disp_h / 2 + 12);
    s_lcd->endWrite();
}

bool display_available(void) {
    return s_available;
}

void display_beep(void) {
    M5.Speaker.tone(1800, 200);
}

// 背景色つきで矩形領域をテキストで埋める (残り部分も bg で塗りつぶし)
static void fill_text_line(int x, int y, int w, const char* text, uint32_t fg, uint32_t bg, uint8_t datum = top_left) {
    s_lcd->setTextDatum(datum);
    s_lcd->setTextColor(fg, bg);
    s_lcd->fillRect(x, y, w, s_font_h, bg);
    s_lcd->drawString(text, x + (datum == top_left ? 0 : datum == top_right ? w : w / 2), y);
}

// テキスト折り返し描画 (UTF-8 対応、背景色塗りつぶし付き)
static void draw_wrapped_text(const char* text, int x, int* y, int max_x, int max_y, uint32_t fg, uint32_t bg) {
    s_lcd->setTextDatum(top_left);
    s_lcd->setTextColor(fg, bg);

    int cursor_x = x;
    const char* p = text;

    // 行開始時にその行の背景を塗る
    auto fill_line_bg = [&]() {
        s_lcd->fillRect(x, *y, max_x - x, s_font_h, bg);
    };

    fill_line_bg();

    while (*p && *y < max_y) {
        if (*p == '\n') {
            cursor_x = x;
            *y += s_font_h;
            if (*y < max_y) fill_line_bg();
            p++;
            continue;
        }

        // UTF-8 文字長
        int char_len = 1;
        uint8_t c = (uint8_t)*p;
        if (c >= 0xC0 && c < 0xE0) char_len = 2;
        else if (c >= 0xE0 && c < 0xF0) char_len = 3;
        else if (c >= 0xF0) char_len = 4;

        char ch_buf[5] = {0};
        for (int i = 0; i < char_len && p[i]; i++) ch_buf[i] = p[i];

        int cw = s_lcd->textWidth(ch_buf);

        if (cursor_x + cw > max_x) {
            cursor_x = x;
            *y += s_font_h;
            if (*y >= max_y) break;
            fill_line_bg();
        }

        s_lcd->drawString(ch_buf, cursor_x, *y);
        cursor_x += cw;
        p += char_len;
    }

    *y += s_font_h;
}

static void draw_button_bar(const char* btn_a, const char* btn_b, const char* btn_c) {
    int y = s_disp_h - s_btn_bar_h;
    int btn_w = s_disp_w / 3;

    s_lcd->fillRect(0, y, s_disp_w, s_btn_bar_h, COL_BTN_BG);
    s_lcd->setTextDatum(middle_center);
    s_lcd->setTextColor(COL_TEXT, COL_BTN_BG);

    if (btn_a && btn_a[0]) {
        char buf[24];
        snprintf(buf, sizeof(buf), "[A:%s]", btn_a);
        s_lcd->drawString(buf, btn_w * 0 + btn_w / 2, y + s_btn_bar_h / 2);
    }
    if (btn_b && btn_b[0]) {
        char buf[24];
        snprintf(buf, sizeof(buf), "[B:%s]", btn_b);
        s_lcd->drawString(buf, btn_w * 1 + btn_w / 2, y + s_btn_bar_h / 2);
    }
    if (btn_c && btn_c[0]) {
        char buf[24];
        snprintf(buf, sizeof(buf), "[C:%s]", btn_c);
        s_lcd->drawString(buf, btn_w * 2 + btn_w / 2, y + s_btn_bar_h / 2);
    }
}

static void draw_header_bar(const char* left, const char* center, const char* right,
                            uint32_t left_col, uint32_t right_col) {
    s_lcd->fillRect(0, 0, s_disp_w, s_header_h, COL_HEADER_BG);
    s_lcd->setTextColor(left_col, COL_HEADER_BG);
    s_lcd->setTextDatum(middle_left);
    s_lcd->drawString(left, 4, s_header_h / 2);

    if (center && center[0]) {
        s_lcd->setTextDatum(middle_center);
        s_lcd->setTextColor(COL_TEXT, COL_HEADER_BG);
        s_lcd->drawString(center, s_disp_w / 2, s_header_h / 2);
    }

    if (right && right[0]) {
        s_lcd->setTextDatum(middle_right);
        s_lcd->setTextColor(right_col, COL_HEADER_BG);
        s_lcd->drawString(right, s_disp_w - 4, s_header_h / 2);
    }
}

void display_show_idle(const char* ip_str) {
    if (!s_available) return;
    s_state = IDLE;
    strncpy(s_ip_str, ip_str, sizeof(s_ip_str) - 1);
    s_dirty = true;
}

static void draw_idle(void) {
    s_lcd->startWrite();

    // ヘッダ
    draw_header_bar("Prompt Relay", nullptr, "WiFi", COL_ACCENT, COL_GREEN);

    // 本文エリアを背景色で塗りつぶし
    int body_y = s_header_h;
    int body_h = s_disp_h - s_header_h - s_btn_bar_h;
    s_lcd->fillRect(0, body_y, s_disp_w, body_h, COL_BG);

    // IP アドレス
    s_lcd->setTextDatum(top_left);
    s_lcd->setTextColor(COL_TEXT, COL_BG);
    char addr[48];
    snprintf(addr, sizeof(addr), "%s:3939", s_ip_str);
    s_lcd->drawString(addr, 4, s_header_h + 4);

    // 承認待ち数
    s_lcd->setTextDatum(middle_center);
    int pending = request_store_pending_count();
    if (pending == 0) {
        s_lcd->setTextColor(COL_DIM, COL_BG);
        s_lcd->drawString("承認待ちなし", s_disp_w / 2, s_disp_h / 2);
    } else {
        s_lcd->setTextColor(COL_ACCENT, COL_BG);
        char buf[32];
        snprintf(buf, sizeof(buf), "承認待ち %d 件", pending);
        s_lcd->drawString(buf, s_disp_w / 2, s_disp_h / 2);
    }

    draw_button_bar("---", "---", "---");
    s_lcd->endWrite();
}

void display_show_request(const PermissionRequest* req, int idx, int total) {
    if (!s_available) return;
    s_current_req = req;
    s_current_idx = idx;
    s_current_total = total;
    s_state = SHOWING_REQUEST;
    s_dirty = true;
}

static void draw_request(void) {
    if (!s_current_req) return;
    const PermissionRequest* req = s_current_req;

    s_lcd->startWrite();

    // ── ヘッダバー ──
    char host_buf[32];
    if (req->hostname[0]) {
        snprintf(host_buf, sizeof(host_buf), "%.16s", req->hostname);
    } else {
        strcpy(host_buf, "local");
    }

    char idx_buf[16];
    snprintf(idx_buf, sizeof(idx_buf), "[%d/%d]", s_current_idx + 1, s_current_total);

    int64_t elapsed_sec = (esp_timer_get_time() / 1000000) - (req->created_at / 1000);
    if (elapsed_sec < 0) elapsed_sec = 0;
    char time_buf[16];
    snprintf(time_buf, sizeof(time_buf), "%02d:%02d", (int)(elapsed_sec / 60), (int)(elapsed_sec % 60));

    draw_header_bar(host_buf, idx_buf, time_buf,
                    COL_TEXT, req->response[0] != '\0' ? COL_DIM : COL_ACCENT);

    // 区切り線
    s_lcd->drawFastHLine(0, s_header_h, s_disp_w, COL_DIM);

    // ── 本文エリアを背景で塗りつぶし ──
    int body_top = s_header_h + 1;
    int body_bottom = s_disp_h - s_btn_bar_h;
    s_lcd->fillRect(0, body_top, s_disp_w, body_bottom - body_top, COL_BG);

    // ── subtitle ──
    int y = body_top + 2;
    s_lcd->setTextDatum(top_left);
    s_lcd->setTextColor(COL_ACCENT, COL_BG);
    s_lcd->drawString(req->subtitle, 4, y);
    y += s_font_h + 2;

    // ── message (折り返し) ──
    int max_y = body_bottom - 2;
    if (req->response[0] != '\0') {
        max_y -= (s_font_h + 2);
    }
    draw_wrapped_text(req->message, 4, &y, s_disp_w - 4, max_y, COL_TEXT, COL_BG);

    // ── 応答済みステータス ──
    if (req->response[0] != '\0') {
        int status_y = body_bottom - s_font_h - 2;
        s_lcd->setTextDatum(top_left);
        s_lcd->setTextColor(strcmp(req->response, "allow") == 0 ? COL_GREEN : COL_ACCENT, COL_BG);
        char status_buf[32];
        snprintf(status_buf, sizeof(status_buf), "> %s", req->response);
        s_lcd->drawString(status_buf, 4, status_y);
        draw_button_bar("---", "---", "Next");
    } else {
        const char* btn_a = "---";
        const char* btn_b = "---";
        if (req->choice_count > 0) {
            btn_a = req->choices[0].text;
        }
        if (req->choice_count > 1) {
            btn_b = req->choices[req->choice_count - 1].text;
        }
        draw_button_bar(btn_a, btn_b, "Next");
    }

    s_lcd->endWrite();
}

// ヘッダ右側の経過時間だけ部分更新
static void update_request_timer(void) {
    if (!s_current_req) return;
    const PermissionRequest* req = s_current_req;

    int64_t elapsed_sec = (esp_timer_get_time() / 1000000) - (req->created_at / 1000);
    if (elapsed_sec < 0) elapsed_sec = 0;
    char time_buf[16];
    snprintf(time_buf, sizeof(time_buf), "%02d:%02d", (int)(elapsed_sec / 60), (int)(elapsed_sec % 60));

    // タイマー表示領域だけ上書き (ヘッダ右端)
    int time_w = s_lcd->textWidth("00:00") + 8;
    int time_x = s_disp_w - time_w;

    s_lcd->startWrite();
    s_lcd->fillRect(time_x, 0, time_w, s_header_h, COL_HEADER_BG);
    s_lcd->setTextDatum(middle_right);
    s_lcd->setTextColor(req->response[0] != '\0' ? COL_DIM : COL_ACCENT, COL_HEADER_BG);
    s_lcd->drawString(time_buf, s_disp_w - 4, s_header_h / 2);
    s_lcd->endWrite();
}

void display_show_notification(const char* title, const char* message, const char* hostname) {
    if (!s_available) return;

    s_state = SHOWING_NOTIFICATION;
    s_notification_time = esp_timer_get_time() / 1000;
    s_dirty = true;

    s_lcd->startWrite();

    // ヘッダ
    draw_header_bar("通知", nullptr, hostname, COL_ACCENT, COL_DIM);

    // 本文エリア
    int body_top = s_header_h;
    int body_bottom = s_disp_h - s_btn_bar_h;
    s_lcd->fillRect(0, body_top, s_disp_w, body_bottom - body_top, COL_BG);

    s_lcd->setTextDatum(top_left);
    s_lcd->setTextColor(COL_TEXT, COL_BG);
    s_lcd->drawString(title, 4, s_header_h + 6);

    if (message && message[0]) {
        s_lcd->setTextColor(COL_DIM, COL_BG);
        s_lcd->drawString(message, 4, s_header_h + 6 + s_font_h + 4);
    }

    draw_button_bar("---", "---", "OK");
    s_lcd->endWrite();
}

void display_notify_new_request(void) {
    if (!s_available) return;

    PermissionRequest* reqs[MAX_REQUESTS];
    int count = request_store_get_all(reqs, MAX_REQUESTS);

    for (int i = 0; i < count; i++) {
        if (reqs[i]->response[0] == '\0') {
            int pending = 0;
            for (int j = 0; j < count; j++) {
                if (reqs[j]->response[0] == '\0') pending++;
            }
            display_show_request(reqs[i], 0, pending);
            return;
        }
    }

    display_show_idle(s_ip_str);
}

void display_update(void) {
    if (!s_available) return;

    if (s_state == SHOWING_NOTIFICATION) {
        int64_t now = esp_timer_get_time() / 1000;
        if (now - s_notification_time > 5000) {
            display_notify_new_request();
        }
    }

    // リクエスト表示中は経過時間のみ部分更新 (全画面再描画しない)
    if (s_state == SHOWING_REQUEST) {
        static int64_t last_timer = 0;
        int64_t now = esp_timer_get_time() / 1000;
        if (now - last_timer > 1000) {
            update_request_timer();
            last_timer = now;
        }
    }

    if (!s_dirty) return;
    s_dirty = false;

    switch (s_state) {
        case IDLE:
            draw_idle();
            break;
        case SHOWING_REQUEST:
            draw_request();
            break;
        case SHOWING_NOTIFICATION:
            break;
    }
}
