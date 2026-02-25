package net.ainyan.promptrelay.notification

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import net.ainyan.promptrelay.MainActivity
import net.ainyan.promptrelay.R
import net.ainyan.promptrelay.data.model.PermissionRequest

class NotificationHelper(private val context: Context) {

    companion object {
        const val CHANNEL_SERVICE = "channel_service"
        const val CHANNEL_REQUESTS = "channel_requests"
        private const val REQUEST_NOTIFICATION_BASE_ID = 1000 // フォアグラウンドサービス通知(ID=1)との衝突を回避
    }

    private val manager: NotificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    fun getManager(): NotificationManager = manager

    fun createChannels() {
        val serviceChannel = NotificationChannel(
            CHANNEL_SERVICE,
            "接続状態",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "サーバとの接続状態を表示します"
            setShowBadge(false)
        }

        val requestsChannel = NotificationChannel(
            CHANNEL_REQUESTS,
            "承認要求",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            description = "Claude Code の承認要求を通知します"
            enableVibration(true)
        }

        manager.createNotificationChannels(listOf(serviceChannel, requestsChannel))
    }

    fun showRequestNotification(request: PermissionRequest) {
        val notificationId = requestNotificationId(request.id)

        // Tap action -> open app
        val contentIntent = PendingIntent.getActivity(
            context, notificationId,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(context, CHANNEL_REQUESTS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(request.toolName)
            .setContentText(request.message)
            .setStyle(NotificationCompat.BigTextStyle().bigText(request.message))
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_HIGH)

        // Subtitle with hostname
        if (!request.hostname.isNullOrEmpty()) {
            builder.setSubText(request.hostname)
        }

        // Add action buttons based on choices
        val choices = request.choices
        if (!choices.isNullOrEmpty()) {
            // Android supports max 3 action buttons
            // Use first choice (approve), last choice (deny), and optionally one middle
            val buttonsToShow = when {
                choices.size <= 3 -> choices
                else -> listOf(choices.first(), choices[1], choices.last())
            }

            for (choice in buttonsToShow) {
                val actionIntent = Intent(context, NotificationActionReceiver::class.java).apply {
                    action = "RESPOND_CHOICE"
                    putExtra("request_id", request.id)
                    putExtra("choice", choice.number)
                }
                val actionPendingIntent = PendingIntent.getBroadcast(
                    context,
                    notificationId * 100 + choice.number,
                    actionIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                builder.addAction(0, choice.text, actionPendingIntent)
            }
        } else {
            // Fallback: Approve / Deny
            val approveIntent = Intent(context, NotificationActionReceiver::class.java).apply {
                action = "RESPOND_LEGACY"
                putExtra("request_id", request.id)
                putExtra("response", "allow")
            }
            val denyIntent = Intent(context, NotificationActionReceiver::class.java).apply {
                action = "RESPOND_LEGACY"
                putExtra("request_id", request.id)
                putExtra("response", "deny")
            }

            builder.addAction(
                0, "Approve",
                PendingIntent.getBroadcast(
                    context, notificationId * 100 + 1, approveIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )
            builder.addAction(
                0, "Deny",
                PendingIntent.getBroadcast(
                    context, notificationId * 100 + 2, denyIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )
        }

        manager.notify(notificationId, builder.build())
    }

    fun cancelRequestNotification(requestId: String) {
        manager.cancel(requestNotificationId(requestId))
    }

    private fun requestNotificationId(requestId: String): Int {
        // Use hash to get a stable notification ID from UUID
        return REQUEST_NOTIFICATION_BASE_ID + (requestId.hashCode() and 0x7FFFFFFF) % 10000
    }
}
