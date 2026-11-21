package com.theagilemonkeys.shepherdr.remote.ui.arcade

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.automirrored.filled.VolumeOff
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.res.imageResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.theagilemonkeys.shepherdr.remote.R
import com.theagilemonkeys.shepherdr.remote.protocol.Herd
import com.theagilemonkeys.shepherdr.remote.protocol.HerdEvent
import com.theagilemonkeys.shepherdr.remote.protocol.HerdGame
import com.theagilemonkeys.shepherdr.remote.protocol.HerdScore
import com.theagilemonkeys.shepherdr.remote.protocol.HerdScores
import com.theagilemonkeys.shepherdr.remote.protocol.QueueRow
import com.theagilemonkeys.shepherdr.remote.protocol.RemoteSessionID
import com.theagilemonkeys.shepherdr.remote.relay.RelayClient
import com.theagilemonkeys.shepherdr.remote.ui.Theme
import kotlin.math.ceil
import kotlin.math.min

/**
 * Herd mode: the queue as an arcade game. The sessions that stopped come first, needing you, then
 * done, then idle; the ones working graze in the pasture. Clear them all before the clock runs
 * out, and your initials go in the table.
 */
@Composable
fun ArcadeScreen(
    client: RelayClient,
    onQueue: () -> Unit,
    onSettings: () -> Unit,
    onOpen: (QueueRow, RemoteSessionID) -> Unit,
    modifier: Modifier = Modifier,
) {
    val arcade = client.arcade
    val rows = client.queue?.rows ?: emptyList()
    Column(
        modifier
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 14.dp)
            .padding(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        TopBar(client, onQueue, onSettings)
        ScoreBar(arcade)
        val game = arcade.game
        when {
            game == null -> AttractScreen(client, arcade, rows)
            game.isOver -> ResultScreen(arcade, game, onQueue)
            else -> PlayScreen(client, arcade, game, rows, client.phase == RelayClient.Phase.Connected, onOpen)
        }
    }
}

fun digits(score: Int): String = "%06d".format(min(score, 999_999))

@Composable
private fun TopBar(client: RelayClient, onQueue: () -> Unit, onSettings: () -> Unit) {
    val arcade = client.arcade
    Row(Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.clickable(onClick = onQueue).padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.AutoMirrored.Filled.List, contentDescription = null, tint = Theme.dim, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(5.dp))
            Text("QUEUE", style = Theme.mono(12f, FontWeight.SemiBold, 2.sp), color = Theme.dim)
        }
        Spacer(Modifier.weight(1f))
        Box(Modifier.size(7.dp).background(if (client.phase == RelayClient.Phase.Connected) Theme.phosphor else Theme.amber, CircleShape))
        Spacer(Modifier.width(6.dp))
        Text(client.mac?.name ?: "Mac", style = Theme.mono(11f), color = Theme.dim, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false))
        IconButton(onClick = { arcade.toggleSound() }) {
            Icon(
                if (arcade.soundOn) Icons.AutoMirrored.Filled.VolumeUp else Icons.AutoMirrored.Filled.VolumeOff,
                contentDescription = if (arcade.soundOn) "Mute" else "Sound On", tint = Theme.dim,
            )
        }
        IconButton(onClick = onSettings) { Icon(Icons.Filled.Settings, contentDescription = "Settings", tint = Theme.dim) }
    }
}

/** Shepherdr's dog, your score and the best one, as an arcade's top line. */
@Composable
private fun ScoreBar(arcade: Arcade) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Image(
            ImageBitmap.imageResource(R.drawable.arcade_dog), contentDescription = null, filterQuality = FilterQuality.None,
            modifier = Modifier.size(54.dp).border(2.dp, Theme.phosphor.copy(alpha = 0.5f)),
        )
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            PixelText("1UP", color = Theme.red)
            PixelText(digits(arcade.game?.score ?: 0), scale = 3f, color = Theme.text)
        }
        Spacer(Modifier.weight(1f))
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(6.dp)) {
            PixelText("HI SCORE", color = Theme.amber)
            PixelText(digits(arcade.highScore), scale = 3f, color = Theme.text)
        }
    }
}

// Title

@Composable
private fun AttractScreen(client: RelayClient, arcade: Arcade, rows: List<QueueRow>) {
    val strays = Herd.strays(rows)
    val moving = rows.count { it.kind == QueueRow.Kind.Session && Herd.isMoving(it.status) }
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Image(
            ImageBitmap.imageResource(R.drawable.arcade_title), contentDescription = "Shepherdr's dog and its sheep",
            filterQuality = FilterQuality.None, contentScale = ContentScale.FillWidth,
            modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
        )
        PixelText("HERD MODE", scale = 4f, color = Theme.amber, shadow = Theme.red.copy(alpha = 0.6f))
        when {
            client.queue == null -> PixelText("WAITING FOR THE MAC", color = Theme.dim)
            strays.isEmpty() -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                PixelText("ALL SHEEP GRAZING", color = Theme.phosphor)
                Text(
                    "Nothing to herd: every session is working or on hold.", style = Theme.mono(11f), color = Theme.dim,
                    textAlign = TextAlign.Center,
                )
            }
            else -> {
                Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
                    PixelText("ASTRAY ${strays.size}", color = Theme.amber)
                    PixelText("GRAZING $moving", color = Theme.phosphor)
                }
                Box(
                    Modifier
                        .clickable { arcade.start(rows) }
                        .border(2.dp, Theme.phosphor)
                        .padding(horizontal = 18.dp, vertical = 12.dp),
                ) {
                    Blinking { PixelText("PRESS START", scale = 3f, color = Theme.phosphor) }
                }
            }
        }
        HowToPlay()
        HighScoreTable(arcade.scores, highlight = null)
    }
}

@Composable
private fun HowToPlay() {
    Column(
        Modifier.fillMaxWidth().border(2.dp, Theme.line).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        PixelText("HOW TO PLAY", color = Theme.cyan)
        HowLine("▶ BACK TO WORK", "10", Theme.phosphor)
        HowLine("! ANSWER", "50", Theme.amber)
        HowLine("✓ EXIT WHEN DONE", "100", Theme.cyan)
        HowLine("★ QUEUE CLEAR", "500", Theme.lilac)
        HowLine("COMBO IN 90 S", "×5", Theme.red)
        Text(
            "Prompt a session that stopped, answer the one that needs you, or leave the agent of one that's done, such as " +
                "with /exit, all from this phone. Ten minutes without doing anything is GAME OVER.",
            style = Theme.mono(10.5f), color = Theme.dim,
        )
    }
}

@Composable
private fun HowLine(label: String, points: String, color: Color) {
    Row(Modifier.fillMaxWidth()) {
        PixelText(label, color = color)
        Spacer(Modifier.weight(1f))
        PixelText(points, color = Theme.text)
    }
}

// Playing

@Composable
private fun PlayScreen(
    client: RelayClient,
    arcade: Arcade,
    game: HerdGame,
    rows: List<QueueRow>,
    connected: Boolean,
    onOpen: (QueueRow, RemoteSessionID) -> Unit,
) {
    var confirmsGivingUp by remember { mutableStateOf(false) }
    val strays = game.strays(rows)
    val moving = rows.filter { it.kind == QueueRow.Kind.Session && Herd.isMoving(it.status) }
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        rememberTick(1000)
        val now = System.currentTimeMillis()
        val left = maxOf(0, ceil((game.deadline - now) / 1000.0).toInt())
        val combo = game.lastScored?.let { now - it <= HerdGame.COMBO_WINDOW } == true && game.combo > 1
        val time = "TIME %02d:%02d".format(left / 60, left % 60)
        Row(Modifier.fillMaxWidth()) {
            when {
                !connected -> Blinking { PixelText("CLOCK STOPPED", color = Theme.amber) }
                left <= 60 -> Blinking { PixelText(time, color = Theme.red) }
                else -> PixelText(time, color = Theme.text)
            }
            Spacer(Modifier.weight(1f))
            if (combo) PixelText("COMBO ×${game.combo}", color = Theme.amber)
        }
        if (!connected) {
            Text(
                "Waiting for ${client.mac?.name ?: "the Mac"}: the clock starts again once the phone reaches it.",
                style = Theme.mono(11f), color = Theme.amber,
            )
        }
        Pasture(grazing = moving.size)
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            PixelText("ASTRAY ${strays.size}", color = Theme.amber)
            PixelText("GRAZING ${moving.count { it.status == "working" }}", color = Theme.phosphor)
            val held = moving.count { it.status == "waiting" }
            if (held > 0) PixelText("HOLD $held", color = Theme.lilac)
        }
        for (kind in Herd.Stray.entries) {
            val herd = strays.filter { Herd.stray(it.status) == kind }
            if (herd.isEmpty()) continue
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    PixelText(heading(kind), color = strayColor(kind))
                    Spacer(Modifier.weight(1f))
                    Text(hint(kind), style = Theme.mono(10f), color = Theme.faint)
                }
                for (row in herd) {
                    val session = row.session ?: continue
                    StrayCard(row, kind, Modifier.clickable { onOpen(row, session) })
                }
            }
        }
        Box(Modifier.fillMaxWidth().padding(top = 8.dp), contentAlignment = Alignment.Center) {
            Box(Modifier.clickable { confirmsGivingUp = true }.border(2.dp, Theme.line).padding(horizontal = 12.dp, vertical = 8.dp)) {
                PixelText("GIVE UP", color = Theme.faint)
            }
        }
    }
    if (confirmsGivingUp) {
        AlertDialog(
            onDismissRequest = { confirmsGivingUp = false },
            title = { Text("Give up this game?") },
            text = { Text("It ends now, with the points you have. Your sessions carry on as they are.") },
            confirmButton = {
                TextButton(onClick = { confirmsGivingUp = false; arcade.giveUp() }) { Text("Give Up", color = Theme.red) }
            },
            dismissButton = { TextButton(onClick = { confirmsGivingUp = false }) { Text("Keep Playing") } },
            containerColor = Theme.panel,
        )
    }
}

private fun heading(kind: Herd.Stray) = when (kind) {
    Herd.Stray.NeedsYou -> "! NEEDS YOU"
    Herd.Stray.Done -> "✓ DONE"
    Herd.Stray.Idle -> "Z IDLE"
}

private fun hint(kind: Herd.Stray) = when (kind) {
    Herd.Stray.NeedsYou -> "answer +50"
    Herd.Stray.Done, Herd.Stray.Idle -> "prompt +10 · exit +100"
}

private fun strayColor(kind: Herd.Stray) = when (kind) {
    Herd.Stray.NeedsYou -> Theme.amber
    Herd.Stray.Done -> Theme.cyan
    Herd.Stray.Idle -> Theme.dim
}

/** A session astray: its sheep in the color of what it waits for, and what it last said. */
@Composable
private fun StrayCard(row: QueueRow, kind: Herd.Stray, modifier: Modifier = Modifier) {
    val color = strayColor(kind)
    Row(
        modifier
            .fillMaxWidth()
            .background(Theme.panel)
            .border(2.dp, color.copy(alpha = 0.55f))
            .padding(10.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box {
            SpriteView(Flock.sheep(color), Modifier.padding(top = 6.dp), scale = 3f)
            if (kind == Herd.Stray.NeedsYou) {
                Box(Modifier.align(Alignment.TopEnd).offset(x = 4.dp, y = (-4).dp)) {
                    Blinking { PixelText("!", color = Theme.amber) }
                }
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(row.title, style = Theme.mono(13f, FontWeight.SemiBold), color = Theme.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            row.summary?.takeIf { it.isNotEmpty() }?.let {
                Text(it, style = Theme.mono(10.5f), color = Theme.dim, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            val detail = listOfNotNull(row.agent, row.machine).joinToString(" · ")
            if (detail.isNotEmpty()) Text(detail, style = Theme.mono(10f), color = Theme.faint, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = Theme.faint,
            modifier = Modifier.padding(top = 6.dp).size(18.dp),
        )
    }
}

/** The sessions at work, as sheep running across a field with the dog behind them. */
@Composable
private fun Pasture(grazing: Int) {
    val now = rememberFrameTime()
    Box(Modifier.fillMaxWidth().height(50.dp)) {
        Canvas(Modifier.fillMaxWidth().height(50.dp)) {
            val time = now / 1000.0
            val unit = 1.dp.toPx()
            val pixel = 3 * unit
            val widthUnits = size.width / unit
            val ground = size.height - 6 * unit
            drawRect(Theme.line, Offset(0f, ground), Size(size.width, 2 * unit))
            val grass = Path()
            var x = 7.0
            while (x < widthUnits) {
                grass.addRect(Rect(Offset((x * unit).toFloat(), ground - 4 * unit), Size(2 * unit, 4 * unit)))
                grass.addRect(Rect(Offset(((x + 4) * unit).toFloat(), ground - 2 * unit), Size(2 * unit, 2 * unit)))
                x += 23
            }
            drawPath(grass, Color(0xFF1E5A3A))
            val lap = widthUnits + 90
            for (index in 0 until min(grazing, 8)) {
                val speed = 16 + (index * 7 % 11).toDouble()
                val sheepX = (index * 53 + time * speed) % lap - 50
                val step = (time * 5 + index).toInt() % 2 == 0
                Flock.sheep(Theme.phosphor, step).draw(this, Offset((sheepX * unit).toFloat(), ground - 30 * unit), pixel)
            }
            val dog = (time * 22) % (lap + 40) - 70
            Flock.dog((time * 7).toInt() % 2 == 0).draw(this, Offset((dog * unit).toFloat(), ground - 36 * unit), pixel)
        }
        if (grazing == 0) {
            Box(Modifier.align(Alignment.Center).offset(y = (-16).dp)) { PixelText("NO SHEEP GRAZING", color = Theme.faint) }
        }
    }
}

// The end

@Composable
private fun ResultScreen(arcade: Arcade, game: HerdGame, onQueue: () -> Unit) {
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(18.dp)) {
        if (game.outcome == HerdGame.Outcome.Cleared) {
            val tick = rememberTick(200)
            val colors = listOf(Theme.phosphor, Theme.amber, Theme.cyan, Theme.lilac)
            PixelText("QUEUE CLEAR!", scale = 4f, color = colors[(tick % colors.size).toInt()], shadow = Theme.faint)
            Image(
                ImageBitmap.imageResource(R.drawable.arcade_title), contentDescription = null, filterQuality = FilterQuality.None,
                contentScale = ContentScale.FillWidth, modifier = Modifier.fillMaxWidth(),
            )
        } else {
            PixelText("GAME OVER", scale = 5f, color = Theme.red, shadow = Color(0xFF5A1A18))
            PixelText(if (game.outcome == HerdGame.Outcome.TimeUp) "TIME UP" else "YOU GAVE UP", color = Theme.dim)
            SpriteView(Flock.sheep(Theme.faint), scale = 6f)
        }
        Column(
            Modifier.fillMaxWidth().border(2.dp, Theme.line).padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Tally("BACK TO WORK", "×${game.backToWork}")
            Tally("ANSWERED", "×${game.answered}")
            Tally("CLOSED", "×${game.closed}")
            if (game.outcome == HerdGame.Outcome.Cleared) {
                Tally("CLEAR BONUS", "${game.clearBonus}")
                Tally("TIME BONUS", "${game.timeBonus}")
            }
            Row(Modifier.fillMaxWidth().padding(top = 4.dp)) {
                PixelText("SCORE", scale = 3f, color = Theme.amber)
                Spacer(Modifier.weight(1f))
                PixelText(digits(game.score), scale = 3f, color = Theme.text)
            }
        }
        if (arcade.awaitsInitials) {
            InitialsEntry(arcade)
        } else {
            HighScoreTable(arcade.scores, highlight = arcade.placed?.takeIf { it >= 0 })
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                Box(Modifier.clickable { arcade.reset() }.border(2.dp, Theme.phosphor).padding(horizontal = 12.dp, vertical = 10.dp)) {
                    PixelText("PLAY AGAIN", color = Theme.phosphor)
                }
                Box(
                    Modifier
                        .clickable { arcade.reset(); onQueue() }
                        .border(2.dp, Theme.line)
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                ) {
                    PixelText("QUEUE", color = Theme.dim)
                }
            }
        }
    }
}

@Composable
private fun Tally(label: String, value: String) {
    Row(Modifier.fillMaxWidth()) {
        PixelText(label, color = Theme.dim)
        Spacer(Modifier.weight(1f))
        PixelText(value, color = Theme.text)
    }
}

/** Three letters, picked with the arrows, as an arcade asks for them. */
@Composable
private fun InitialsEntry(arcade: Arcade) {
    val letters = remember { mutableStateListOf(*HerdScores.initials(arcade.lastInitials).toList().toTypedArray()) }
    var slot by remember { mutableIntStateOf(0) }
    fun step(index: Int, by: Int) {
        val alphabet = HerdScores.alphabet
        val position = alphabet.indexOf(letters[index]).coerceAtLeast(0)
        letters[index] = alphabet[(position + by + alphabet.size) % alphabet.size]
        slot = index
        arcade.play(ArcadeSound.Effect.Select)
    }
    Column(
        Modifier.padding(vertical = 6.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Blinking { PixelText("NEW HIGH SCORE!", scale = 3f, color = Theme.amber) }
        PixelText("ENTER YOUR INITIALS", color = Theme.dim)
        Row(horizontalArrangement = Arrangement.spacedBy(22.dp)) {
            for (index in 0 until 3) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.clickable { step(index, 1) }.padding(8.dp)) { PixelText("▲", scale = 5f, color = Theme.dim) }
                    Column(
                        Modifier.clickable { slot = index; arcade.play(ArcadeSound.Effect.Select) },
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        PixelText(letters[index].toString(), scale = 7f, color = if (slot == index) Theme.phosphor else Theme.text)
                        Box(Modifier.size(35.dp, 4.dp).background(if (slot == index) Theme.phosphor else Theme.line))
                    }
                    Box(Modifier.clickable { step(index, -1) }.padding(8.dp)) { PixelText("▼", scale = 5f, color = Theme.dim) }
                }
            }
        }
        Box(
            Modifier
                .clickable { arcade.enter(letters.joinToString("")) }
                .background(Theme.phosphor)
                .padding(horizontal = 26.dp, vertical = 10.dp),
        ) {
            PixelText("OK", scale = 3f, color = Theme.background)
        }
    }
}

/** The ten best scores, in an arcade's colors; the one just made blinks. */
@Composable
private fun HighScoreTable(scores: List<HerdScore>, highlight: Int?) {
    val colors = listOf(Theme.amber, Theme.phosphor, Theme.cyan, Theme.lilac, Theme.red)
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        PixelText("HIGH SCORES", Modifier.padding(bottom = 4.dp), scale = 3f, color = Theme.amber, shadow = Theme.red.copy(alpha = 0.6f))
        scores.take(HerdScores.SIZE).forEachIndexed { index, entry ->
            val line = @Composable {
                Row(Modifier.fillMaxWidth()) {
                    PixelText(ordinal(index + 1), Modifier.width(60.dp), color = colors[index % colors.size])
                    PixelText(digits(entry.score), color = Theme.text)
                    Spacer(Modifier.weight(1f))
                    PixelText(entry.initials, color = colors[index % colors.size])
                }
            }
            if (index == highlight) Blinking(300) { line() } else line()
        }
    }
}

private fun ordinal(rank: Int) = when (rank) {
    1 -> "1ST"
    2 -> "2ND"
    3 -> "3RD"
    else -> "${rank}TH"
}

// Popups

/** The points as they come, over whatever screen the phone shows. */
@Composable
fun ArcadePopups(arcade: Arcade, modifier: Modifier = Modifier) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        for (popup in arcade.popups) {
            androidx.compose.runtime.key(popup.id) {
                AnimatedVisibility(visible = true, enter = scaleIn(initialScale = 0.6f) + fadeIn(), exit = fadeOut()) {
                    PopupView(popup)
                }
            }
        }
    }
}

@Composable
private fun PopupView(popup: Arcade.Popup) {
    val now = rememberFrameTime()
    val age = (now - popup.date) / 1000.0
    val event = popup.event
    val color = when (event.kind) {
        HerdEvent.Kind.Answered -> Theme.amber
        HerdEvent.Kind.Closed -> Theme.cyan
        HerdEvent.Kind.Strayed -> Theme.dim
        else -> Theme.phosphor
    }
    Row(
        Modifier
            .offset(y = (-min(age, 2.0) * 8).dp)
            .alpha(if (age < 1.6) 1f else maxOf(0.0, 1 - (age - 1.6) / 0.5).toFloat())
            .background(Theme.panel.copy(alpha = 0.96f))
            .border(2.dp, color.copy(alpha = 0.7f))
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        if (event.kind == HerdEvent.Kind.Strayed) PixelText("BAA!", scale = 3f, color = color)
        else if (event.points > 0) PixelText("+${event.points}", scale = 3f, color = color)
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            PixelText(label(event), color = Theme.text)
            Text(event.title, style = Theme.mono(10f), color = Theme.dim, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (event.combo > 1) PixelText("×${event.combo}", scale = 2f, color = Theme.amber)
    }
}

private fun label(event: HerdEvent) = when (event.kind) {
    HerdEvent.Kind.BackToWork -> "BACK TO WORK"
    HerdEvent.Kind.Answered -> "ANSWERED"
    HerdEvent.Kind.Closed -> "CLOSED"
    HerdEvent.Kind.Strayed -> "ASTRAY"
    HerdEvent.Kind.Cleared -> "QUEUE CLEAR"
    HerdEvent.Kind.TimeUp -> "TIME UP"
}
