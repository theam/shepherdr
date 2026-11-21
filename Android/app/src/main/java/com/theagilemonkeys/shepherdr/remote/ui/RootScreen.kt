package com.theagilemonkeys.shepherdr.remote.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.theagilemonkeys.shepherdr.remote.protocol.Herd
import com.theagilemonkeys.shepherdr.remote.relay.RelayClient
import com.theagilemonkeys.shepherdr.remote.ui.arcade.ArcadePopups
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop

@Composable
fun RootScreen(client: RelayClient, navigator: Navigator) {
    Box(Modifier.fillMaxSize().background(Theme.background).statusBarsPadding()) {
        if (client.mac == null) {
            PairScreen(client)
        } else {
            when (val screen = navigator.stack.lastOrNull()) {
                null -> QueueScreen(client, navigator)
                is Screen.Session -> androidx.compose.runtime.key(screen.session) {
                    SessionScreen(client, screen, onBack = { navigator.pop() })
                }
                Screen.Compass -> CompassScreen(client, navigator)
            }
            ArcadePopups(client.arcade, Modifier.align(Alignment.TopCenter).padding(top = 54.dp))
        }
    }

    BackHandler(enabled = client.mac != null && navigator.stack.isNotEmpty()) { navigator.pop() }

    // A game that ends shows how it went, wherever you were.
    LaunchedEffect(Unit) {
        snapshotFlow { client.arcade.game?.outcome }.distinctUntilChanged().drop(1).collect { outcome ->
            if (outcome == null) return@collect
            client.arcade.showHerdMode(true)
            navigator.reset()
        }
    }

    // A session a link asked for opens once the queue shows it; a game a launch asked for starts
    // once the queue has sessions astray.
    LaunchedEffect(client.pendingSession, client.queue, navigator.startsHerd) {
        val session = client.pendingSession
        val row = session?.let { s -> client.queue?.rows?.firstOrNull { it.session == s } }
        if (session != null && row != null) {
            client.pendingSession = null
            navigator.reset(Screen.Session(row, session))
        }
        val rows = client.queue?.rows
        if (navigator.startsHerd && rows != null && Herd.strays(rows).isNotEmpty()) {
            navigator.startsHerd = false
            if (!client.arcade.isPlaying) client.arcade.start(rows)
        }
    }
}
