idf_component_register(
    SRCS "main.cpp" "wifi_setup.cpp" "mdns_service.cpp"
         "request_store.cpp" "http_server.cpp"
         "display_manager.cpp" "button_handler.cpp"
    INCLUDE_DIRS "."
    REQUIRES nvs_flash esp_http_server esp_wifi esp_netif json esp_timer
)
