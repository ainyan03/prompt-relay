package net.ainyan.promptrelay.data.model

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class Choice(
    val number: Int,
    val text: String
)

@Serializable
data class PermissionRequest(
    val id: String,
    @SerialName("tool_name") val toolName: String = "",
    val message: String = "",
    val choices: List<Choice>? = null,
    @SerialName("created_at") val createdAt: Long = 0L,
    @SerialName("expires_at") val expiresAt: Long? = null,
    val response: String? = null,
    @SerialName("responded_at") val respondedAt: Long? = null,
    @SerialName("send_key") val sendKey: String? = null,
    val hostname: String? = null
) {
    val isPending: Boolean get() = response == null
    val isCancelled: Boolean get() = response == "cancelled"
    val isExpired: Boolean get() = response == "expired"

    fun remainingSeconds(): Int {
        val deadline = expiresAt ?: (createdAt + 120_000)
        return maxOf(0, ((deadline - System.currentTimeMillis()) / 1000).toInt())
    }

    /** choice 番号から応答テキストを解決する */
    fun resolveChoiceText(choiceNumber: Int): String? {
        return choices?.firstOrNull { it.number == choiceNumber }?.text
    }
}
