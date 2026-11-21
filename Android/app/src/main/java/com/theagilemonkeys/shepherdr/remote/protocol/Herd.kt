package com.theagilemonkeys.shepherdr.remote.protocol

import kotlinx.serialization.Serializable

/**
 * Herd mode: the queue as an arcade game. The sessions that stopped are sheep astray: putting
 * them back to work, answering them and closing the finished ones scores, and a queue with none
 * left astray wins. Ten minutes without doing anything ends the game.
 *
 * Times are milliseconds since the epoch.
 */
object Herd {
    /** Why a session stopped, in the order the game deals with them. */
    enum class Stray {
        /** Its agent asks a question or a permission. */
        NeedsYou,
        /** Its agent finished a turn nobody looked at yet. */
        Done,
        /** Its agent waits for a prompt. */
        Idle,
    }

    /**
     * A session's place in the game: null when it moves on its own (working, on hold), when its
     * machine doesn't answer, and for shells and headings.
     */
    fun stray(row: QueueRow): Stray? = if (row.kind == QueueRow.Kind.Session) stray(row.status) else null

    fun stray(status: String?): Stray? = when (status) {
        "needsYou" -> Stray.NeedsYou
        "done" -> Stray.Done
        "idle", "unknown" -> Stray.Idle
        else -> null
    }

    /** Working or on hold: the session carries on without you. */
    fun isMoving(status: String?): Boolean = status == "working" || status == "waiting"

    /** The sessions astray: needing you first, then done, then idle, each in the queue's order. */
    fun strays(rows: List<QueueRow>): List<QueueRow> =
        rows.withIndex()
            .mapNotNull { (index, row) -> stray(row)?.let { Triple(it, index, row) } }
            .sortedWith(compareBy({ it.first }, { it.second }))
            .map { it.third }

    /** The session a pane belongs to: its own, or the one whose tab it splits. */
    fun session(pane: RemoteSessionID, rows: List<QueueRow>): RemoteSessionID? =
        rows.firstOrNull { it.session == pane || it.panes.any { p -> p.pane == pane } }?.session

    internal fun key(session: RemoteSessionID) = session.machineID + "/" + session.terminalID
}

/** Something that happened in a game, for the score's popups and sounds. */
data class HerdEvent(
    val kind: Kind,
    /** The session's name; empty for the game's own events. */
    val title: String,
    val points: Int,
    /** The multiplier the points got, 1 without a combo. */
    val combo: Int = 1,
) {
    enum class Kind {
        /** A session that was done or idle works again after you prompted it. */
        BackToWork,
        /** A session that needed you moved on after you answered it. */
        Answered,
        /** A session you were in ended: `exit` closed it. */
        Closed,
        /** A session stopped and joined the strays. */
        Strayed,
        /** No session is astray anymore: the game is won. */
        Cleared,
        /** Ten minutes went by without you doing anything. */
        TimeUp,
    }
}

/**
 * One game of herd mode, from PRESS START to the queue cleared or the game over. It follows the
 * queue's snapshots and scores what changed in the sessions you touched from the phone.
 *
 * It mutates in place; callers that need a new value for observers use [copy].
 */
@Serializable
class HerdGame private constructor(
    var started: Long,
    var score: Int = 0,
    var combo: Int = 1,
    var lastScored: Long? = null,
    /** When you last scored or typed into a session astray: the countdown starts again from it. */
    var lastAction: Long,
    var backToWork: Int = 0,
    var answered: Int = 0,
    var closed: Int = 0,
    var outcome: Outcome? = null,
    var ended: Long? = null,
    var clearBonus: Int = 0,
    var timeBonus: Int = 0,
    /**
     * Each session's status at the last snapshot, by `machine/terminal`. A session whose machine
     * stopped answering keeps the status it had, so that it still counts as astray.
     */
    private val statuses: MutableMap<String, Seen> = mutableMapOf(),
    /** When you last typed into each session, by `machine/terminal`. */
    private var touched: MutableMap<String, Long> = mutableMapOf(),
) {
    object Points {
        /** A done or idle session works again. */
        const val BACK_TO_WORK = 10
        /** A session that needed you moves on: 10 for setting it going and 40 for the answer. */
        const val ANSWERED = 50
        /** A finished session closed with `exit`. */
        const val CLOSED = 100
        /** No session left astray. */
        const val CLEARED = 500
        /** For each minute under half an hour that clearing the queue took. */
        const val PER_MINUTE_LEFT = 10
    }

    @Serializable
    enum class Outcome { Cleared, TimeUp, GaveUp }

    @Serializable
    data class Seen(val status: String?, val title: String)

    companion object {
        /** How long the game waits for you to do something before it ends. */
        const val PATIENCE: Long = 10 * 60 * 1000
        /** How long after your input a session's change still counts as yours. */
        const val TOUCH_WINDOW: Long = 3 * 60 * 1000
        /** Scoring again within this long raises the multiplier. */
        const val COMBO_WINDOW: Long = 90 * 1000
        const val MAX_COMBO = 5

        /** A game that starts with the queue as it is now. */
        fun start(rows: List<QueueRow>, now: Long): HerdGame {
            val statuses = mutableMapOf<String, Seen>()
            for (row in rows) {
                val session = row.session
                if (row.kind == QueueRow.Kind.Session && session != null) statuses[Herd.key(session)] = Seen(row.status, row.title)
            }
            return HerdGame(started = now, lastAction = now, statuses = statuses)
        }
    }

    fun copy(): HerdGame = HerdGame(
        started, score, combo, lastScored, lastAction, backToWork, answered, closed, outcome, ended, clearBonus, timeBonus,
        statuses.toMutableMap(), touched.toMutableMap(),
    )

    val isOver: Boolean get() = outcome != null

    /** When the game ends unless you do something. */
    val deadline: Long get() = lastAction + PATIENCE

    /**
     * The sessions astray, in the order to deal with them, counting those whose machine stopped
     * answering while astray.
     */
    fun strays(rows: List<QueueRow>): List<QueueRow> = Herd.strays(rows.map { row ->
        val session = row.session
        val seen = session?.let { statuses[Herd.key(it)] }
        if (row.kind == QueueRow.Kind.Session && row.status == "stale" && seen != null && Herd.stray(seen.status) != null) {
            row.copy(status = seen.status)
        } else {
            row
        }
    })

    /** You typed into a session from the phone: what it does next scores, and the countdown starts again. */
    fun touch(session: RemoteSessionID, now: Long) {
        if (isOver) return
        touched[Herd.key(session)] = now
        lastAction = maxOf(lastAction, now)
    }

    /**
     * Stops the clock for a while, such as while the phone can't reach the Mac: you can't do
     * anything then, so the time doesn't count.
     */
    fun hold(millis: Long) {
        if (isOver || millis <= 0) return
        started += millis
        lastAction += millis
    }

    /** Ends the game when the countdown ran out. Returns the event when it did. */
    fun expire(now: Long): HerdEvent? {
        if (isOver || now < deadline) return null
        outcome = Outcome.TimeUp
        ended = deadline
        return HerdEvent(HerdEvent.Kind.TimeUp, "", 0)
    }

    fun giveUp(now: Long) {
        if (isOver) return
        outcome = Outcome.GaveUp
        ended = now
    }

    /** Scores what changed since the last snapshot, and wins the game once nothing is astray. */
    fun observe(rows: List<QueueRow>, now: Long): List<HerdEvent> {
        expire(now)?.let { return listOf(it) }
        if (isOver) return emptyList()
        touched = touched.filterValues { now - it <= TOUCH_WINDOW }.toMutableMap()
        val current = LinkedHashMap<String, QueueRow>()
        for (row in rows) {
            val session = row.session
            if (row.kind == QueueRow.Kind.Session && session != null) current[Herd.key(session)] = row
        }
        val events = mutableListOf<HerdEvent>()

        for ((key, row) in current.entries.sortedBy { it.key }) {
            val before = statuses[key]
            if (row.status == "stale") continue
            val was = before?.let { Herd.stray(it.status) }
            if (Herd.stray(row) != null && was == null) {
                events += HerdEvent(HerdEvent.Kind.Strayed, row.title, 0)
            }
            if (before != null && before.status != row.status && was != null && touched[key] != null) {
                if (was == Herd.Stray.NeedsYou && row.status != "needsYou") {
                    events += score(HerdEvent.Kind.Answered, Points.ANSWERED, row.title, key, now)
                } else if (Herd.isMoving(row.status)) {
                    events += score(HerdEvent.Kind.BackToWork, Points.BACK_TO_WORK, row.title, key, now)
                }
            }
            statuses[key] = Seen(row.status, row.title)
        }

        for ((key, before) in statuses.entries.sortedBy { it.key }.map { it.key to it.value }) {
            if (current.containsKey(key)) continue
            statuses.remove(key)
            val was = Herd.stray(before.status) ?: continue
            if (touched[key] == null) continue
            // Closing a session that still needed you clears it, but only finished work scores.
            events += score(HerdEvent.Kind.Closed, if (was == Herd.Stray.NeedsYou) 0 else Points.CLOSED, before.title, key, now)
        }

        if (strays(rows).isEmpty()) {
            outcome = Outcome.Cleared
            ended = now
            clearBonus = Points.CLEARED
            timeBonus = maxOf(0, 30 - ((now - started) / 60_000).toInt()) * Points.PER_MINUTE_LEFT
            score += clearBonus + timeBonus
            events += HerdEvent(HerdEvent.Kind.Cleared, "", clearBonus + timeBonus)
        }
        return events
    }

    private fun score(kind: HerdEvent.Kind, base: Int, title: String, key: String, now: Long): HerdEvent {
        touched.remove(key)
        lastAction = maxOf(lastAction, now)
        when (kind) {
            HerdEvent.Kind.BackToWork -> backToWork += 1
            HerdEvent.Kind.Answered -> answered += 1
            HerdEvent.Kind.Closed -> closed += 1
            else -> {}
        }
        if (base <= 0) return HerdEvent(kind, title, 0)
        val last = lastScored
        combo = if (last != null && now - last <= COMBO_WINDOW) minOf(combo + 1, MAX_COMBO) else 1
        lastScored = now
        val points = base * combo
        score += points
        return HerdEvent(kind, title, points, combo)
    }

    override fun equals(other: Any?): Boolean = other is HerdGame &&
        started == other.started && score == other.score && combo == other.combo && lastScored == other.lastScored &&
        lastAction == other.lastAction && backToWork == other.backToWork && answered == other.answered &&
        closed == other.closed && outcome == other.outcome && ended == other.ended && clearBonus == other.clearBonus &&
        timeBonus == other.timeBonus && statuses == other.statuses && touched == other.touched

    override fun hashCode(): Int = listOf(started, score, combo, lastAction, outcome, statuses, touched).hashCode()
}

/** An entry in the table of the ten best scores. */
@Serializable
data class HerdScore(
    /** Three letters, as an arcade's table takes them. */
    val initials: String,
    val score: Int,
    /** When it was made; null for the table's starting entries. */
    val date: Long? = null,
)

object HerdScores {
    const val SIZE = 10

    /** The letters an initial can be, in the order the arrows go through them. */
    val alphabet: List<Char> = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789. ".toList()

    /** The table before anyone plays, to have something to beat. */
    val starting: List<HerdScore> = listOf(
        "DOG" to 3000, "BAA" to 2500, "TTY" to 2000, "SSH" to 1500, "GIT" to 1200,
        "CLI" to 1000, "ZZZ" to 800, "ACK" to 600, "NOP" to 400, "EOF" to 200,
    ).map { HerdScore(it.first, it.second) }

    /**
     * Where a score would go in the table, or null when it doesn't make it. A score that ties
     * goes under the ones already there.
     */
    fun rank(score: Int, table: List<HerdScore>): Int? {
        if (score <= 0) return null
        val index = table.indexOfFirst { it.score < score }.let { if (it < 0) table.size else it }
        return if (index < SIZE) index else null
    }

    /** The table with the entry in its place, and that place; the table as it was when the score doesn't make it. */
    fun inserting(entry: HerdScore, table: List<HerdScore>): Pair<List<HerdScore>, Int?> {
        val rank = rank(entry.score, table) ?: return table to null
        val updated = table.toMutableList()
        updated.add(rank, entry.copy(initials = initials(entry.initials)))
        return updated.take(SIZE) to rank
    }

    /** Three letters from the alphabet, uppercase, padded with spaces. */
    fun initials(text: String): String {
        val letters = text.uppercase().map { if (it in alphabet) it else ' ' }
        return (letters + List(3) { ' ' }).take(3).joinToString("")
    }
}
