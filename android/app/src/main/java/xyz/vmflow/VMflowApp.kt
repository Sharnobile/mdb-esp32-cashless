package xyz.vmflow

import android.app.Application

class VMflowApp : Application() {
    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    companion object {
        lateinit var instance: VMflowApp
            private set
    }
}
