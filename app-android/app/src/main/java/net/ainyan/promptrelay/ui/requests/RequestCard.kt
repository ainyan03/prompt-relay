package net.ainyan.promptrelay.ui.requests

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import net.ainyan.promptrelay.data.model.PermissionRequest
import net.ainyan.promptrelay.ui.theme.Danger
import net.ainyan.promptrelay.ui.theme.Success
import net.ainyan.promptrelay.ui.theme.Surface2
import net.ainyan.promptrelay.ui.theme.TextDim
import net.ainyan.promptrelay.ui.theme.Warning

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun RequestCard(
    request: PermissionRequest,
    onRespondWithChoice: ((String, Int) -> Unit)?,
    onRespond: ((String, String) -> Unit)?,
    modifier: Modifier = Modifier,
    buttonsLocked: Boolean = false
) {
    Card(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surface
        ),
        shape = RoundedCornerShape(12.dp)
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            // Header: tool name, hostname, timer
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                // Tool name
                Text(
                    text = request.toolName,
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.primary
                )

                Row(verticalAlignment = Alignment.CenterVertically) {
                    // Hostname badge
                    if (!request.hostname.isNullOrEmpty()) {
                        Box(
                            modifier = Modifier
                                .background(Surface2, RoundedCornerShape(4.dp))
                                .padding(horizontal = 6.dp, vertical = 2.dp)
                        ) {
                            Text(
                                text = request.hostname,
                                style = MaterialTheme.typography.labelSmall,
                                color = TextDim,
                                fontSize = 11.sp
                            )
                        }
                        Spacer(modifier = Modifier.width(8.dp))
                    }

                    // Countdown timer (pending only)
                    if (request.isPending) {
                        CountdownTimer(request)
                    }
                }
            }

            Spacer(modifier = Modifier.height(8.dp))

            // Message
            Text(
                text = request.message,
                style = MaterialTheme.typography.bodyMedium.copy(
                    fontFamily = FontFamily.Monospace,
                    lineHeight = 20.sp
                ),
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 6,
                overflow = TextOverflow.Ellipsis
            )

            Spacer(modifier = Modifier.height(8.dp))

            // Action buttons or status
            if (request.isPending && (onRespondWithChoice != null || onRespond != null)) {
                val choices = request.choices
                if (!choices.isNullOrEmpty()) {
                    // Dynamic choice buttons
                    FlowRow(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        choices.forEachIndexed { index, choice ->
                            val lower = choice.text.lowercase()
                            val isDeny = lower.startsWith("no") || lower.startsWith("reject") || lower.startsWith("deny")
                            val buttonColor = if (isDeny) Danger else Success
                            val textColor = if (isDeny) Color.White else Color.Black
                            Button(
                                onClick = {
                                    onRespondWithChoice?.invoke(request.id, choice.number)
                                },
                                enabled = !buttonsLocked,
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = buttonColor,
                                    contentColor = textColor
                                ),
                            ) {
                                Text(
                                    text = choice.text,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                            }
                        }
                    }
                } else {
                    // Fallback: Approve / Deny
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Button(
                            onClick = { onRespond?.invoke(request.id, "allow") },
                            enabled = !buttonsLocked,
                            colors = ButtonDefaults.buttonColors(
                                containerColor = Success,
                                contentColor = Color.Black
                            ),
                            modifier = Modifier.weight(1f)
                        ) {
                            Text("Approve")
                        }
                        Button(
                            onClick = { onRespond?.invoke(request.id, "deny") },
                            enabled = !buttonsLocked,
                            colors = ButtonDefaults.buttonColors(containerColor = Danger),
                            modifier = Modifier.weight(1f)
                        ) {
                            Text("Deny")
                        }
                    }
                }
            } else {
                // Responded status
                // 選択肢テキストから色を決定（拒否系の先頭語なら赤、それ以外は緑）
                val chosenChoice = request.sendKey?.toIntOrNull()?.let { num ->
                    request.choices?.firstOrNull { it.number == num }
                }
                val chosenIsDeny = chosenChoice?.let {
                    val lower = it.text.lowercase()
                    lower.startsWith("no") || lower.startsWith("reject") || lower.startsWith("deny")
                } ?: (request.response == "deny")

                val statusText = when {
                    request.isCancelled -> "Cancelled"
                    request.isExpired -> "Expired"
                    chosenChoice != null -> chosenChoice.text
                    else -> ""
                }
                val statusColor = when {
                    request.isCancelled -> TextDim
                    request.isExpired -> Warning
                    chosenIsDeny -> Danger
                    else -> Success
                }
                Text(
                    text = statusText,
                    style = MaterialTheme.typography.labelLarge,
                    color = statusColor
                )
            }
        }
    }
}

@Composable
private fun CountdownTimer(request: PermissionRequest) {
    var remaining by remember(request.id) { mutableIntStateOf(request.remainingSeconds()) }

    LaunchedEffect(request.id) {
        while (remaining > 0) {
            delay(1000)
            remaining = request.remainingSeconds()
        }
    }

    val timerColor = when {
        remaining <= 30 -> Danger
        remaining <= 60 -> Warning
        else -> TextDim
    }

    Text(
        text = "${remaining}s",
        style = MaterialTheme.typography.labelSmall,
        color = timerColor,
        fontSize = 13.sp
    )
}
