package net.ainyan.promptrelay.data.remote

import kotlinx.serialization.Serializable
import net.ainyan.promptrelay.data.model.PermissionRequest
import okhttp3.ResponseBody
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.POST
import retrofit2.http.Path

interface PromptRelayApi {

    @GET("health")
    suspend fun healthCheck(): ResponseBody

    @GET("permission-requests")
    suspend fun getRequests(): List<PermissionRequest>

    @POST("permission-request/{id}/respond")
    suspend fun respondWithChoice(
        @Path("id") id: String,
        @Body body: ChoiceResponse
    ): ResponseBody

    @POST("permission-request/{id}/respond")
    suspend fun respond(
        @Path("id") id: String,
        @Body body: LegacyResponse
    ): ResponseBody

    @POST("unregister")
    suspend fun unregister(@Body body: UnregisterRequest): ResponseBody
}

@Serializable
data class ChoiceResponse(val choice: Int, val source: String = "android-app")

@Serializable
data class LegacyResponse(val response: String, val source: String = "android-app")

@Serializable
data class UnregisterRequest(val token: String)
