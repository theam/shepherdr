package com.theagilemonkeys.shepherdr.remote.protocol

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Mac's HerdTests (theam/shepherdr, Tests/ShepherdrCoreTests/HerdTests.swift), in Kotlin. */
class HerdTest {
    private val start = 1_800_000_000_000L

    private fun id(terminal: String) = RemoteSessionID("local", terminal)

    private fun row(
        terminal: String, status: String?, number: Int = 1, kind: QueueRow.Kind = QueueRow.Kind.Session,
        panes: List<RemotePane> = emptyList(),
    ) = QueueRow(
        id = terminal, kind = kind, session = if (kind == QueueRow.Kind.Group) null else id(terminal), number = number,
        title = "s-$terminal", status = status, panes = panes,
    )

    private fun at(seconds: Long) = start + seconds * 1000

    private fun event(kind: HerdEvent.Kind, title: String, points: Int, combo: Int = 1) = HerdEvent(kind, title, points, combo)

    @Test
    fun straysNeedYouFirstThenDoneThenIdleEachInTheQueuesOrder() {
        val rows = listOf(
            row("g", null, kind = QueueRow.Kind.Group), row("a", "idle", 1), row("b", "working", 2), row("c", "done", 3),
            row("d", "needsYou", 4), row("e", "unknown", 5), row("f", "needsYou", 6), row("h", "waiting", 7),
            row("i", "stale", 8), row("j", "finished", kind = QueueRow.Kind.Shell), row("k", "done", 9),
        )
        assertEquals(listOf("d", "f", "c", "k", "a", "e"), Herd.strays(rows).map { it.id })
    }

    @Test
    fun aPaneBelongsToTheSessionWhoseTabItSplits() {
        val rows = listOf(row("a", "idle", panes = listOf(RemotePane(id("a"), "claude", true), RemotePane(id("a2"), "shell", false))))
        assertEquals(id("a"), Herd.session(id("a2"), rows))
        assertEquals(id("a"), Herd.session(id("a"), rows))
        assertNull(Herd.session(id("zz"), rows))
    }

    @Test
    fun onlyWhatYouTouchedScores() {
        val game = HerdGame.start(listOf(row("a", "idle"), row("b", "done"), row("c", "idle")), start)
        game.touch(id("a"), at(5))
        val events = game.observe(listOf(row("a", "working"), row("b", "working"), row("c", "idle")), at(10))
        assertEquals(listOf(event(HerdEvent.Kind.BackToWork, "s-a", 10)), events)
        assertEquals(10, game.score)
        assertEquals(1, game.backToWork)
        // The touch is spent: the next time a stops and starts again by itself, nothing scores.
        game.observe(listOf(row("a", "done"), row("b", "working"), row("c", "idle")), at(20))
        assertTrue(game.observe(listOf(row("a", "working"), row("b", "working"), row("c", "idle")), at(30)).isEmpty())
    }

    @Test
    fun answeringScoresFiftyAndCombosMultiply() {
        val game = HerdGame.start(listOf(row("a", "needsYou"), row("b", "needsYou"), row("c", "idle"), row("x", "idle")), start)
        game.touch(id("a"), at(1))
        assertEquals(
            listOf(event(HerdEvent.Kind.Answered, "s-a", 50)),
            game.observe(listOf(row("a", "working"), row("b", "needsYou"), row("c", "idle"), row("x", "idle")), at(2)),
        )
        game.touch(id("b"), at(30))
        // Answering a question can also leave the agent done at once: it still counts.
        assertEquals(
            listOf(event(HerdEvent.Kind.Answered, "s-b", 100, 2)),
            game.observe(listOf(row("a", "working"), row("b", "done"), row("c", "idle"), row("x", "idle")), at(40)),
        )
        game.touch(id("c"), at(200))
        // Too long after the last points: the combo starts over.
        assertEquals(
            listOf(event(HerdEvent.Kind.BackToWork, "s-c", 10)),
            game.observe(listOf(row("a", "working"), row("b", "done"), row("c", "working"), row("x", "idle")), at(210)),
        )
        assertEquals(160, game.score)
        assertEquals(2, game.answered)
    }

    @Test
    fun closingAFinishedSessionScoresAHundredAndOneThatNeededYouNothing() {
        val game = HerdGame.start(listOf(row("a", "done"), row("b", "needsYou"), row("c", "idle"), row("x", "idle")), start)
        game.touch(id("a"), at(1))
        game.touch(id("b"), at(1))
        val events = game.observe(listOf(row("c", "idle"), row("x", "idle")), at(5))
        assertEquals(listOf(event(HerdEvent.Kind.Closed, "s-a", 100), event(HerdEvent.Kind.Closed, "s-b", 0)), events)
        assertEquals(2, game.closed)
        // A session that ends without you touching it doesn't score.
        assertTrue(game.observe(listOf(row("x", "idle")), at(6)).isEmpty())
    }

    @Test
    fun touchesExpire() {
        val game = HerdGame.start(listOf(row("a", "idle"), row("x", "idle")), start)
        game.touch(id("a"), at(0))
        assertTrue(game.observe(listOf(row("a", "working"), row("x", "idle")), start + HerdGame.TOUCH_WINDOW + 1000).isEmpty())
    }

    @Test
    fun sessionsThatStopAreAnnounced() {
        val game = HerdGame.start(listOf(row("a", "working"), row("x", "idle")), start)
        assertEquals(
            listOf(event(HerdEvent.Kind.Strayed, "s-a", 0), event(HerdEvent.Kind.Strayed, "s-n", 0)),
            game.observe(listOf(row("a", "done"), row("x", "idle"), row("n", "idle")), at(5)),
        )
        // done → idle is only someone looking at it.
        assertTrue(game.observe(listOf(row("a", "idle"), row("x", "idle"), row("n", "idle")), at(6)).isEmpty())
    }

    @Test
    fun clearingTheQueueWinsWithABonusForTheTimeLeft() {
        val game = HerdGame.start(listOf(row("a", "needsYou"), row("b", "working"), row("s", "stale")), start)
        game.touch(id("a"), at(5 * 60))
        val events = game.observe(listOf(row("a", "working"), row("b", "working"), row("s", "stale")), at(5 * 60 + 30))
        assertEquals(event(HerdEvent.Kind.Cleared, "", 500 + 250), events.last())
        assertEquals(HerdGame.Outcome.Cleared, game.outcome)
        assertEquals(50 + 750, game.score)
        assertEquals(250, game.timeBonus)
        assertTrue(game.observe(listOf(row("a", "done")), at(400)).isEmpty())
    }

    @Test
    fun aSessionAstrayWhoseMachineStopsAnsweringStillHasToBeHerded() {
        val game = HerdGame.start(listOf(row("a", "idle"), row("b", "working")), start)
        assertTrue(game.observe(listOf(row("a", "stale"), row("b", "working")), at(5)).isEmpty())
        assertEquals(listOf("idle"), game.strays(listOf(row("a", "stale"), row("b", "working"))).map { it.status })
        game.touch(id("a"), at(10))
        // Back online and working: it was idle all along, so it scores and clears the queue.
        val events = game.observe(listOf(row("a", "working"), row("b", "working")), at(20))
        assertEquals(listOf(HerdEvent.Kind.BackToWork, HerdEvent.Kind.Cleared), events.map { it.kind })
    }

    @Test
    fun tenMinutesWithoutDoingAnythingEndTheGame() {
        val game = HerdGame.start(listOf(row("a", "idle"), row("b", "idle")), start)
        assertNull(game.expire(start + HerdGame.PATIENCE - 1000))
        game.touch(id("a"), at(300))
        assertEquals(at(300) + HerdGame.PATIENCE, game.deadline)
        assertNull(game.expire(start + HerdGame.PATIENCE + 1000))
        assertEquals(
            listOf(HerdEvent.Kind.TimeUp),
            game.observe(listOf(row("a", "working"), row("b", "idle")), at(300) + HerdGame.PATIENCE).map { it.kind },
        )
        assertEquals(HerdGame.Outcome.TimeUp, game.outcome)
        assertEquals(at(300) + HerdGame.PATIENCE, game.ended)
        assertEquals(0, game.score)
    }

    @Test
    fun theClockStopsWhileHeld() {
        val game = HerdGame.start(listOf(row("a", "idle"), row("b", "idle")), start)
        game.hold(120_000)
        assertEquals(at(120) + HerdGame.PATIENCE, game.deadline)
        assertNull(game.expire(start + HerdGame.PATIENCE + 60_000))
        // The time bonus counts only the time you could play.
        game.touch(id("a"), at(120 + 10))
        game.touch(id("b"), at(120 + 10))
        game.observe(listOf(row("a", "working"), row("b", "working")), at(120 + 30))
        assertEquals(300, game.timeBonus)
    }

    @Test
    fun givingUpEndsTheGameWithItsScore() {
        val game = HerdGame.start(listOf(row("a", "idle"), row("b", "idle")), start)
        game.touch(id("a"), at(1))
        game.observe(listOf(row("a", "working"), row("b", "idle")), at(2))
        game.giveUp(at(3))
        assertEquals(HerdGame.Outcome.GaveUp, game.outcome)
        assertEquals(10, game.score)
        assertTrue(game.observe(listOf(row("a", "working"), row("b", "working")), at(4)).isEmpty())
    }

    @Test
    fun gamesSurviveARelaunch() {
        val game = HerdGame.start(listOf(row("a", "idle"), row("b", "idle")), start)
        game.touch(id("a"), at(1))
        val restored = Json.decodeFromString(HerdGame.serializer(), Json.encodeToString(HerdGame.serializer(), game))
        assertEquals(game, restored)
        assertEquals(listOf(10), restored.observe(listOf(row("a", "working"), row("b", "idle")), at(2)).map { it.points })
    }

    @Test
    fun copiesAreIndependent() {
        val game = HerdGame.start(listOf(row("a", "idle"), row("b", "idle")), start)
        val copy = game.copy()
        copy.touch(id("a"), at(1))
        copy.observe(listOf(row("a", "working"), row("b", "idle")), at(2))
        assertEquals(0, game.score)
        assertEquals(10, copy.score)
    }

    @Test
    fun theTableKeepsTheTenBestAndTiesGoUnder() {
        val table = HerdScores.starting
        assertEquals(10, table.size)
        assertEquals(0, HerdScores.rank(5000, table))
        assertEquals(2, HerdScores.rank(2500, table))
        assertEquals(9, HerdScores.rank(201, table))
        assertNull(HerdScores.rank(200, table))
        assertNull(HerdScores.rank(0, emptyList()))
        assertEquals(0, HerdScores.rank(1, emptyList()))
        val (inserted, rank) = HerdScores.inserting(HerdScore("jt", 1300), table)
        assertEquals(4, rank)
        assertEquals(10, inserted.size)
        assertEquals(HerdScore("JT ", 1300), inserted[4])
        assertEquals("NOP", inserted.last().initials)
        assertEquals("A B", HerdScores.initials("a-b/c"))
    }
}
