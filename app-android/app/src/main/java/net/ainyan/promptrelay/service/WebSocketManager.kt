package net.ainyan.promptrelay.service

import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import net.ainyan.promptrelay.data.model.WebSocketMessage
import net.ainyan.promptrelay.data.remote.ApiClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.net.ConnectException
import java.net.UnknownHostException
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLException

class WebSocketManager(private val scope: CoroutineScope) {

    companion object {
        private const val TAG = "WebSocketManager"
        private const val MAX_RECONNECT_DELAY = 30_000L
    }

    sealed class ConnectionState {
        data object Disconnected : ConnectionState()
        data object Connecting : ConnectionState()
        data object Connected : ConnectionState()
        data class Error(val message: String) : ConnectionState()
    }

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private val _connectionState = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    val connectionState: StateFlow<ConnectionState> = _connectionState.asStateFlow()

    private val _messages = MutableSharedFlow<WebSocketMessage>(extraBufferCapacity = 16)
    val messages: SharedFlow<WebSocketMessage> = _messages.asSharedFlow()

    private var webSocket: WebSocket? = null
    private val socketGeneration = AtomicInteger(0)
    private var reconnectDelay = 1000L
    private var reconnectJob: Job? = null
    private var currentServerUrl: String = ""
    private var currentApiKey: String = ""
    private var shouldReconnect = true

    fun connect(serverUrl: String, apiKey: String) {
        if (serverUrl.isBlank()) {
            _connectionState.value = ConnectionState.Disconnected
            return
        }

        currentServerUrl = serverUrl
        currentApiKey = apiKey
        shouldReconnect = true
        reconnectJob?.cancel()

        // 既に接続処理中なら重複呼び出しをスキップ（起動時の競合防止）
        if (_connectionState.value is ConnectionState.Connecting) {
            Log.d(TAG, "Already connecting, skipping duplicate connect()")
            return
        }

        doConnect()
    }

    fun disconnect() {
        shouldReconnect = false
        reconnectJob?.cancel()
        webSocket?.close(1000, "Client disconnect")
        webSocket = null
        _connectionState.value = ConnectionState.Disconnected
    }

    private fun doConnect() {
        webSocket?.close(1000, null)
        webSocket = null

        _connectionState.value = ConnectionState.Connecting

        val wsUrl = buildWsUrl(currentServerUrl)
        val generation = socketGeneration.incrementAndGet()
        Log.d(TAG, "Connecting to $wsUrl (gen=$generation)")

        val request = Request.Builder()
            .url(wsUrl)
            .addHeader("Authorization", "Bearer $currentApiKey")
            .build()

        webSocket = ApiClient.okHttpClient.newWebSocket(request, object : WebSocketListener() {
            // 古い（stale）ソケットのコールバックを無視するためのチェック
            private fun isCurrent() = generation == socketGeneration.get()

            override fun onOpen(webSocket: WebSocket, response: Response) {
                if (!isCurrent()) return
                Log.d(TAG, "WebSocket connected")
                _connectionState.value = ConnectionState.Connected
                reconnectDelay = 1000L
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                if (!isCurrent()) return
                try {
                    val message = json.decodeFromString<WebSocketMessage>(text)
                    scope.launch { _messages.emit(message) }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to parse message: $text", e)
                }
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                if (!isCurrent()) return
                Log.d(TAG, "WebSocket closing: $code $reason")
                webSocket.close(1000, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                if (!isCurrent()) return
                Log.d(TAG, "WebSocket closed: $code $reason")
                if (code == 4001) {
                    _connectionState.value = ConnectionState.Error("認証エラー")
                    return
                }
                _connectionState.value = ConnectionState.Disconnected
                scheduleReconnect()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                if (!isCurrent()) return
                Log.e(TAG, "WebSocket failure", t)
                when {
                    t is UnknownHostException || t is ConnectException -> {
                        _connectionState.value = ConnectionState.Error("設定エラー: URLを確認してください")
                        shouldReconnect = false
                    }
                    t is SSLException || t.cause is SSLException -> {
                        val detail = (t.cause ?: t).message?.take(100) ?: "不明"
                        _connectionState.value = ConnectionState.Error("証明書エラー: $detail")
                        shouldReconnect = false
                    }
                    else -> {
                        val detail = t.message?.take(100) ?: t.javaClass.simpleName
                        _connectionState.value = ConnectionState.Error("接続失敗: $detail")
                        scheduleReconnect()
                    }
                }
            }
        })
    }

    private fun scheduleReconnect() {
        if (!shouldReconnect || currentServerUrl.isBlank()) return

        reconnectJob?.cancel()
        reconnectJob = scope.launch {
            delay(reconnectDelay)
            reconnectDelay = (reconnectDelay * 2).coerceAtMost(MAX_RECONNECT_DELAY)
            if (shouldReconnect) {
                doConnect()
            }
        }
    }

    private fun buildWsUrl(serverUrl: String): String {
        val base = serverUrl.trimEnd('/')
        val wsBase = when {
            base.startsWith("https://") -> "wss://" + base.removePrefix("https://")
            base.startsWith("http://") -> "ws://" + base.removePrefix("http://")
            else -> "ws://$base"
        }
        return "$wsBase/ws"
    }
}
