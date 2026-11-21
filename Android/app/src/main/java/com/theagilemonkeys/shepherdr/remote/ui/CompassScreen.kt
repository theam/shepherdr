package com.theagilemonkeys.shepherdr.remote.ui

import android.annotation.SuppressLint
import android.content.Intent
import android.graphics.Color as AndroidColor
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.theagilemonkeys.shepherdr.remote.protocol.RemoteCompass
import com.theagilemonkeys.shepherdr.remote.relay.RelayClient

/**
 * Compass on the phone: what its agent is doing, a run now, any day's page, and the agent's
 * terminal. The page's buttons stay on the Mac, which fills them in.
 */
@Composable
fun CompassScreen(client: RelayClient, navigator: Navigator) {
    /** The day shown; null for today. */
    var day by rememberSaveable { mutableStateOf<String?>(null) }
    var showsDays by remember { mutableStateOf(false) }
    val compass = client.queue?.compass
    val connected = client.phase == RelayClient.Phase.Connected

    // What the page depends on: the day, today's last change, and being connected.
    LaunchedEffect(day, if (day == null) compass?.pageModified else null, connected) {
        if (connected) client.requestCompassPage(day)
    }

    Column(Modifier.fillMaxSize().background(Theme.background)) {
        ScreenBar(onBack = { navigator.pop() }, actions = {
            if (compass != null && compass.days.isNotEmpty()) {
                Box {
                    IconButton(onClick = { showsDays = true }) {
                        Icon(Icons.Filled.CalendarMonth, contentDescription = "Show another day", tint = Theme.phosphor)
                    }
                    DropdownMenu(expanded = showsDays, onDismissRequest = { showsDays = false }, containerColor = Theme.raised) {
                        DropdownMenuItem(text = { Text("Today") }, onClick = { day = null; showsDays = false })
                        for (other in compass.days.filter { it != compass.today }) {
                            DropdownMenuItem(text = { Text(other) }, onClick = { day = other; showsDays = false })
                        }
                    }
                }
            }
        }) {
            Text(day?.let { "COMPASS · $it" } ?: "COMPASS", style = Theme.mono(13f, FontWeight.SemiBold, 2.sp), color = Theme.text, maxLines = 1)
        }
        if (compass == null) {
            Unavailable("Compass isn't set up", "Set it up on the Mac, in Shepherdr's COMPASS tab.")
        } else {
            Status(client, compass, navigator)
            Page(client, compass, day)
        }
    }
}

@Composable
private fun Status(client: RelayClient, compass: RemoteCompass, navigator: Navigator) {
    Column(
        Modifier.fillMaxWidth().background(Theme.panel).padding(horizontal = 14.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(compass.activity, style = Theme.mono(12f), color = compassColor(compass))
        Text(compass.next, style = Theme.mono(11f), color = Theme.dim)
        compass.problem?.let { Text(it, style = Theme.mono(11f), color = Theme.amber) }
        Row(Modifier.padding(top = 2.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ConsoleButton(
                "RUN", onClick = { client.runCompass() }, color = Theme.phosphor, filled = true, enabled = !compass.isRunning,
                leading = { Icon(Icons.Filled.PlayArrow, contentDescription = null, tint = if (compass.isRunning) Theme.faint else Theme.background, modifier = Modifier.size(16.dp)) },
            )
            if (compass.isRunning && !compass.needsYou) ConsoleButton("Cancel Run", onClick = { client.cancelCompassRun() })
            Spacer(Modifier.weight(1f))
            val agent = compass.agent
            val session = agent?.session
            if (agent != null && session != null) {
                val color = if (compass.needsYou) Theme.amber else Theme.dim
                ConsoleButton(
                    "Agent", onClick = { navigator.push(Screen.Session(agent, session)) }, color = color,
                    leading = { Icon(Icons.Filled.Terminal, contentDescription = null, tint = color, modifier = Modifier.size(16.dp)) },
                )
            }
        }
    }
}

@Composable
private fun Page(client: RelayClient, compass: RemoteCompass, day: String?) {
    val wanted = day ?: compass.today
    val page = client.compassPage
    when {
        page == null || page.day != wanted -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = Theme.dim)
        }
        page.html == null -> Unavailable(
            if (day == null) "No page yet today" else "No page that day",
            if (day == null) "Run Compass to write today's page." else "",
        )
        else -> CompassPageView(page.html, Modifier.fillMaxSize().navigationBarsPadding())
    }
}

@Composable
private fun Unavailable(title: String, description: String) {
    Column(Modifier.fillMaxSize().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Text(title, style = Theme.mono(16f, FontWeight.SemiBold), color = Theme.dim, textAlign = TextAlign.Center)
        if (description.isNotEmpty()) {
            Text(description, style = Theme.mono(12f), color = Theme.faint, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 8.dp))
        }
    }
}

/**
 * The page as HTML, fitted to the phone. Links open in the browser; the page's own buttons need
 * the Mac and do nothing here.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun CompassPageView(html: String, modifier: Modifier) {
    var loaded by remember { mutableStateOf<String?>(null) }
    AndroidView(
        factory = { context ->
            WebView(context).apply {
                setBackgroundColor(AndroidColor.rgb(0x09, 0x0C, 0x0A))
                settings.javaScriptEnabled = true
                settings.allowFileAccess = false
                settings.allowContentAccess = false
                // A page written for the Mac's column may not say how wide it is: lay it out at the phone's width.
                settings.useWideViewPort = false
                webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                        val url = request.url
                        if (url.scheme?.lowercase() in listOf("http", "https")) {
                            runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, url)) }
                        }
                        return true
                    }
                }
            }
        },
        update = { view ->
            if (loaded != html) {
                loaded = html
                view.loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
            }
        },
        modifier = modifier,
    )
}
