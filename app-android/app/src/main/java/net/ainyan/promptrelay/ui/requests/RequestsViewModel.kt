package net.ainyan.promptrelay.ui.requests

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import net.ainyan.promptrelay.data.model.PermissionRequest
import net.ainyan.promptrelay.data.remote.ApiClient
import net.ainyan.promptrelay.data.remote.ChoiceResponse
import net.ainyan.promptrelay.data.remote.LegacyResponse
import net.ainyan.promptrelay.service.WebSocketService

class RequestsViewModel(application: Application) : AndroidViewModel(application) {

    val requests: StateFlow<List<PermissionRequest>> = WebSocketService.requests

    fun respondWithChoice(requestId: String, choiceNumber: Int) {
        viewModelScope.launch {
            try {
                val api = WebSocketService.getApi() ?: return@launch
                api.respondWithChoice(requestId, ChoiceResponse(choiceNumber))
                WebSocketService.refreshIfPolling()
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    fun respond(requestId: String, response: String) {
        viewModelScope.launch {
            try {
                val api = WebSocketService.getApi() ?: return@launch
                api.respond(requestId, LegacyResponse(response))
                WebSocketService.refreshIfPolling()
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }
}
