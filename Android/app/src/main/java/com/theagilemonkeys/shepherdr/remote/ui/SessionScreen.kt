package com.theagilemonkeys.shepherdr.remote.ui

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.ArrowCircleUp
import androidx.compose.material.icons.filled.FormatSize
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.theagilemonkeys.shepherdr.remote.dictation.Dictation
import com.theagilemonkeys.shepherdr.remote.protocol.QueueRow
import com.theagilemonkeys.shepherdr.remote.protocol.RemotePane
import com.theagilemonkeys.shepherdr.remote.protocol.RemoteResource
import com.theagilemonkeys.shepherdr.remote.protocol.RemoteTerminalState
import com.theagilemonkeys.shepherdr.remote.relay.RelayClient
import com.theagilemonkeys.shepherdr.remote.relay.RemoteTerminal
import com.theagilemonkeys.shepherdr.remote.terminal.RemoteTerminalView
import kotlinx.coroutines.launch

/**
 * One session: a pane of its Herdr tab at a time, fitted to the phone, with keys and a composer
 * for prompts you type or dictate.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionScreen(client: RelayClient, link: Screen.Session, onBack: () -> Unit) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("shepherdr", Context.MODE_PRIVATE) }
    var fontSize by remember { mutableFloatStateOf(prefs.getFloat(FONT_KEY, 11f)) }
    var paneID by rememberSaveable { mutableStateOf<String?>(null) }
    var showsResources by remember { mutableStateOf(false) }
    var showsTextMenu by remember { mutableStateOf(false) }

    // The row as the queue shows it now, which may have gained or lost panes; Compass's agent is outside the queue.
    val row: QueueRow = client.queue?.rows?.firstOrNull { it.session == link.session }
        ?: client.queue?.compass?.agent?.takeIf { it.session == link.session }
        ?: link.row
    val panes = row.panes.ifEmpty { listOf(RemotePane(link.session, row.title, row.kind == QueueRow.Kind.Session)) }
    val pane = panes.firstOrNull { it.id == paneID } ?: panes.firstOrNull { it.pane == link.session } ?: panes[0]

    // A terminal per pane shown, released when it goes.
    val terminal = remember(pane.pane) { client.terminal(pane.pane) }
    DisposableEffect(terminal) { onDispose { client.release(terminal) } }

    // In herd mode, a session you closed with `exit` takes you back to the game.
    LaunchedEffect(client.queue) {
        val queue = client.queue ?: return@LaunchedEffect
        if (client.arcade.isPlaying && queue.rows.none { it.session == link.session } && queue.compass?.agent?.session != link.session) onBack()
    }

    fun setFont(size: Float) {
        fontSize = size
        prefs.edit().putFloat(FONT_KEY, size).apply()
    }

    Column(Modifier.fillMaxSize().background(Theme.background).imePadding()) {
        ScreenBar(onBack = onBack, actions = {
            if (row.resources.isNotEmpty()) {
                IconButton(onClick = { showsResources = true }) {
                    Icon(Icons.AutoMirrored.Filled.List, contentDescription = "Resources", tint = Theme.phosphor)
                }
            }
            Box {
                IconButton(onClick = { showsTextMenu = true }) {
                    Icon(Icons.Filled.FormatSize, contentDescription = "Text size", tint = Theme.phosphor)
                }
                DropdownMenu(expanded = showsTextMenu, onDismissRequest = { showsTextMenu = false }, containerColor = Theme.raised) {
                    DropdownMenuItem(text = { Text("Larger Text") }, onClick = { setFont(minOf(18f, fontSize + 1)) })
                    DropdownMenuItem(text = { Text("Smaller Text") }, onClick = { setFont(maxOf(7f, fontSize - 1)) })
                }
            }
        }) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(row.title, style = Theme.mono(13f, FontWeight.SemiBold), color = Theme.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    listOfNotNull(Theme.label(row.status), row.machine).filter { it.isNotEmpty() }.joinToString(" · "),
                    style = Theme.mono(9.5f), color = Theme.color(row.status), maxLines = 1,
                )
            }
        }
        if (panes.size > 1) {
            SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 6.dp)) {
                panes.forEachIndexed { index, item ->
                    SegmentedButton(
                        selected = item.id == pane.id, onClick = { paneID = item.id },
                        shape = SegmentedButtonDefaults.itemShape(index, panes.size),
                        colors = SegmentedButtonDefaults.colors(
                            activeContainerColor = Theme.raised, activeContentColor = Theme.phosphor,
                            inactiveContainerColor = Theme.background, inactiveContentColor = Theme.dim,
                            activeBorderColor = Theme.line, inactiveBorderColor = Theme.line,
                        ),
                        icon = {},
                    ) { Text(item.title, style = Theme.mono(11f), maxLines = 1, overflow = TextOverflow.Ellipsis) }
                }
            }
        }
        key(pane.id) {
            TerminalPanel(terminal, fontSize, Modifier.weight(1f).fillMaxWidth())
        }
        Keys(terminal)
        Composer(client, pane, Modifier.navigationBarsPadding())
    }

    if (showsResources) ResourcesSheet(row.title, row.resources) { showsResources = false }
    client.notice?.let { notice ->
        AlertDialog(
            onDismissRequest = { client.notice = null },
            title = { Text("Shepherdr") },
            text = { Text(notice) },
            confirmButton = { TextButton(onClick = { client.notice = null }) { Text("OK", color = Theme.phosphor) } },
            containerColor = Theme.panel,
        )
    }
}

private const val FONT_KEY = "terminalFontSize"

/** A pane's live terminal, at the phone's size: the phone controls it while it shows it. */
@Composable
private fun TerminalPanel(terminal: RemoteTerminal, fontSize: Float, modifier: Modifier) {
    Box(modifier.background(Theme.background)) {
        AndroidView(
            factory = { context -> RemoteTerminalView(context).apply { this.fontSize = fontSize; attach(terminal) } },
            update = { it.fontSize = fontSize },
            onRelease = { it.detach() },
            modifier = Modifier.fillMaxSize().padding(horizontal = 4.dp).clipToBounds(),
        )
        Banner(terminal, Modifier.align(Alignment.TopCenter))
    }
}

@Composable
private fun Banner(terminal: RemoteTerminal, modifier: Modifier) {
    when (terminal.state) {
        RemoteTerminalState.Connecting -> Row(
            modifier.padding(8.dp).background(Theme.panel.copy(alpha = 0.9f), RoundedCornerShape(50)).padding(8.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            CircularProgressIndicator(Modifier.size(14.dp), color = Theme.dim, strokeWidth = 2.dp)
            Text("Attaching…", style = Theme.mono(11f), color = Theme.dim)
        }
        RemoteTerminalState.ControlledElsewhere -> Row(
            modifier.padding(8.dp).background(Theme.panel.copy(alpha = 0.95f), RoundedCornerShape(8.dp)).padding(8.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("Another client controls this pane. You're watching.", style = Theme.mono(11f), color = Theme.amber, modifier = Modifier.weight(1f, fill = false))
            ConsoleButton("TAKE OVER", onClick = { terminal.takeOver() }, color = Theme.amber)
        }
        RemoteTerminalState.Ended, RemoteTerminalState.Failed -> Text(
            terminal.message ?: "The terminal ended.", style = Theme.mono(11f), color = Theme.amber,
            modifier = modifier.padding(8.dp).background(Theme.panel.copy(alpha = 0.95f), RoundedCornerShape(8.dp)).padding(8.dp),
        )
        RemoteTerminalState.Control, RemoteTerminalState.Observing -> {}
    }
}

// Keys

@Composable
private fun Keys(terminal: RemoteTerminal) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(Theme.panel)
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        val keys = listOf(
            "esc" to "\u001b", "⇧⏎" to "\u001b\r", "↑" to "\u001b[A", "↓" to "\u001b[B", "←" to "\u001b[D", "→" to "\u001b[C",
            "tab" to "\t", "^C" to "\u0003", "1" to "1", "2" to "2", "3" to "3", "⏎" to "\r",
        )
        for ((label, bytes) in keys) Key(label) { terminal.input(bytes.toByteArray()) }
        Key("⇞") { terminal.scroll(up = true, lines = 10) }
        Key("⇟") { terminal.scroll(up = false, lines = 10) }
    }
}

@Composable
private fun Key(label: String, onClick: () -> Unit) {
    Box(
        Modifier
            .widthIn(min = 38.dp)
            .background(Theme.raised, RoundedCornerShape(6.dp))
            .border(1.dp, Theme.line, RoundedCornerShape(6.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 7.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = Theme.mono(12f, FontWeight.Medium), color = Theme.text)
    }
}

// Composer

@Composable
private fun Composer(client: RelayClient, pane: RemotePane, modifier: Modifier) {
    val context = LocalContext.current
    val focus = LocalFocusManager.current
    val scope = rememberCoroutineScope()
    var draft by rememberSaveable { mutableStateOf("") }
    val dictation = remember { Dictation(context) }
    DisposableEffect(dictation) { onDispose { dictation.cancel() } }
    val microphone = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) dictation.start()
    }

    fun toggleDictation() {
        if (dictation.isRecording || dictation.state is Dictation.State.Preparing) {
            scope.launch {
                val text = dictation.stop()
                if (text.isNotEmpty()) {
                    val separator = if (draft.isEmpty() || draft.endsWith(" ") || draft.endsWith("\n")) "" else " "
                    draft += separator + text
                }
            }
        } else if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            dictation.start()
        } else {
            microphone.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    fun send() {
        val text = draft.trim()
        if (text.isEmpty()) return
        client.prompt(text, pane.pane)
        draft = ""
        focus.clearFocus()
    }

    val empty = draft.isBlank()
    Column(
        modifier.fillMaxWidth().background(Theme.panel).padding(start = 10.dp, end = 10.dp, top = 6.dp, bottom = 8.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        when (val state = dictation.state) {
            is Dictation.State.Failed -> Text(state.message, style = Theme.mono(11f), color = Theme.amber)
            is Dictation.State.Preparing -> Text(state.message, style = Theme.mono(11f), color = Theme.dim)
            else -> {}
        }
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.weight(1f).background(Theme.raised, RoundedCornerShape(8.dp)).padding(8.dp)) {
                if (draft.isEmpty()) {
                    Text(
                        if (dictation.isRecording && dictation.volatile.isNotEmpty()) dictation.volatile else "Prompt for ${pane.title}…",
                        style = Theme.mono(13f), color = if (dictation.isRecording) Theme.dim else Theme.faint, maxLines = 6,
                    )
                }
                BasicTextField(
                    draft, { draft = it },
                    textStyle = Theme.mono(13f).copy(color = Theme.text),
                    cursorBrush = SolidColor(Theme.phosphor),
                    maxLines = 6,
                    modifier = Modifier.fillMaxWidth().heightIn(max = 140.dp).verticalScroll(rememberScrollState()),
                )
            }
            IconButton(onClick = { toggleDictation() }, modifier = Modifier.size(40.dp)) {
                Icon(
                    if (dictation.isRecording) Icons.Filled.StopCircle else Icons.Filled.Mic,
                    contentDescription = if (dictation.isRecording) "Stop Dictation" else "Dictate",
                    tint = if (dictation.isRecording) Theme.red else Theme.amber,
                )
            }
            IconButton(onClick = { send() }, enabled = !empty, modifier = Modifier.size(40.dp)) {
                Icon(Icons.Filled.ArrowCircleUp, contentDescription = "Send", tint = if (empty) Theme.faint else Theme.phosphor, modifier = Modifier.size(30.dp))
            }
        }
        if (dictation.isRecording) {
            Text(dictation.volatile.ifEmpty { "Listening…" }, style = Theme.mono(11f), color = Theme.dim, maxLines = 3, overflow = TextOverflow.Ellipsis)
        }
    }
}

// Resources

/** A session's resources, as the Mac's Resources column lists them: tap one to open it in the browser. */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun ResourcesSheet(title: String, resources: List<RemoteResource>, onDismiss: () -> Unit) {
    val context = LocalContext.current
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Theme.panel) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp)) {
            Text(title, style = Theme.mono(15f, FontWeight.SemiBold), color = Theme.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            for (kind in RemoteResource.Kind.entries) {
                val items = resources.filter { it.kind == kind }
                if (items.isEmpty()) continue
                SectionTitle(kindTitle(kind))
                for (resource in items) {
                    ResourceRow(
                        resource,
                        Modifier.combinedClickable(
                            onClick = { runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(resource.url))) } },
                            onLongClick = {
                                context.getSystemService(ClipboardManager::class.java)
                                    ?.setPrimaryClip(ClipData.newPlainText(resource.name, resource.url))
                            },
                        ),
                    )
                }
            }
            Text("Long-press a link to copy it.", style = Theme.mono(10f), color = Theme.faint, modifier = Modifier.padding(top = 12.dp))
        }
    }
}

private fun kindTitle(kind: RemoteResource.Kind) = when (kind) {
    RemoteResource.Kind.PullRequest -> "Pull requests"
    RemoteResource.Kind.Issue -> "Issues"
    RemoteResource.Kind.Artifact -> "Claude artifacts"
    RemoteResource.Kind.Link -> "Links"
    RemoteResource.Kind.Repository -> "Repository"
}

@Composable
private fun ResourceRow(resource: RemoteResource, modifier: Modifier) {
    val glyph = when (resource.kind) {
        RemoteResource.Kind.PullRequest -> "⇄"
        RemoteResource.Kind.Issue -> "◎"
        RemoteResource.Kind.Artifact -> "◆"
        RemoteResource.Kind.Link -> "↗"
        RemoteResource.Kind.Repository -> "▣"
    }
    Row(modifier.fillMaxWidth().padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(glyph, style = Theme.mono(12f), color = Theme.cyan, modifier = Modifier.widthIn(min = 14.dp))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(resource.name, style = Theme.mono(12f, FontWeight.SemiBold), color = Theme.text, maxLines = 1,
                    overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false))
                resource.state?.takeIf { it != "open" }?.let {
                    Text(it, style = Theme.mono(10f), color = if (it == "merged") Theme.lilac else Theme.dim)
                }
                ChecksMark(resource)
            }
            Text(
                resource.title ?: runCatching { Uri.parse(resource.url).host }.getOrNull() ?: resource.url,
                style = Theme.mono(10.5f), color = Theme.dim, maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
