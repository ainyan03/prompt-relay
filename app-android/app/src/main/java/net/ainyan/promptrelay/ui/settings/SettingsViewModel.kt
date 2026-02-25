package net.ainyan.promptrelay.ui.settings

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import net.ainyan.promptrelay.PromptRelayApplication
import net.ainyan.promptrelay.service.WebSocketService

class SettingsViewModel(application: Application) : AndroidViewModel(application) {

    private val dataStore = (application as PromptRelayApplication).settingsDataStore

    private val _editServerUrl = MutableStateFlow("")
    val editServerUrl: StateFlow<String> = _editServerUrl.asStateFlow()

    private val _editApiKey = MutableStateFlow("")
    val editApiKey: StateFlow<String> = _editApiKey.asStateFlow()

    val connectionEnabled: StateFlow<Boolean> = dataStore.connectionEnabled.stateIn(
        viewModelScope, SharingStarted.WhileSubscribed(5000), true
    )

    init {
        viewModelScope.launch {
            // DataStore から直接 first() で読む（stateIn の初期値 "" を経由しない→バグ修正）
            _editServerUrl.value = dataStore.serverUrl.first()
            _editApiKey.value = dataStore.apiKey.first()

            // 初期値設定後に debounce 収集を開始（初期値の自動保存を防ぐ）
            launch {
                _editServerUrl.drop(1).debounce(500).collect { url ->
                    dataStore.setServerUrl(url.trim())
                    if (connectionEnabled.value && url.isNotBlank()) {
                        WebSocketService.reconnect(getApplication())
                    }
                }
            }
            launch {
                _editApiKey.drop(1).debounce(500).collect { key ->
                    dataStore.setApiKey(key.trim())
                    if (connectionEnabled.value && editServerUrl.value.isNotBlank()) {
                        WebSocketService.reconnect(getApplication())
                    }
                }
            }
        }

        // Error 状態はステータステキストで表示。トグルはユーザーの意図を反映し、自動 OFF しない。
        // （shouldReconnect=false で再接続ループは既に防止済み）
    }

    fun onServerUrlChange(url: String) {
        _editServerUrl.value = url
    }

    fun onApiKeyChange(key: String) {
        _editApiKey.value = key
    }

    fun setConnectionEnabled(enabled: Boolean) {
        viewModelScope.launch { dataStore.setConnectionEnabled(enabled) }
        if (enabled) {
            WebSocketService.reconnect(getApplication())
        } else {
            WebSocketService.disconnect(getApplication())
        }
    }
}
