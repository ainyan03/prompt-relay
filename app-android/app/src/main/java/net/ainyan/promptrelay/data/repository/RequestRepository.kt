package net.ainyan.promptrelay.data.repository

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import net.ainyan.promptrelay.data.model.PermissionRequest
import net.ainyan.promptrelay.data.remote.ApiClient
import net.ainyan.promptrelay.data.remote.PromptRelayApi
import net.ainyan.promptrelay.service.WebSocketManager

class RequestRepository(
    private val wsManager: WebSocketManager,
    private val scope: CoroutineScope
) {
    companion object {
        private const val TAG = "RequestRepository"
        private const val POLL_INTERVAL_MS = 2000L
    }

    private val _requests = MutableStateFlow<List<PermissionRequest>>(emptyList())
    val requests: StateFlow<List<PermissionRequest>> = _requests.asStateFlow()

    private var pollingJob: Job? = null
    private var serverUrl: String = ""
    private var apiKey: String = ""

    init {
        // Subscribe to WebSocket messages
        scope.launch {
            wsManager.messages.collect { message ->
                if (message.type == "update" && message.requests != null) {
                    _requests.value = message.requests
                    stopPolling()
                }
            }
        }

        // Start/stop polling based on WS connection state
        scope.launch {
            wsManager.connectionState.collect { state ->
                when (state) {
                    is WebSocketManager.ConnectionState.Connected -> stopPolling()
                    is WebSocketManager.ConnectionState.Disconnected,
                    is WebSocketManager.ConnectionState.Error -> startPolling()
                    else -> {}
                }
            }
        }
    }

    fun configure(serverUrl: String, apiKey: String) {
        this.serverUrl = serverUrl
        this.apiKey = apiKey
    }

    fun getApi(): PromptRelayApi? {
        if (serverUrl.isBlank()) return null
        return ApiClient.getApi(serverUrl, apiKey)
    }

    suspend fun refreshFromHttp() {
        if (serverUrl.isBlank()) return
        try {
            val api = ApiClient.getApi(serverUrl, apiKey)
            _requests.value = api.getRequests()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to fetch requests", e)
        }
    }

    private fun startPolling() {
        if (serverUrl.isBlank()) return
        if (pollingJob?.isActive == true) return

        pollingJob = scope.launch {
            Log.d(TAG, "Starting HTTP polling")
            while (true) {
                refreshFromHttp()
                delay(POLL_INTERVAL_MS)
            }
        }
    }

    private fun stopPolling() {
        if (pollingJob?.isActive == true) {
            Log.d(TAG, "Stopping HTTP polling (WS connected)")
            pollingJob?.cancel()
            pollingJob = null
        }
    }
}
