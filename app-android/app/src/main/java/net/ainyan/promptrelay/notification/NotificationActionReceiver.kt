package net.ainyan.promptrelay.notification

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import net.ainyan.promptrelay.data.remote.ChoiceResponse
import net.ainyan.promptrelay.data.remote.LegacyResponse
import net.ainyan.promptrelay.service.WebSocketService

class NotificationActionReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "NotificationAction"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val requestId = intent.getStringExtra("request_id") ?: return

        val pendingResult = goAsync()

        CoroutineScope(Dispatchers.IO).launch {
            try {
                val api = WebSocketService.getApi() ?: run {
                    Log.e(TAG, "API not available")
                    return@launch
                }

                when (intent.action) {
                    "RESPOND_CHOICE" -> {
                        val choice = intent.getIntExtra("choice", -1)
                        if (choice >= 0) {
                            Log.d(TAG, "Responding to $requestId with choice $choice")
                            api.respondWithChoice(requestId, ChoiceResponse(choice, "android-notification"))
                        }
                    }
                    "RESPOND_LEGACY" -> {
                        val response = intent.getStringExtra("response") ?: return@launch
                        Log.d(TAG, "Responding to $requestId with $response")
                        api.respond(requestId, LegacyResponse(response, "android-notification"))
                    }
                }

                WebSocketService.refreshIfPolling()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to respond to $requestId", e)
            } finally {
                pendingResult.finish()
            }
        }
    }
}
