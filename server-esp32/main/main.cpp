#include <cstdio>
#include <M5Unified.h>
#include <nvs_flash.h>
#include <esp_log.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include "wifi_setup.h"
#include "mdns_service.h"
#include "request_store.h"
#include "http_server.h"
#include "display_manager.h"
#include "button_handler.h"

static const char* TAG = "main";

extern "C" void app_main(void) {
    // NVS 初期化
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    // M5Unified 初期化
    auto cfg = M5.config();
    M5.begin(cfg);
    ESP_LOGI(TAG, "M5Unified initialized");

    // 画面初期化
    display_init();

    // WiFi 接続
    ESP_LOGI(TAG, "Connecting to WiFi...");
    if (wifi_start() != ESP_OK) {
        ESP_LOGE(TAG, "WiFi connection failed");
        // 画面にエラー表示してリトライ待ち
        if (display_available()) {
            M5.Display.fillScreen(TFT_BLACK);
            M5.Display.setTextDatum(middle_center);
            M5.Display.setTextColor(TFT_RED);
            M5.Display.drawString("WiFi Failed", M5.Display.width() / 2, M5.Display.height() / 2);
        }
        // 再起動まで待機
        vTaskDelay(pdMS_TO_TICKS(10000));
        esp_restart();
    }
    ESP_LOGI(TAG, "WiFi connected: %s", wifi_get_ip_str());

    // mDNS 登録
    mdns_service_start();

    // リクエストストア初期化
    request_store_init();

    // HTTP サーバ起動
    http_server_start();

    // 待機画面表示
    display_show_idle(wifi_get_ip_str());

    ESP_LOGI(TAG, "=== Prompt Relay ESP32 ready ===");
    ESP_LOGI(TAG, "  http://%s:3939", wifi_get_ip_str());
    ESP_LOGI(TAG, "  http://prompt-relay.local:3939");

    // メインループ
    while (true) {
        M5.update();
        button_handler_update();
        request_store_tick();
        display_update();
        vTaskDelay(pdMS_TO_TICKS(50));
    }
}
