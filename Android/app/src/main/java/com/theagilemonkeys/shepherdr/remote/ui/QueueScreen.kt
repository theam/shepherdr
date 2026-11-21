package com.theagilemonkeys.shepherdr.remote.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SportsEsports
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.theagilemonkeys.shepherdr.remote.protocol.QueueRow
import com.theagilemonkeys.shepherdr.remote.protocol.QueueSearch
import com.theagilemonkeys.shepherdr.remote.protocol.QueueTree
import com.theagilemonkeys.shepherdr.remote.protocol.RemoteCompass
import com.theagilemonkeys.shepherdr.remote.protocol.RemoteResource
import com.theagilemonkeys.shepherdr.remote.relay.RelayClient
import com.theagilemonkeys.shepherdr.remote.ui.arcade.ArcadeScreen
import com.theagilemonkeys.shepherdr.remote.ui.arcade.ArcadeSound

private val INDENT = 14.dp
/** The number's column, as wide as two digits. */
private val NUMBER_WIDTH = 18.dp
private val LEADING = 14.dp
private val TRAILING = 10.dp

/**
 * The Mac's queue, in its order: groups, projects, sessions with the ones they wait for nested
 * under them, and shells. Searching narrows it to the sessions that match.
 */
@Composable
fun QueueScreen(client: RelayClient, navigator: Navigator) {
    var showsSettings by rememberSaveable { mutableStateOf(false) }
    val arcade = client.arcade
    Box(Modifier.fillMaxSize().background(Theme.background)) {
        if (arcade.herdMode) {
            ArcadeScreen(
                client,
                onQueue = { arcade.showHerdMode(false) },
                onSettings = { showsSettings = true },
                onOpen = { row, session -> navigator.push(Screen.Session(row, session)) },
            )
        } else {
            QueueList(client, navigator, onSettings = { showsSettings = true })
        }
    }
    if (showsSettings) SettingsSheet(client) { showsSettings = false }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun QueueList(client: RelayClient, navigator: Navigator, onSettings: () -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    val queue = client.queue
    PullToRefreshBox(isRefreshing = false, onRefresh = { client.start() }) {
        LazyColumn(Modifier.fillMaxSize()) {
            item(key = "header") {
                Header(client, query, { query = it }, onSettings, Modifier.padding(start = LEADING, end = TRAILING, top = 4.dp, bottom = 8.dp))
            }
            if (queue != null) {
                val rows = QueueSearch.rows(queue.rows, query)
                val compass = queue.compass
                if (compass != null && (query.isEmpty() || "compass".contains(query.lowercase()))) {
                    item(key = "compass") {
                        CompassRow(
                            compass,
                            Modifier
                                .padding(start = LEADING - 4.dp, end = TRAILING, bottom = 6.dp)
                                .background(Theme.panel, RoundedCornerShape(8.dp))
                                .border(1.dp, if (compass.needsYou) Theme.amber.copy(alpha = 0.6f) else Theme.line, RoundedCornerShape(8.dp))
                                .clickable { navigator.push(Screen.Compass) }
                                .padding(horizontal = 12.dp),
                        )
                    }
                }
                items(rows, key = { it.id }) { row ->
                    val session = row.session
                    val flat = query.isNotEmpty()
                    val padding = Modifier.padding(start = LEADING, end = TRAILING)
                    if (session != null) {
                        QueueRowView(row, flat, Modifier.clickable { navigator.push(Screen.Session(row, session)) }.then(padding))
                    } else {
                        HeadingView(row, flat, padding)
                    }
                }
                if (rows.isEmpty() && query.isNotEmpty()) {
                    item { Text("No session matches “$query”.", style = Theme.mono(12f), color = Theme.dim, modifier = Modifier.padding(horizontal = LEADING)) }
                }
            } else if (client.phase == RelayClient.Phase.Connected || client.phase == RelayClient.Phase.Connecting) {
                item {
                    Row(Modifier.padding(horizontal = LEADING, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(16.dp), color = Theme.dim, strokeWidth = 2.dp)
                        Spacer(Modifier.width(10.dp))
                        Text("Waiting for the queue…", style = Theme.mono(12f), color = Theme.dim)
                    }
                }
            }
        }
    }
}

@Composable
private fun Header(client: RelayClient, query: String, onQuery: (String) -> Unit, onSettings: () -> Unit, modifier: Modifier) {
    val phase = client.phase
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("SHEPHERDR", style = Theme.mono(13f, FontWeight.SemiBold, 3.sp), color = Theme.phosphor)
            Spacer(Modifier.weight(1f))
            IconButton(onClick = {
                client.arcade.showHerdMode(true)
                client.arcade.play(ArcadeSound.Effect.Coin)
            }) {
                Icon(
                    Icons.Filled.SportsEsports, contentDescription = "Herd Mode",
                    tint = if (client.arcade.isPlaying) Theme.amber else Theme.dim,
                )
            }
            IconButton(onClick = onSettings) { Icon(Icons.Filled.Settings, contentDescription = "Settings", tint = Theme.dim) }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            val dot = when (phase) {
                RelayClient.Phase.Connected -> Theme.phosphor
                RelayClient.Phase.Connecting -> Theme.amber
                is RelayClient.Phase.Failed -> Theme.red
                RelayClient.Phase.Idle -> Theme.faint
            }
            Box(Modifier.size(8.dp).background(dot, CircleShape))
            Spacer(Modifier.width(8.dp))
            Text(client.mac?.name ?: "Mac", style = Theme.mono(13f, FontWeight.Medium), color = Theme.text, maxLines = 1,
                overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            val label = when (phase) {
                RelayClient.Phase.Connected -> "live"
                RelayClient.Phase.Connecting -> "connecting…"
                is RelayClient.Phase.Failed -> "offline"
                RelayClient.Phase.Idle -> "paused"
            }
            Text(label, style = Theme.mono(11f), color = Theme.dim)
        }
        if (phase is RelayClient.Phase.Failed) Text(phase.message, style = Theme.mono(12f), color = Theme.amber)
        val queue = client.queue ?: return@Column
        val sessions = queue.rows.filter { it.kind == QueueRow.Kind.Session }
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Chip("${sessions.count { it.status == "needsYou" }} need you", Theme.amber)
            Chip("${sessions.count { it.status == "working" }} working", Theme.phosphor)
            Chip("${sessions.size} sessions", Theme.dim)
        }
        if (queue.machines.size > 1) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (machine in queue.machines) Chip(machine.name, if (machine.isOnline) Theme.dim else Theme.red)
            }
        }
        SearchField(query, onQuery)
    }
}

@Composable
private fun SearchField(query: String, onQuery: (String) -> Unit) {
    val focus = LocalFocusManager.current
    Row(
        Modifier
            .fillMaxWidth()
            .padding(top = 2.dp)
            .background(Theme.raised, RoundedCornerShape(8.dp))
            .padding(horizontal = 10.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Search, contentDescription = null, tint = Theme.faint, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Box(Modifier.weight(1f)) {
            if (query.isEmpty()) Text("Search sessions", style = Theme.mono(13f), color = Theme.faint)
            BasicTextField(
                query, onQuery, singleLine = true,
                textStyle = Theme.mono(13f).copy(color = Theme.text),
                cursorBrush = SolidColor(Theme.phosphor),
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, imeAction = ImeAction.Search),
                keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSearch = { focus.clearFocus() }),
                modifier = Modifier.fillMaxWidth(),
            )
        }
        if (query.isNotEmpty()) {
            Icon(
                Icons.Filled.Cancel, contentDescription = "Clear search", tint = Theme.faint,
                modifier = Modifier.size(18.dp).clickable { onQuery("") },
            )
        }
    }
}

/** Compass at the top of the queue, as the Mac's COMPASS tab: what its agent is doing and when it runs next. */
@Composable
private fun CompassRow(compass: RemoteCompass, modifier: Modifier) {
    Row(modifier.fillMaxWidth().padding(top = 8.dp, bottom = 14.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("◈", style = Theme.mono(12f), color = Theme.phosphor, modifier = Modifier.width(NUMBER_WIDTH))
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("COMPASS", style = Theme.mono(12f, FontWeight.SemiBold, 2.sp), color = Theme.text)
                if (compass.hasNews) Box(Modifier.size(6.dp).background(Theme.phosphor, CircleShape))
            }
            Text(compass.activity, style = Theme.mono(10.5f), color = compassColor(compass), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(compass.next, style = Theme.mono(10f), color = Theme.faint, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

fun compassColor(compass: RemoteCompass): Color = when {
    compass.needsYou -> Theme.amber
    compass.activity.startsWith("✓") -> Theme.phosphor
    compass.activity.startsWith("●") || compass.activity.startsWith("○") -> Theme.cyan
    else -> Theme.dim
}

/** One session or shell, indented as deep as the Mac nests it. */
@Composable
fun QueueRowView(row: QueueRow, flat: Boolean, modifier: Modifier = Modifier) {
    val depth = if (flat) 0 else row.depth
    Row(
        modifier
            .fillMaxWidth()
            .drawBehind { if (!flat) { drawRails(row); row.tree?.let { drawTree(it, row.depth) } } }
            .padding(start = INDENT * depth)
            .padding(vertical = 7.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            row.number?.toString() ?: if (row.kind == QueueRow.Kind.Shell) "$" else "·",
            style = Theme.mono(11f), color = Theme.faint, modifier = Modifier.width(NUMBER_WIDTH).padding(top = 2.dp),
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(row.title, style = Theme.mono(13f, FontWeight.SemiBold), color = Theme.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            row.summary?.takeIf { it.isNotEmpty() }?.let {
                Text(it, style = Theme.mono(10.5f), color = Theme.dim, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            val detail = listOfNotNull(row.agent, row.machine).joinToString(" · ")
            val pulls = row.resources.filter { it.kind == RemoteResource.Kind.PullRequest }
            if (detail.isNotEmpty() || pulls.isNotEmpty()) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (detail.isNotEmpty()) {
                        Text(detail, style = Theme.mono(10f), color = Theme.faint, maxLines = 1, overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false))
                    }
                    PullsLabel(pulls)
                }
            }
        }
        Text(Theme.label(row.status), style = Theme.mono(9.5f, FontWeight.SemiBold, 1.sp), color = Theme.color(row.status),
            modifier = Modifier.padding(top = 3.dp))
    }
}

/** A session's pull requests in its queue row: `⇄ #12 ✓`, or `⇄ 3 PRs`. */
@Composable
private fun PullsLabel(pulls: List<RemoteResource>) {
    val first = pulls.firstOrNull() ?: return
    Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(
            if (pulls.size == 1) "⇄ ${prNumber(first)}" else "⇄ ${pulls.size} PRs",
            style = Theme.mono(10f), color = if (first.state == "merged") Theme.lilac else Theme.cyan, maxLines = 1,
        )
        if (pulls.size == 1) ChecksMark(first)
    }
}

/** `#12` from `theam/shepherdr#12`. */
fun prNumber(resource: RemoteResource): String =
    resource.name.split("#").lastOrNull()?.takeIf { resource.name.contains("#") }?.let { "#$it" } ?: resource.name

@Composable
fun ChecksMark(resource: RemoteResource) {
    when (resource.checks) {
        "passed" -> Text("✓", style = Theme.mono(10f), color = Theme.phosphor)
        "failed" -> Text("✗", style = Theme.mono(10f), color = Theme.red)
        "running" -> Text("◌", style = Theme.mono(10f), color = Theme.amber)
    }
}

/** The lines down a group and a project, under their headings, as the Mac's sidebar draws them. */
private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawRails(row: QueueRow) {
    val unit = 1.dp.toPx()
    if (row.inGroup && row.kind != QueueRow.Kind.Group) {
        drawRect(Theme.line, Offset(3 * unit, 0f), Size(unit, size.height))
    }
    if (row.inProject && row.kind != QueueRow.Kind.Project) {
        val x = ((if (row.inGroup) INDENT.toPx() else 0f) + 3 * unit)
        drawRect(Theme.faint.copy(alpha = 0.5f), Offset(x, 0f), Size(unit, size.height))
    }
}

/**
 * The lines tying sessions on hold to the sessions they wait for, as the Mac's sidebar draws them:
 * each level's line runs under its parent's number, and ends in an elbow at the session.
 */
private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawTree(tree: QueueTree, depth: Int) {
    val unit = 1.dp.toPx()
    val indent = INDENT.toPx()
    val elbow = 15 * unit
    val parentBottom = 22 * unit
    val top = (depth - tree.depth) * indent
    fun x(level: Int) = top + (level - 1) * indent + 3.5f * unit
    val color = Theme.faint.copy(alpha = 0.7f)
    tree.guides.forEachIndexed { index, passes -> if (passes) drawRect(color, Offset(x(index + 1), 0f), Size(unit, size.height)) }
    if (tree.depth > 0) {
        val own = x(tree.depth)
        drawRect(color, Offset(own, 0f), Size(unit, if (tree.isLast) elbow + unit else size.height))
        drawRect(color, Offset(own, elbow), Size(indent - 7 * unit, unit))
    }
    if (tree.nested > 0) {
        drawRect(color, Offset(x(tree.depth + 1), parentBottom), Size(unit, maxOf(0f, size.height - parentBottom)))
    }
}

@Composable
private fun HeadingView(row: QueueRow, flat: Boolean, modifier: Modifier) {
    Row(
        modifier
            .fillMaxWidth()
            .drawBehind { if (!flat) drawRails(row) }
            .padding(start = if (flat) 0.dp else INDENT * row.depth)
            .padding(top = 12.dp, bottom = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(row.title.uppercase(), style = Theme.mono(10.5f, FontWeight.SemiBold, 2.sp), color = Theme.faint)
        if (row.needsYou > 0) Text("${row.needsYou} need you", style = Theme.mono(10f), color = Theme.amber)
    }
}
