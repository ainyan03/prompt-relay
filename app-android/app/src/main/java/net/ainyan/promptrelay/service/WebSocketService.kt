package net.ainyan.promptrelay.service

import android.app.Notification
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.lifecycle.LifecycleService
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import net.ainyan.promptrelay.MainActivity
import net.ainyan.promptrelay.PromptRelayApplication
import net.ainyan.promptrelay.R
import net.ainyan.promptrelay.data.model.PermissionRequest
import net.ainyan.promptrelay.data.remote.PromptRelayApi
import net.ainyan.promptrelay.data.repository.RequestRepository
import net.ainyan.promptrelay.notification.NotificationHelper

class WebSocketService : LifecycleService() {

    companion object {
        private const val TAG = "WebSocketService"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_START = "START"
        private const val ACTION_RECONNECT = "RECONNECT"
        private const val ACTION_DISCONNECT = "DISCONNECT"

        // Global state shared with UI
        private val _requests = MutableStateFlow<List<PermissionRequest>>(emptyList())
        val requests: StateFlow<List<PermissionRequest>> = _requests.asStateFlow()

        private val _connectionState = MutableStateFlow<WebSocketManager.ConnectionState>(
            WebSocketManager.ConnectionState.Disconnected
        )
        val connectionState: StateFlow<WebSocketManager.ConnectionState> =
            _connectionState.asStateFlow()

        private var repository: RequestRepository? = null

        fun start(context: Context) {
            val intent = Intent(context, WebSocketService::class.java).apply {
                action = ACTION_START
            }
            context.startForegroundService(intent)
        }

        fun reconnect(context: Context) {
            val intent = Intent(context, WebSocketService::class.java).apply {
                action = ACTION_RECONNECT
            }
            context.startForegroundService(intent)
        }

        fun disconnect(context: Context) {
            val intent = Intent(context, WebSocketService::class.java).apply {
                action = ACTION_DISCONNECT
            }
            context.startForegroundService(intent)
        }

        fun getApi(): PromptRelayApi? = repository?.getApi()

        fun refreshIfPolling() {
            val repo = repository ?: return
            kotlinx.coroutines.GlobalScope.launch { // 通知アクションからの fire-and-forget（Service のライフサイクル外）
                if (_connectionState.value !is WebSocketManager.ConnectionState.Connected) {
                    repo.refreshFromHttp()
                }
            }
        }
    }

    private lateinit var wsManager: WebSocketManager
    private lateinit var networkMonitor: NetworkMonitor
    private lateinit var notificationHelper: NotificationHelper
    private var previousPendingIds: Set<String> = emptySet()

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "Service created")

        notificationHelper = (application as PromptRelayApplication).notificationHelper
        wsManager = WebSocketManager(lifecycleScope)
        networkMonitor = NetworkMonitor(this)

        val repo = RequestRepository(wsManager, lifecycleScope)
        repository = repo

        // Forward state to companions
        lifecycleScope.launch {
            repo.requests.collect { reqs ->
                _requests.value = reqs
                onRequestsUpdated(reqs)
            }
        }
        lifecycleScope.launch {
            wsManager.connectionState.collect { state ->
                _connectionState.value = state
                updateServiceNotification(state)
            }
        }

        // Network change -> reconnect WS
        networkMonitor.start {
            Log.d(TAG, "Network changed, reconnecting")
            lifecycleScope.launch { connectWithSettings() }
        }

        startForeground(NOTIFICATION_ID, buildServiceNotification("起動中…"))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        super.onStartCommand(intent, flags, startId)

        when (intent?.action) {
            ACTION_START, ACTION_RECONNECT -> {
                lifecycleScope.launch { connectWithSettings() }
            }
            ACTION_DISCONNECT -> wsManager.disconnect()
        }

        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        wsManager.disconnect()
        networkMonitor.stop()
        repository = null
        Log.d(TAG, "Service destroyed")
    }

    private suspend fun connectWithSettings() {
        val app = application as PromptRelayApplication
        val serverUrl = app.settingsDataStore.serverUrl.first()
        val apiKey = app.settingsDataStore.apiKey.first()

        repository?.configure(serverUrl, apiKey)

        if (serverUrl.isBlank()) {
            _connectionState.value = WebSocketManager.ConnectionState.Disconnected
            return
        }

        wsManager.connect(serverUrl, apiKey)
    }

    private fun onRequestsUpdated(requests: List<PermissionRequest>) {
        val currentPendingIds = requests.filter { it.isPending }.map { it.id }.toSet()
        val newPendingIds = currentPendingIds - previousPendingIds

        // Show notification for new pending requests
        for (req in requests) {
            if (req.id in newPendingIds) {
                notificationHelper.showRequestNotification(req)
            }
        }

        // Cancel notifications for responded requests
        for (req in requests) {
            if (!req.isPending) {
                notificationHelper.cancelRequestNotification(req.id)
            }
        }

        // Cancel notifications for requests that disappeared from the list
        val allIds = requests.map { it.id }.toSet()
        for (id in previousPendingIds) {
            if (id !in allIds) {
                notificationHelper.cancelRequestNotification(id)
            }
        }

        previousPendingIds = currentPendingIds
    }

    private fun updateServiceNotification(state: WebSocketManager.ConnectionState) {
        val text = when (state) {
            is WebSocketManager.ConnectionState.Connected -> "サーバに接続中"
            is WebSocketManager.ConnectionState.Connecting -> "接続中…"
            is WebSocketManager.ConnectionState.Disconnected -> "未接続"
            is WebSocketManager.ConnectionState.Error -> "エラー: ${state.message}"
        }
        try {
            notificationHelper.getManager().notify(NOTIFICATION_ID, buildServiceNotification(text))
        } catch (_: Exception) {
        }
    }

    private fun buildServiceNotification(text: String): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, NotificationHelper.CHANNEL_SERVICE)
            .setContentTitle("Prompt Relay")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }
}
