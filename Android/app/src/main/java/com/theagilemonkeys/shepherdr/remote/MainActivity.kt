package com.theagilemonkeys.shepherdr.remote

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.theagilemonkeys.shepherdr.remote.protocol.PairingInvite
import com.theagilemonkeys.shepherdr.remote.protocol.RemoteSessionID
import com.theagilemonkeys.shepherdr.remote.protocol.SessionLink
import com.theagilemonkeys.shepherdr.remote.ui.RootScreen
import com.theagilemonkeys.shepherdr.remote.ui.Screen
import com.theagilemonkeys.shepherdr.remote.ui.ShepherdrTheme

class MainActivity : ComponentActivity() {
    private val app get() = application as ShepherdrApp

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
        )
        super.onCreate(savedInstanceState)
        setContent {
            ShepherdrTheme { RootScreen(app.client, app.navigator) }
        }
        if (savedInstanceState == null) handle(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    /**
     * Links, and launch extras for tests on an emulator, where nobody taps:
     * `--es pairInvite <link>` pairs, `--es openSession <machine>/<terminal>` opens that session once
     * the queue shows it, `--ez openCompass true` opens Compass, `--ez herdStart true` starts a game.
     */
    private fun handle(intent: Intent?) {
        intent ?: return
        val client = app.client
        val navigator = app.navigator
        intent.dataString?.let { link ->
            PairingInvite.parse(link)?.let { client.pair(it) }
                ?: SessionLink.session(link)?.let { client.pendingSession = it }
        }
        intent.getStringExtra("pairInvite")?.let { link ->
            if (client.mac == null) PairingInvite.parse(link)?.let { client.pair(it) }
        }
        intent.getStringExtra("openSession")?.let { open ->
            val slash = open.indexOf('/')
            if (slash > 0) client.pendingSession = RemoteSessionID(open.substring(0, slash), open.substring(slash + 1))
        }
        if (intent.getBooleanExtra("openCompass", false)) navigator.push(Screen.Compass)
        if (intent.getBooleanExtra("herdStart", false)) navigator.startsHerd = true
    }
}
