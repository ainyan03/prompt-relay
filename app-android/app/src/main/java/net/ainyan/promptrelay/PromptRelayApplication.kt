package net.ainyan.promptrelay

import android.app.Application
import net.ainyan.promptrelay.data.preferences.SettingsDataStore
import net.ainyan.promptrelay.notification.NotificationHelper

class PromptRelayApplication : Application() {

    lateinit var settingsDataStore: SettingsDataStore
        private set

    lateinit var notificationHelper: NotificationHelper
        private set

    override fun onCreate() {
        super.onCreate()
        instance = this
        settingsDataStore = SettingsDataStore(this)
        notificationHelper = NotificationHelper(this)
        notificationHelper.createChannels()
    }

    companion object {
        lateinit var instance: PromptRelayApplication
            private set
    }
}
