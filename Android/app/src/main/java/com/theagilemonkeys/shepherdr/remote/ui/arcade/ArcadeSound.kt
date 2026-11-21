package com.theagilemonkeys.shepherdr.remote.ui.arcade

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import com.theagilemonkeys.shepherdr.remote.dictation.Dictation
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * Herd mode's 8-bit sounds, synthesized on the phone: square and triangle waves, as a game
 * console's sound chip makes them. They stay quiet while the phone is on silent or vibrate, and
 * while you dictate.
 */
class ArcadeSound(context: Context) {
    enum class Effect { Coin, Start, Select, BackToWork, Answered, Closed, Strayed, Cleared, GameOver, Tick, Entry }

    private val audio = context.getSystemService(AudioManager::class.java)
    private val cache = mutableMapOf<Effect, ShortArray>()
    private val main = Handler(Looper.getMainLooper())
    var isEnabled: () -> Boolean = { true }

    fun play(effect: Effect) {
        if (!isEnabled() || Dictation.isListening) return
        if (audio?.ringerMode != AudioManager.RINGER_MODE_NORMAL) return
        val samples = cache.getOrPut(effect) { Synth.wave(music(effect)) }
        if (samples.isEmpty()) return
        runCatching {
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_GAME)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(Synth.RATE.toInt())
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setTransferMode(AudioTrack.MODE_STATIC)
                .setBufferSizeInBytes(samples.size * 2)
                .build()
            track.write(samples, 0, samples.size)
            track.setVolume(0.55f)
            track.play()
            val millis = samples.size * 1000L / Synth.RATE.toLong() + 200
            main.postDelayed({ runCatching { track.stop() }; track.release() }, millis)
        }
    }

    /** Each sound's voices, played together. */
    private fun music(effect: Effect): List<List<Synth.Note>> {
        fun n(name: String) = Synth.frequency(name)
        fun note(
            frequency: Double, duration: Double, to: Double? = null, wave: Synth.Wave = Synth.Wave.Square,
            duty: Double = 0.5, vibrato: Double = 0.0, volume: Double = 0.5,
        ) = Synth.Note(frequency, duration, to, wave, duty, vibrato, volume)
        val tri = Synth.Wave.Triangle
        return when (effect) {
            Effect.Coin -> listOf(listOf(note(n("B5"), 0.06, duty = 0.25), note(n("E6"), 0.32, duty = 0.25)))
            Effect.Entry -> listOf(listOf(note(n("E6"), 0.06, duty = 0.25), note(n("B6"), 0.3, duty = 0.25)))
            Effect.Start -> listOf(
                listOf(note(n("G5"), 0.06), note(n("C6"), 0.06), note(n("E6"), 0.06), note(n("G6"), 0.12), note(n("E6"), 0.06), note(n("G6"), 0.26)),
            )
            Effect.Select -> listOf(listOf(note(n("A6"), 0.03, duty = 0.125, volume = 0.35)))
            Effect.Tick -> listOf(listOf(note(n("E5"), 0.05, duty = 0.25, volume = 0.35)))
            Effect.BackToWork -> listOf(listOf(note(n("E6"), 0.05), note(n("A6"), 0.1)))
            Effect.Answered -> listOf(listOf(note(n("C6"), 0.045), note(n("E6"), 0.045), note(n("G6"), 0.045), note(n("C7"), 0.14)))
            Effect.Closed -> listOf(
                listOf(note(n("C5"), 0.24, to = n("C7")), note(n("G6"), 0.06), note(n("C7"), 0.22)),
                listOf(note(0.0, 0.24), note(n("C4"), 0.28, wave = tri, volume = 0.6)),
            )
            // A bleat: a wobbling square that sags a little.
            Effect.Strayed -> listOf(listOf(note(430.0, 0.42, to = 360.0, vibrato = 19.0, volume = 0.32)))
            Effect.Cleared -> listOf(
                listOf(
                    note(n("C5"), 0.1), note(n("E5"), 0.1), note(n("G5"), 0.1), note(n("C6"), 0.2), note(0.0, 0.05),
                    note(n("A5"), 0.1), note(n("C6"), 0.1), note(n("E6"), 0.1), note(n("G6"), 0.5),
                ),
                listOf(
                    note(n("C3"), 0.3, wave = tri, volume = 0.6), note(n("G3"), 0.3, wave = tri, volume = 0.6),
                    note(n("A3"), 0.3, wave = tri, volume = 0.6), note(n("G3"), 0.55, wave = tri, volume = 0.6),
                ),
            )
            Effect.GameOver -> listOf(
                listOf(note(n("G4"), 0.2), note(n("F#4"), 0.2), note(n("F4"), 0.2), note(n("E4"), 0.7, vibrato = 6.0)),
                listOf(note(n("G2"), 0.6, wave = tri, volume = 0.6), note(n("C2"), 0.7, wave = tri, volume = 0.6)),
            )
        }
    }
}

/** A tiny sound chip: notes in, 16-bit mono samples out. */
object Synth {
    const val RATE = 22_050.0

    enum class Wave { Square, Triangle }

    data class Note(
        /** Hertz; 0 is a rest. */
        val frequency: Double,
        val duration: Double,
        /** Slides to this frequency by the note's end. */
        val to: Double? = null,
        val wave: Wave = Wave.Square,
        /** The square's share of high: 0.5 is hollow, 0.125 thin and buzzy. */
        val duty: Double = 0.5,
        /** Wobbles the pitch this many times a second. */
        val vibrato: Double = 0.0,
        val volume: Double = 0.5,
    )

    /** `A4` is 440 Hz; `F#4` and `Bb3` work too. */
    fun frequency(name: String): Double {
        val semitones = mapOf('C' to 0, 'D' to 2, 'E' to 4, 'F' to 5, 'G' to 7, 'A' to 9, 'B' to 11)
        var rest = name
        var semitone = semitones[rest.firstOrNull() ?: return 0.0] ?: return 0.0
        rest = rest.drop(1)
        if (rest.startsWith("#")) { semitone += 1; rest = rest.drop(1) } else if (rest.startsWith("b")) { semitone -= 1; rest = rest.drop(1) }
        val octave = rest.toIntOrNull() ?: 4
        val midi = (12 * (octave + 1) + semitone).toDouble()
        return 440 * 2.0.pow((midi - 69) / 12)
    }

    /** The voices mixed. */
    fun wave(voices: List<List<Note>>): ShortArray {
        val tracks = voices.map(::samples)
        val length = tracks.maxOfOrNull { it.size } ?: 0
        return ShortArray(length) { index ->
            val sum = tracks.sumOf { if (index < it.size) it[index] else 0.0 }
            (max(-1.0, min(1.0, sum * 0.6)) * 32_000).toInt().toShort()
        }
    }

    private fun samples(notes: List<Note>): DoubleArray {
        val output = ArrayList<Double>()
        var phase = 0.0
        for (note in notes) {
            val count = (note.duration * RATE).toInt()
            for (index in 0 until count) {
                val progress = index.toDouble() / max(1, count)
                if (note.frequency <= 0) { output += 0.0; continue }
                var frequency = note.frequency + ((note.to ?: note.frequency) - note.frequency) * progress
                if (note.vibrato > 0) frequency *= 1 + 0.05 * sin(2 * PI * note.vibrato * index / RATE)
                phase = (phase + frequency / RATE) % 1.0
                val value = when (note.wave) {
                    Wave.Square -> if (phase < note.duty) 1.0 else -1.0
                    Wave.Triangle -> 4 * abs(phase - 0.5) - 1
                }
                // A click-free start, a slow fade, and a quick release at the end.
                val attack = min(1.0, index / (0.004 * RATE))
                val release = min(1.0, (count - index) / (0.012 * RATE))
                output += value * note.volume * attack * release * (1 - 0.5 * progress)
            }
        }
        return output.toDoubleArray()
    }
}
