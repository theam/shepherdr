package com.theagilemonkeys.shepherdr.remote.ui.arcade

import android.content.Context
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.theagilemonkeys.shepherdr.remote.protocol.Herd
import com.theagilemonkeys.shepherdr.remote.protocol.HerdEvent
import com.theagilemonkeys.shepherdr.remote.protocol.HerdGame
import com.theagilemonkeys.shepherdr.remote.protocol.HerdScore
import com.theagilemonkeys.shepherdr.remote.protocol.HerdScores
import com.theagilemonkeys.shepherdr.remote.protocol.QueueRow
import com.theagilemonkeys.shepherdr.remote.protocol.RemoteSessionID
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.util.UUID

/**
 * Herd mode on the phone: the game in play, the table of high scores and the points popping up.
 * It follows the queue the Mac sends and what you type into sessions, and keeps the game and the
 * table on the phone, so that a game goes on after the app quits.
 */
class Arcade(context: Context, private val isConnected: () -> Boolean) {
    data class Popup(val event: HerdEvent, val id: String = UUID.randomUUID().toString(), val date: Long = System.currentTimeMillis())

    private val prefs = context.getSharedPreferences("shepherdr.herd", Context.MODE_PRIVATE)
    private val sound = ArcadeSound(context)
    private val haptics = Haptics(context)
    private val scope = MainScope()
    private val json = Json { ignoreUnknownKeys = true }

    var game by mutableStateOf<HerdGame?>(null)
        private set
    var scores by mutableStateOf(HerdScores.starting)
        private set
    /** Where the finished game's score went in the table once its initials are in; -1 when it didn't make it. */
    var placed by mutableStateOf<Int?>(null)
        private set
    /** The initials entered last, to start from next time. */
    var lastInitials by mutableStateOf("AAA")
        private set
    /** What just scored, popping up over whatever the phone shows. */
    var popups by mutableStateOf<List<Popup>>(emptyList())
        private set
    /** Whether the queue's screen shows herd mode. */
    var herdMode by mutableStateOf(prefs.getBoolean(MODE_KEY, false))
        private set
    var soundOn by mutableStateOf(prefs.getBoolean(SOUND_KEY, true))
        private set

    init {
        game = prefs.getString(GAME_KEY, null)?.let { runCatching { json.decodeFromString(HerdGame.serializer(), it) }.getOrNull() }
        placed = if (prefs.contains(PLACED_KEY)) prefs.getInt(PLACED_KEY, -1) else null
        scores = prefs.getString(SCORES_KEY, null)
            ?.let { runCatching { json.decodeFromString(ListSerializer(HerdScore.serializer()), it) }.getOrNull() }
            ?: HerdScores.starting
        lastInitials = prefs.getString(INITIALS_KEY, null) ?: "AAA"
        sound.isEnabled = { soundOn }
        startClock()
    }

    val isPlaying: Boolean get() = game?.isOver == false
    val highScore: Int get() = maxOf(scores.firstOrNull()?.score ?: 0, game?.score ?: 0)

    /** The finished game made the table and waits for its initials. */
    val awaitsInitials: Boolean
        get() {
            val game = game ?: return false
            if (!game.isOver || placed != null) return false
            return HerdScores.rank(game.score, scores) != null
        }

    fun showHerdMode(on: Boolean) {
        herdMode = on
        prefs.edit().putBoolean(MODE_KEY, on).apply()
    }

    fun toggleSound() {
        soundOn = !soundOn
        prefs.edit().putBoolean(SOUND_KEY, soundOn).apply()
        if (soundOn) play(ArcadeSound.Effect.Select)
    }

    // Playing

    fun start(rows: List<QueueRow>) {
        game = HerdGame.start(rows, System.currentTimeMillis())
        placed = null
        popups = emptyList()
        save()
        sound.play(ArcadeSound.Effect.Start)
    }

    /** A new queue from the Mac: score what changed. */
    fun observe(rows: List<QueueRow>) {
        val game = game?.takeIf { !it.isOver }?.copy() ?: return
        val events = game.observe(rows, System.currentTimeMillis())
        this.game = game
        save()
        handle(events)
    }

    /** You typed into a pane from the phone. Only sessions astray count. */
    fun touch(pane: RemoteSessionID, rows: List<QueueRow>?) {
        val current = game?.takeIf { !it.isOver } ?: return
        rows ?: return
        val session = Herd.session(pane, rows) ?: return
        if (current.strays(rows).none { it.session == session }) return
        val game = current.copy()
        game.touch(session, System.currentTimeMillis())
        this.game = game
        save()
    }

    fun giveUp() {
        val game = game?.takeIf { !it.isOver }?.copy() ?: return
        game.giveUp(System.currentTimeMillis())
        this.game = game
        save()
        sound.play(ArcadeSound.Effect.GameOver)
        haptics.error()
    }

    /** Puts the finished game's score in the table under these initials. */
    fun enter(initials: String) {
        val game = game ?: return
        if (!game.isOver || placed != null) return
        val entry = HerdScore(initials, game.score, game.ended ?: System.currentTimeMillis())
        val (table, rank) = HerdScores.inserting(entry, scores)
        scores = table
        placed = rank ?: -1
        lastInitials = HerdScores.initials(initials)
        save()
        sound.play(ArcadeSound.Effect.Entry)
    }

    /** Back to the title screen, for another game. */
    fun reset() {
        game = null
        placed = null
        popups = emptyList()
        save()
        sound.play(ArcadeSound.Effect.Coin)
    }

    fun play(effect: ArcadeSound.Effect) = sound.play(effect)

    // Events

    private fun handle(events: List<HerdEvent>) {
        if (events.isEmpty()) return
        val added = events.filter { it.kind != HerdEvent.Kind.Cleared && it.kind != HerdEvent.Kind.TimeUp }.map { Popup(it) }
        popups = (popups + added).takeLast(4)
        val ids = added.map { it.id }.toSet()
        scope.launch {
            delay(2200)
            popups = popups.filterNot { it.id in ids }
        }
        // One sound for the lot: the one that matters most.
        val kinds = events.map { it.kind }
        val scored = events.filter { it.points > 0 }.maxByOrNull { it.points }
        when {
            HerdEvent.Kind.Cleared in kinds -> {
                sound.play(ArcadeSound.Effect.Cleared)
                haptics.success()
            }
            HerdEvent.Kind.TimeUp in kinds -> {
                sound.play(ArcadeSound.Effect.GameOver)
                haptics.error()
            }
            scored != null -> {
                sound.play(
                    when (scored.kind) {
                        HerdEvent.Kind.Closed -> ArcadeSound.Effect.Closed
                        HerdEvent.Kind.Answered -> ArcadeSound.Effect.Answered
                        else -> ArcadeSound.Effect.BackToWork
                    },
                )
                haptics.impact(heavy = scored.kind == HerdEvent.Kind.Closed)
            }
            HerdEvent.Kind.Strayed in kinds -> sound.play(ArcadeSound.Effect.Strayed)
            HerdEvent.Kind.Closed in kinds -> sound.play(ArcadeSound.Effect.Select)
        }
    }

    /**
     * Ends the game when its countdown runs out, and ticks through its last ten seconds. The clock
     * stops while the app, in front, can't reach the Mac; it runs on while the app is away.
     */
    private fun startClock() {
        scope.launch {
            var last = System.nanoTime()
            while (true) {
                delay(1000)
                val now = System.nanoTime()
                val elapsed = (now - last) / 1_000_000
                last = now
                val current = game?.takeIf { !it.isOver } ?: continue
                if (!isConnected()) {
                    val game = current.copy()
                    game.hold(elapsed)
                    this@Arcade.game = game
                    save()
                    continue
                }
                val game = current.copy()
                val event = game.expire(System.currentTimeMillis())
                if (event != null) {
                    this@Arcade.game = game
                    save()
                    handle(listOf(event))
                } else if (current.deadline - System.currentTimeMillis() <= 10_000) {
                    sound.play(ArcadeSound.Effect.Tick)
                }
            }
        }
    }

    private fun save() {
        val editor = prefs.edit()
        val game = game
        if (game != null) editor.putString(GAME_KEY, json.encodeToString(HerdGame.serializer(), game)) else editor.remove(GAME_KEY)
        val placed = placed
        if (placed != null) editor.putInt(PLACED_KEY, placed) else editor.remove(PLACED_KEY)
        editor.putString(SCORES_KEY, json.encodeToString(ListSerializer(HerdScore.serializer()), scores))
        editor.putString(INITIALS_KEY, lastInitials)
        editor.apply()
    }

    private companion object {
        const val MODE_KEY = "herdMode"
        const val SOUND_KEY = "herdSound"
        const val GAME_KEY = "herdGame"
        const val PLACED_KEY = "herdPlaced"
        const val SCORES_KEY = "herdScores"
        const val INITIALS_KEY = "herdInitials"
    }
}

/** The arcade's buzzes: a thud for points, a pattern for winning and for losing. */
private class Haptics(context: Context) {
    private val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        context.getSystemService(VibratorManager::class.java)?.defaultVibrator
    } else {
        @Suppress("DEPRECATION")
        context.getSystemService(Vibrator::class.java)
    }

    fun impact(heavy: Boolean) = vibrate(VibrationEffect.createPredefined(if (heavy) VibrationEffect.EFFECT_HEAVY_CLICK else VibrationEffect.EFFECT_CLICK))
    fun success() = vibrate(VibrationEffect.createWaveform(longArrayOf(0, 30, 60, 30), intArrayOf(0, 180, 0, 255), -1))
    fun error() = vibrate(VibrationEffect.createWaveform(longArrayOf(0, 40, 50, 40, 50, 80), intArrayOf(0, 255, 0, 255, 0, 255), -1))

    private fun vibrate(effect: VibrationEffect) {
        runCatching { if (vibrator?.hasVibrator() == true) vibrator.vibrate(effect) }
    }
}
