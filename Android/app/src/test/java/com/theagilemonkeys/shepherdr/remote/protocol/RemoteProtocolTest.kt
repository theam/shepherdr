package com.theagilemonkeys.shepherdr.remote.protocol

import kotlinx.serialization.json.Json
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The fixture `golden-protocol.txt` is what the Mac's own Swift code (theam/shepherdr,
 * Sources/ShepherdrRemote) encodes for these messages, so these tests check that both sides read
 * each other.
 */
class RemoteProtocolTest {
    private val golden: Map<String, List<String>> = run {
        val lines = javaClass.classLoader!!.getResource("golden-protocol.txt")!!.readText().lines()
        val sections = linkedMapOf<String, MutableList<String>>()
        var current = ""
        for (line in lines) {
            if (line.startsWith("#")) current = line.drop(1).also { sections[it] = mutableListOf() }
            else if (line.isNotBlank()) sections.getValue(current) += line
        }
        sections
    }

    private val pane = RemoteSessionID("remote:buildbox", "term_1")

    @Test
    fun clientMessagesEncodeAsTheMacDoes() {
        val messages = listOf(
            ClientMessage.Hello("d", "t", 1), ClientMessage.Pair("c", "Phone", 1),
            ClientMessage.Attach(3, pane, 52, 30), ClientMessage.TakeOver(3), ClientMessage.Detach(3),
            ClientMessage.Input(3, byteArrayOf(27, 0, -1)), ClientMessage.Resize(3, 60, 20), ClientMessage.Scroll(3, true, 10),
            ClientMessage.Prompt(pane, "fix the flaky test\nplease"), ClientMessage.CompassRun, ClientMessage.CompassCancel,
            ClientMessage.CompassPage(null), ClientMessage.CompassPage("2026-11-02"), ClientMessage.Ping,
        )
        val expected = golden.getValue("CLIENT")
        assertEquals(expected.size, messages.size)
        messages.zip(expected).forEach { (message, json) ->
            assertEquals(Json.parseToJsonElement(json), Json.parseToJsonElement(RemoteCodec.encode(message)))
        }
    }

    @Test
    fun serverMessagesDecodeFromTheMac() {
        val decoded = golden.getValue("SERVER").map { RemoteCodec.decodeServer(it) }
        assertEquals(ServerMessage.Welcome("Studio", 1), decoded[0])
        assertEquals(ServerMessage.Paired("d", "t", "Studio"), decoded[1])
        assertEquals(ServerMessage.Refused("No"), decoded[2])
        val snapshot = (decoded[3] as ServerMessage.Queue).snapshot
        assertEquals("Studio", snapshot.macName)
        assertEquals(listOf(RemoteMachine("local", "Local", "online", true)), snapshot.machines)
        val row = snapshot.rows[0]
        assertEquals(
            QueueRow(
                id = "s:1", kind = QueueRow.Kind.Session, session = pane, number = 1, depth = 2, title = "fix-login", status = "needsYou",
                panes = listOf(RemotePane(pane, "claude", true)), tree = QueueTree(1, listOf(true), false, 2), inGroup = true, inProject = true,
                resources = listOf(
                    RemoteResource(
                        RemoteResource.Kind.PullRequest, "theam/shepherdr#12", "Fix login",
                        "https://github.com/theam/shepherdr/pull/12", "open", "passed",
                    ),
                ),
            ),
            row,
        )
        assertEquals(QueueRow(id = "g:1", kind = QueueRow.Kind.Group, title = "Release", needsYou = 2), snapshot.rows[1])
        val compass = snapshot.compass!!
        assertEquals("✓ updated 09:00", compass.activity)
        assertEquals(800_000_000.0, compass.pageModified!!, 0.0)
        assertEquals(listOf("2026-11-02", "2026-11-01"), compass.days)
        assertEquals(row, compass.agent)
        assertTrue(compass.hasNews)
        assertEquals(ServerMessage.Terminal(3, RemoteTerminalState.ControlledElsewhere, null), decoded[4])
        assertEquals(ServerMessage.Terminal(4, RemoteTerminalState.Ended, "bye"), decoded[5])
        assertEquals(ServerMessage.Reset(3), decoded[6])
        assertEquals(ServerMessage.Failure("x"), decoded[7])
        assertEquals(ServerMessage.CompassPage("2026-11-02", "<h1>Today</h1>"), decoded[8])
        assertEquals(ServerMessage.CompassPage("2026-10-30", null), decoded[9])
        assertEquals(ServerMessage.Pong, decoded[10])
    }

    @Test
    fun unknownOrBrokenMessagesAreSkipped() {
        assertNull(RemoteCodec.decodeServer("""{"somethingNew":{}}"""))
        assertNull(RemoteCodec.decodeServer("not json"))
        assertNull(RemoteCodec.decodeServer("""{"welcome":{}}"""))
    }

    @Test
    fun rowsFromAMacWithoutLinesOrResourcesStillRead() {
        val json = """{"id":"s:1","kind":"session","title":"fix-login","depth":1,"needsYou":0,"panes":[]}"""
        val row = RemoteProtocol.json.decodeFromString(QueueRow.serializer(), json)
        assertEquals("fix-login", row.title)
        assertEquals(1, row.depth)
        assertTrue(!row.inGroup && !row.inProject && row.resources.isEmpty() && row.tree == null)
    }

    @Test
    fun searchFindsSessionsByEveryWordTheirResourcesAndMachine() {
        val local = RemoteSessionID("local", "t1")
        val other = RemoteSessionID("remote:box", "t2")
        val rows = listOf(
            QueueRow(id = "g:1", kind = QueueRow.Kind.Group, title = "Release"),
            QueueRow(
                id = "s:1", kind = QueueRow.Kind.Session, session = local, number = 1, depth = 1, title = "fix-login",
                summary = "Wants to edit session.ts", agent = "claude", machine = "Local", status = "needsYou",
                resources = listOf(
                    RemoteResource(
                        RemoteResource.Kind.PullRequest, "theam/shepherdr#29", "Carry out each letter once",
                        "https://github.com/theam/shepherdr/pull/29",
                    ),
                ),
            ),
            QueueRow(
                id = "s:2", kind = QueueRow.Kind.Session, session = other, number = 2, title = "api-tests", agent = "codex",
                machine = "buildbox", status = "working",
            ),
        )
        fun ids(query: String) = QueueSearch.rows(rows, query).map { it.id }
        assertEquals(3, QueueSearch.rows(rows, "").size)
        assertEquals(listOf("s:1"), ids("login claude"))
        assertEquals(listOf("s:1"), ids("#29"))
        assertEquals(listOf("s:1"), ids("letter"))
        assertEquals(listOf("s:1"), ids("needs you"))
        assertEquals(listOf("s:2"), ids("@build"))
        assertTrue(ids("release").isEmpty())
        assertTrue(ids("login codex").isEmpty())
    }

    @Test
    fun framesRoundTripThroughTheirBinaryHeader() {
        val frame = RemoteFrame(70_000, true, 300, 41, "\u001b[2Jhola".toByteArray())
        val encoded = frame.encoded()
        assertEquals(9 + frame.bytes.size, encoded.size)
        val decoded = RemoteFrame.decode(encoded)!!
        assertEquals(70_000, decoded.channel)
        assertTrue(decoded.isFull)
        assertEquals(300, decoded.columns)
        assertEquals(41, decoded.rows)
        assertArrayEquals(frame.bytes, decoded.bytes)
        assertNull(RemoteFrame.decode(byteArrayOf(0, 1)))
    }

    @Test
    fun invitesReadTheMacsLink() {
        val link = golden.getValue("INVITE").single()
        val invite = PairingInvite(
            "Javier’s MacBook Pro", listOf("100.101.102.103", "192.168.1.20"), 1337, "abc-_123", "c0de",
        )
        assertEquals(invite, PairingInvite.parse(link))
        assertEquals(invite, PairingInvite.parse("  $link\n"))
        assertEquals(invite, PairingInvite.parse(invite.url))
        assertNull(PairingInvite.parse("https://example.com/pair?h=a&p=1&f=x&c=y&n=z"))
        assertNull(PairingInvite.parse("shepherdr-remote://pair?n=x&h=&p=1337&f=x&c=y"))
        assertNull(PairingInvite.parse("shepherdr-remote://pair?n=x&h=a&p=0&f=x&c=y"))
    }

    @Test
    fun sessionLinksOpenASession() {
        assertEquals(RemoteSessionID("remote:box", "t 2"), SessionLink.session("shepherdr-remote://session?m=remote:box&t=t%202"))
        assertNull(SessionLink.session("shepherdr-remote://pair?m=a&t=b"))
        assertNull(SessionLink.session("shepherdr-remote://session?m=a"))
    }

    @Test
    fun fingerprintsMatchTheMacs() {
        val point = byteArrayOf(4) + ByteArray(64) { (it + 1).toByte() }
        assertEquals(golden.getValue("FINGERPRINT").single(), RemoteCrypto.fingerprint(point))
    }

    @Test
    fun tokensAreRandomBase64Url() {
        val a = RemoteCrypto.randomToken()
        val b = RemoteCrypto.randomToken()
        assertTrue(a != b)
        assertEquals(43, a.length)
        assertTrue(!a.contains("=") && !a.contains("+") && !a.contains("/"))
    }
}
