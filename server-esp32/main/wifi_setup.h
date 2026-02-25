#pragma once

#include <esp_err.h>
#include <esp_netif.h>

// WiFi STA 接続を開始し、IP 取得まで待機する
esp_err_t wifi_start(void);

// 現在の IP アドレス文字列を取得 (例: "192.168.1.100")
const char* wifi_get_ip_str(void);

// WiFi 接続中かどうか
bool wifi_is_connected(void);
