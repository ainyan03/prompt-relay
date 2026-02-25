#pragma once

#include <esp_err.h>

// mDNS サービスを開始し、prompt-relay.local を登録する
esp_err_t mdns_service_start(void);
