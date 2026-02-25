#include "mdns_service.h"

#include <esp_log.h>
#include <mdns.h>

static const char* TAG = "mdns";

esp_err_t mdns_service_start(void) {
    esp_err_t err = mdns_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "mdns_init failed: %s", esp_err_to_name(err));
        return err;
    }

    mdns_hostname_set("prompt-relay");
    mdns_instance_name_set("Prompt Relay ESP32");

    mdns_txt_item_t txt[] = {
        { "board", "m5stack" },
        { "version", "0.1.0" },
    };

    err = mdns_service_add(nullptr, "_http", "_tcp", 3939, txt, 2);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "mdns_service_add failed: %s", esp_err_to_name(err));
        return err;
    }

    ESP_LOGI(TAG, "mDNS registered: prompt-relay.local:3939");
    return ESP_OK;
}
