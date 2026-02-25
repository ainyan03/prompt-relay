package net.ainyan.promptrelay.ui.requests

import android.content.res.Configuration
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.delay
import net.ainyan.promptrelay.data.model.PermissionRequest

@Composable
fun RequestsScreen(
    modifier: Modifier = Modifier,
    viewModel: RequestsViewModel = viewModel()
) {
    val requests by viewModel.requests.collectAsStateWithLifecycle()

    val pending = requests.filter { it.isPending }
    val responded = requests.filter { !it.isPending }

    val pendingIds = remember(pending) { pending.map { it.id }.toSet() }
    var buttonsLocked by remember { mutableStateOf(false) }
    var initialized by remember { mutableStateOf(false) }

    // アニメーション管理
    // displayedPendingIds: pending セクションに表示する ID（退出アニメーション中含む）
    // animatedInIds: 入場アニメーション済みの ID（各アイテムの初回描画時に追加）
    var displayedPendingIds by remember { mutableStateOf(pendingIds) }
    var animatedInIds by remember { mutableStateOf(emptySet<String>()) }

    LaunchedEffect(pendingIds) {
        // 新規 pending を表示リストに即追加
        displayedPendingIds = displayedPendingIds + pendingIds

        // ボタンロック: 新規アイテムが追加され、かつ既存アイテムがある場合
        val newIds = pendingIds - animatedInIds
        if (newIds.isNotEmpty() && initialized && (pendingIds - newIds).isNotEmpty()) {
            buttonsLocked = true
            delay(300)
            buttonsLocked = false
        }
        initialized = true
    }

    // 退出アニメーション完了後にクリーンアップ
    val removingIds = displayedPendingIds - pendingIds
    LaunchedEffect(removingIds) {
        if (removingIds.isNotEmpty()) {
            delay(300)
            displayedPendingIds = displayedPendingIds - removingIds
            animatedInIds = animatedInIds - removingIds
        }
    }

    // pending セクションに表示するリクエスト（現在の pending + 退出アニメーション中）
    val displayedPending = requests.filter { it.id in displayedPendingIds }

    val isLandscape = LocalConfiguration.current.orientation == Configuration.ORIENTATION_LANDSCAPE

    if (displayedPending.isEmpty() && responded.isEmpty()) {
        Box(
            modifier = modifier.fillMaxSize(),
            contentAlignment = Alignment.Center
        ) {
            Text(
                text = "リクエストなし",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    } else if (isLandscape) {
        // 横向き: 左に承認待ち、右に履歴
        Row(modifier = modifier.fillMaxSize()) {
            if (displayedPending.isNotEmpty()) {
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .verticalScroll(rememberScrollState())
                ) {
                    SectionHeader("承認待ち (${pending.size})")
                    PendingItems(
                        displayedPending = displayedPending,
                        removingIds = removingIds,
                        animatedInIds = animatedInIds,
                        initialized = initialized,
                        buttonsLocked = buttonsLocked,
                        onAnimatedIn = { id -> animatedInIds = animatedInIds + id },
                        onRespondWithChoice = viewModel::respondWithChoice,
                        onRespond = viewModel::respond
                    )
                }
                VerticalDivider(modifier = Modifier.fillMaxHeight())
            }

            LazyColumn(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight()
            ) {
                item {
                    SectionHeader("履歴")
                }
                items(responded, key = { it.id }) { request ->
                    RequestCard(
                        request = request,
                        onRespondWithChoice = null,
                        onRespond = null,
                        modifier = Modifier.animateItem()
                    )
                }
            }
        }
    } else {
        // 縦向き: 上に承認待ち固定、下に履歴スクロール
        Column(modifier = modifier.fillMaxSize()) {
            if (displayedPending.isNotEmpty()) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .verticalScroll(rememberScrollState())
                ) {
                    SectionHeader("承認待ち (${pending.size})")
                    PendingItems(
                        displayedPending = displayedPending,
                        removingIds = removingIds,
                        animatedInIds = animatedInIds,
                        initialized = initialized,
                        buttonsLocked = buttonsLocked,
                        onAnimatedIn = { id -> animatedInIds = animatedInIds + id },
                        onRespondWithChoice = viewModel::respondWithChoice,
                        onRespond = viewModel::respond
                    )
                }
                HorizontalDivider()
            }

            LazyColumn(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
            ) {
                item {
                    SectionHeader("履歴")
                }
                items(responded, key = { it.id }) { request ->
                    RequestCard(
                        request = request,
                        onRespondWithChoice = null,
                        onRespond = null,
                        modifier = Modifier.animateItem()
                    )
                }
            }
        }
    }
}

/** pending セクション内のカード描画（入場・退場アニメーション付き） */
@Composable
private fun PendingItems(
    displayedPending: List<PermissionRequest>,
    removingIds: Set<String>,
    animatedInIds: Set<String>,
    initialized: Boolean,
    buttonsLocked: Boolean,
    onAnimatedIn: (String) -> Unit,
    onRespondWithChoice: (String, Int) -> Unit,
    onRespond: (String, String) -> Unit
) {
    displayedPending.forEachIndexed { index, request ->
        val isNew = initialized && request.id !in animatedInIds
        val isExiting = request.id in removingIds
        key(request.id) {
            // 入場アニメーション済みとしてマーク
            LaunchedEffect(Unit) {
                onAnimatedIn(request.id)
            }

            val visibleState = remember {
                if (isNew) MutableTransitionState(false).apply { targetState = true }
                else MutableTransitionState(true)
            }
            if (!isNew) {
                visibleState.targetState = !isExiting
            }
            AnimatedVisibility(
                visibleState = visibleState,
                enter = expandVertically(
                    expandFrom = Alignment.Top,
                    animationSpec = tween(250)
                ) + fadeIn(animationSpec = tween(250)),
                exit = shrinkVertically(
                    shrinkTowards = Alignment.Top,
                    animationSpec = tween(250)
                ) + fadeOut(animationSpec = tween(250)),
            ) {
                RequestCard(
                    request = request,
                    onRespondWithChoice = if (!isExiting) onRespondWithChoice else null,
                    onRespond = if (!isExiting) onRespond else null,
                    buttonsLocked = buttonsLocked
                )
            }
        }
        if (index < displayedPending.lastIndex) {
            HorizontalDivider(modifier = Modifier.padding(horizontal = 12.dp))
        }
    }
}

@Composable
private fun SectionHeader(title: String) {
    Text(
        text = title,
        style = MaterialTheme.typography.titleMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)
    )
}
