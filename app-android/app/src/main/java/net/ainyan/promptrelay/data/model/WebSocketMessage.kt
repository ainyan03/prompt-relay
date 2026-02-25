package net.ainyan.promptrelay.data.model

import kotlinx.serialization.Serializable

@Serializable
data class WebSocketMessage(
    val type: String,
    val requests: List<PermissionRequest>? = null
)
