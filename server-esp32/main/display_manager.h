#pragma once

#include "request_store.h"

// 画面を初期化
void display_init(void);

// 待機画面を表示
void display_show_idle(const char* ip_str);

// リクエスト表示 (idx: 0-based, total: 全数)
void display_show_request(const PermissionRequest* req, int idx, int total);

// 画面更新 (メインループから呼ぶ)
void display_update(void);

// 新着リクエスト通知 (自動で最新リクエストを表示)
void display_notify_new_request(void);

// 通知表示
void display_show_notification(const char* title, const char* message, const char* hostname);

// 通知ビープ音
void display_beep(void);

// ディスプレイが利用可能か
bool display_available(void);
