#pragma once

#include <esp_err.h>

// HTTP サーバをポート 3939 で起動
esp_err_t http_server_start(void);
