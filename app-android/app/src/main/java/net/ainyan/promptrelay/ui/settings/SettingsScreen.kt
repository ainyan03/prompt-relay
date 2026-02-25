package net.ainyan.promptrelay.ui.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import net.ainyan.promptrelay.service.WebSocketManager
import net.ainyan.promptrelay.service.WebSocketService
import net.ainyan.promptrelay.ui.theme.Danger
import net.ainyan.promptrelay.ui.theme.Success
import net.ainyan.promptrelay.ui.theme.TextDim
import net.ainyan.promptrelay.ui.theme.Warning

@Composable
fun SettingsScreen(
    modifier: Modifier = Modifier,
    viewModel: SettingsViewModel = viewModel()
) {
    val editServerUrl by viewModel.editServerUrl.collectAsStateWithLifecycle()
    val editApiKey by viewModel.editApiKey.collectAsStateWithLifecycle()
    val connectionState by WebSocketService.connectionState.collectAsStateWithLifecycle()
    val connectionEnabled by viewModel.connectionEnabled.collectAsStateWithLifecycle()

    val (statusText, statusColor) = when (connectionState) {
        is WebSocketManager.ConnectionState.Connected -> "接続済み" to Success
        is WebSocketManager.ConnectionState.Connecting -> "接続中…" to Warning
        is WebSocketManager.ConnectionState.Disconnected -> "未接続" to Danger
        is WebSocketManager.ConnectionState.Error ->
            "エラー: ${(connectionState as WebSocketManager.ConnectionState.Error).message}" to Danger
    }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp)
    ) {
        // ステータス
        Text(
            text = "ステータス",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface
        )
        Spacer(modifier = Modifier.height(4.dp))
        Text(
            text = statusText,
            style = MaterialTheme.typography.bodyLarge,
            color = statusColor
        )

        Spacer(modifier = Modifier.height(24.dp))

        // 接続設定
        Text(
            text = "接続設定",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface
        )
        Spacer(modifier = Modifier.height(8.dp))
        OutlinedTextField(
            value = editServerUrl,
            onValueChange = viewModel::onServerUrlChange,
            modifier = Modifier.fillMaxWidth(),
            label = { Text("サーバ URL") },
            placeholder = { Text("http://192.168.x.x:3939") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri)
        )
        Spacer(modifier = Modifier.height(8.dp))

        val apiKeyError = when {
            editApiKey.isEmpty() -> "API Key を入力してください"
            editApiKey.length < 8 -> "API Key は 8 文字以上で入力してください (${editApiKey.length}文字)"
            editApiKey.length > 128 -> "API Key は 128 文字以下で入力してください"
            else -> null
        }

        OutlinedTextField(
            value = editApiKey,
            onValueChange = viewModel::onApiKeyChange,
            modifier = Modifier.fillMaxWidth(),
            label = { Text("API Key (8〜128文字)") },
            placeholder = { Text("API Key") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            isError = apiKeyError != null
        )
        if (apiKeyError != null) {
            Text(
                text = apiKeyError,
                style = MaterialTheme.typography.bodySmall,
                color = Danger
            )
        }
        Spacer(modifier = Modifier.height(12.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = "接続",
                style = MaterialTheme.typography.bodyLarge,
                modifier = Modifier.weight(1f)
            )
            Switch(
                checked = connectionEnabled,
                onCheckedChange = { enabled ->
                    if (enabled && apiKeyError != null) return@Switch
                    viewModel.setConnectionEnabled(enabled)
                }
            )
        }
        if (connectionState is WebSocketManager.ConnectionState.Error) {
            val errorMsg = (connectionState as WebSocketManager.ConnectionState.Error).message
            Text(
                text = errorMsg,
                style = MaterialTheme.typography.bodySmall,
                color = Danger
            )
        }

    }
}
