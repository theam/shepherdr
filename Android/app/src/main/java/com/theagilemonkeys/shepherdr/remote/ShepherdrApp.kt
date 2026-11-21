package com.theagilemonkeys.shepherdr.remote

import android.app.Application
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import com.theagilemonkeys.shepherdr.remote.relay.RelayClient
import com.theagilemonkeys.shepherdr.remote.ui.Navigator

/** One connection and one navigation for the whole app, which survive the activity being recreated. */
class ShepherdrApp : Application() {
    lateinit var client: RelayClient
        private set
    val navigator = Navigator()

    override fun onCreate() {
        super.onCreate()
        client = RelayClient(this)
        // The connection lives while the app is in front, and comes back when it returns.
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStart(owner: LifecycleOwner) = client.start()
            override fun onStop(owner: LifecycleOwner) = client.suspend()
        })
    }
}
