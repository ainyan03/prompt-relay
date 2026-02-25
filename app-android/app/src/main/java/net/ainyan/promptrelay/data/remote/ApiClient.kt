package net.ainyan.promptrelay.data.remote

import com.jakewharton.retrofit2.converter.kotlinx.serialization.asConverterFactory
import kotlinx.serialization.json.Json
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Response
import retrofit2.Retrofit
import java.util.concurrent.TimeUnit

object ApiClient {

    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
    }

    private var currentBaseUrl: String = ""
    private var currentApiKey: String = ""
    private var retrofit: Retrofit? = null
    private var api: PromptRelayApi? = null

    val okHttpClient: OkHttpClient = OkHttpClient.Builder()
        .pingInterval(25, TimeUnit.SECONDS) // WebSocket キープアライブ間隔
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        .addInterceptor(AuthInterceptor())
        .build()

    fun getApi(baseUrl: String, apiKey: String): PromptRelayApi {
        if (baseUrl != currentBaseUrl || apiKey != currentApiKey || api == null) {
            currentBaseUrl = baseUrl
            currentApiKey = apiKey

            val url = if (baseUrl.endsWith("/")) baseUrl else "$baseUrl/"

            retrofit = Retrofit.Builder()
                .baseUrl(url)
                .client(okHttpClient)
                .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
                .build()

            api = retrofit!!.create(PromptRelayApi::class.java)
        }
        return api!!
    }

    private class AuthInterceptor : Interceptor {
        override fun intercept(chain: Interceptor.Chain): Response {
            val request = chain.request()
            val newRequest = if (currentApiKey.isNotEmpty()) {
                request.newBuilder()
                    .header("Authorization", "Bearer $currentApiKey")
                    .build()
            } else {
                request
            }
            return chain.proceed(newRequest)
        }
    }
}
