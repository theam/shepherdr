package com.theagilemonkeys.shepherdr.remote.protocol

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.Base64

/**
 * The relay's wire protocol: one WebSocket over TLS between Shepherdr on the Mac and Shepherdr
 * Remote on a phone. Control travels as JSON text messages; terminal frames as binary ones.
 *
 * The Mac speaks Swift's synthesized `Codable`: an enum case is an object with one key, the case's
 * name, holding its associated values by label (`_0` when unlabeled); `Data` is standard base64 and
 * `Date` is seconds since 2001-01-01.
 */
object RemoteProtocol {
    /** Bumped whenever a message changes in a way the other side can't read. */
    const val VERSION = 1
    const val DEFAULT_PORT = 1337

    val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        coerceInputValues = true
        encodeDefaults = true
    }
}

/** A session or a pane on one of the Mac's machines, as Shepherdr addresses it. */
@Serializable
data class RemoteSessionID(val machineID: String, val terminalID: String)

/** What the phone sends. */
sealed interface ClientMessage {
    /** The first message of a paired phone: its token proves who it is. */
    data class Hello(val deviceID: String, val token: String, val version: Int = RemoteProtocol.VERSION) : ClientMessage
    /** The first message of a phone that scanned a pairing code. */
    data class Pair(val code: String, val deviceName: String, val version: Int = RemoteProtocol.VERSION) : ClientMessage
    /** Streams a pane's terminal on a channel the phone numbers, at the phone's size. */
    data class Attach(val channel: Int, val pane: RemoteSessionID, val columns: Int, val rows: Int) : ClientMessage
    /** Takes control of a pane another client controls. Only ever the user's explicit choice. */
    data class TakeOver(val channel: Int) : ClientMessage
    data class Detach(val channel: Int) : ClientMessage
    /** Keys typed into the terminal, as the terminal encodes them. */
    class Input(val channel: Int, val bytes: ByteArray) : ClientMessage
    data class Resize(val channel: Int, val columns: Int, val rows: Int) : ClientMessage
    /** Scrolls through the history Herdr keeps for the terminal. */
    data class Scroll(val channel: Int, val up: Boolean, val lines: Int) : ClientMessage
    /** A composed prompt for the agent in a pane, typed as a paste followed by Return. */
    data class Prompt(val pane: RemoteSessionID, val text: String) : ClientMessage
    /** Compass: a run now, as the Mac's ▶ RUN button does. */
    data object CompassRun : ClientMessage
    /** Compass: stop waiting for the open run. The agent keeps whatever it is doing. */
    data object CompassCancel : ClientMessage
    /** Compass: a day's page (`2026-11-02`), or today's when null. */
    data class CompassPage(val day: String?) : ClientMessage
    data object Ping : ClientMessage
}

/** What the Mac sends. */
sealed interface ServerMessage {
    data class Welcome(val macName: String, val version: Int) : ServerMessage
    /** Pairing worked: the phone keeps the token and says hello with it from now on. */
    data class Paired(val deviceID: String, val token: String, val macName: String) : ServerMessage
    /** The connection is refused, and why. The Mac closes it afterwards. */
    data class Refused(val reason: String) : ServerMessage
    data class Queue(val snapshot: QueueSnapshot) : ServerMessage
    data class Terminal(val channel: Int, val state: RemoteTerminalState, val message: String?) : ServerMessage
    /** The terminal starts over: clear the screen before the next frame. */
    data class Reset(val channel: Int) : ServerMessage
    /** Something the phone asked for didn't work. */
    data class Failure(val message: String) : ServerMessage
    /** The Compass page the phone asked for, or null when that day has none. */
    data class CompassPage(val day: String, val html: String?) : ServerMessage
    data object Pong : ServerMessage
}

@Serializable
enum class RemoteTerminalState {
    @SerialName("connecting") Connecting,
    /** The phone's keys reach the terminal. */
    @SerialName("control") Control,
    /** Another client controls the terminal: the phone watches and may take over. */
    @SerialName("controlledElsewhere") ControlledElsewhere,
    @SerialName("observing") Observing,
    /** Herdr ended the terminal, or the Mac stopped streaming it. */
    @SerialName("ended") Ended,
    @SerialName("failed") Failed,
}

/**
 * Shepherdr's queue as the Mac's sidebar lists it, flattened for a phone: groups, project headings,
 * sessions with the sessions they wait for nested under them, and shells.
 */
@Serializable
data class QueueSnapshot(
    val macName: String,
    val machines: List<RemoteMachine> = emptyList(),
    val rows: List<QueueRow> = emptyList(),
    /** Compass, once it is set up on the Mac. */
    val compass: RemoteCompass? = null,
)

/**
 * Compass as the Mac's column shows it: what its agent is doing, when it runs next, and the agent
 * itself. Pages travel on request, with `compassPage`.
 */
@Serializable
data class RemoteCompass(
    /** `● running since 10:02`, `✓ updated 09:00`, `! needs you in its terminal`… */
    val activity: String,
    val needsYou: Boolean = false,
    /** A run is under way: another can't start, and this one can be cancelled. */
    val isRunning: Boolean = false,
    /** `next run 14:00`, `runs when you ask`… */
    val next: String = "",
    val problem: String? = null,
    /** Today's page changed since you last looked at it on the Mac. */
    val hasNews: Boolean = false,
    /** When today's page last changed, in seconds since 2001-01-01, to fetch it again. */
    val pageModified: Double? = null,
    val today: String,
    /** The days with a page, newest first. */
    val days: List<String> = emptyList(),
    /** The Compass agent's session, to open its terminal; null until it starts. */
    val agent: QueueRow? = null,
)

/** One of a session's resources, as the Mac's Resources column lists it. */
@Serializable
data class RemoteResource(
    val kind: Kind,
    /** `theam/shepherdr#12`, `ENG-42`… */
    val name: String,
    /** The page's title, once the Mac checked it. */
    val title: String? = null,
    val url: String,
    /** `open`, `merged` or `closed`, when the Mac knows. */
    val state: String? = null,
    /** A pull request's checks: `passed`, `failed` or `running`. */
    val checks: String? = null,
) {
    val id: String get() = url

    @Serializable
    enum class Kind {
        @SerialName("pullRequest") PullRequest,
        @SerialName("issue") Issue,
        @SerialName("artifact") Artifact,
        @SerialName("link") Link,
        @SerialName("repository") Repository,
    }
}

@Serializable
data class RemoteMachine(
    val id: String,
    val name: String,
    /** Online, loading, unreachable…, as Shepherdr words it. */
    val connection: String = "",
    val isOnline: Boolean = false,
)

@Serializable
data class QueueRow(
    /** Unique within a snapshot. */
    val id: String,
    val kind: Kind,
    /** Sessions and shells; null for headings. */
    val session: RemoteSessionID? = null,
    /** The session's place in the queue, counting from 1. */
    val number: Int? = null,
    /** 0 at the top level; one more inside a group, a project or under a session waiting for it. */
    val depth: Int = 0,
    /** The session's name, or the heading's. */
    val title: String,
    /** What the agent last said, or Herdr's summary. */
    val summary: String? = null,
    /** The agent's kind, such as `claude`. */
    val agent: String? = null,
    val machine: String? = null,
    /** A `SessionStatus` raw value: `needsYou`, `working`, `waiting`, `done`, `idle`, `stale`… */
    val status: String? = null,
    /** For headings: how many of their sessions need you. */
    val needsYou: Int = 0,
    /** The panes of the session's Herdr tab, its own first; one for a session without splits. */
    val panes: List<RemotePane> = emptyList(),
    /** Where the session sits in its tree of sessions on hold. Null outside such a tree. */
    val tree: QueueTree? = null,
    /** Inside a group, under its heading: the group's line runs down beside it. */
    val inGroup: Boolean = false,
    /** Under a project's heading: the project's line runs down beside it. */
    val inProject: Boolean = false,
    /** The session's pull requests, issues and links, the most relevant first. */
    val resources: List<RemoteResource> = emptyList(),
) {
    @Serializable
    enum class Kind {
        @SerialName("group") Group,
        @SerialName("project") Project,
        @SerialName("session") Session,
        @SerialName("shell") Shell,
        @SerialName("section") Section,
    }
}

/**
 * A session's place in a tree of sessions on hold: each awaited session nested under the session
 * waiting for it, as the Mac's sidebar draws it.
 */
@Serializable
data class QueueTree(
    /** 0 for the session at the top of the tree, one more for each level under it. */
    val depth: Int,
    /** For each level between the top and this session, whether a line passes by. */
    val guides: List<Boolean> = emptyList(),
    /** The last session nested under its parent ends the parent's line. */
    val isLast: Boolean = false,
    /** How many sessions are nested directly under this one. */
    val nested: Int = 0,
)

@Serializable
data class RemotePane(
    val pane: RemoteSessionID,
    /** The agent's name and kind, or the shell's title. */
    val title: String,
    val isAgent: Boolean = false,
) {
    val id: String get() = pane.terminalID
}

/**
 * Searching the queue as the Mac's ⌘T does: the sessions and shells with every word typed in
 * their name, summary, agent, panes, state or resources, and `@name` for a machine; in the
 * queue's order, without headings.
 */
object QueueSearch {
    fun rows(rows: List<QueueRow>, query: String): List<QueueRow> {
        val words = query.lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (words.isEmpty()) return rows
        return rows.filter { row ->
            if (row.session == null) return@filter false
            val text = (listOf(row.title, row.summary, row.agent, row.machine, row.status, statusWords(row.status)) +
                row.panes.map { it.title } + row.resources.flatMap { listOf(it.name, it.title) })
                .filterNotNull().joinToString(" ").lowercase()
            words.all { word ->
                if (word.startsWith("@") && word.length > 1) (row.machine ?: "").lowercase().contains(word.drop(1))
                else text.contains(word)
            }
        }
    }

    /** The words the phone shows for a status, such as `needs you` for `needsYou`. */
    fun statusWords(status: String?): String? = when (status) {
        "needsYou" -> "needs you"
        "waiting" -> "on hold"
        else -> status
    }
}

/**
 * A terminal frame as a binary WebSocket message: a 9-byte header (channel, flags, columns, rows,
 * big endian) and then Herdr's ANSI bytes.
 */
class RemoteFrame(
    val channel: Int,
    /** The frame repaints the whole screen. */
    val isFull: Boolean,
    val columns: Int,
    val rows: Int,
    val bytes: ByteArray,
) {
    fun encoded(): ByteArray {
        val out = ByteArray(9 + bytes.size)
        out[0] = (channel ushr 24).toByte()
        out[1] = (channel ushr 16).toByte()
        out[2] = (channel ushr 8).toByte()
        out[3] = channel.toByte()
        out[4] = if (isFull) 1 else 0
        val c = columns.coerceIn(0, 0xFFFF)
        val r = rows.coerceIn(0, 0xFFFF)
        out[5] = (c ushr 8).toByte()
        out[6] = c.toByte()
        out[7] = (r ushr 8).toByte()
        out[8] = r.toByte()
        bytes.copyInto(out, 9)
        return out
    }

    companion object {
        fun decode(data: ByteArray): RemoteFrame? {
            if (data.size < 9) return null
            fun u(i: Int) = data[i].toInt() and 0xFF
            val channel = (u(0) shl 24) or (u(1) shl 16) or (u(2) shl 8) or u(3)
            return RemoteFrame(
                channel = channel,
                isFull = u(4) and 1 == 1,
                columns = (u(5) shl 8) or u(6),
                rows = (u(7) shl 8) or u(8),
                bytes = data.copyOfRange(9, data.size),
            )
        }
    }
}

/** Reads and writes the protocol's JSON as the Mac's Swift `Codable` does. */
object RemoteCodec {
    private val json = RemoteProtocol.json

    fun encode(message: ClientMessage): String {
        val (name, body) = when (message) {
            is ClientMessage.Hello -> "hello" to buildJsonObject {
                put("deviceID", message.deviceID); put("token", message.token); put("version", message.version)
            }
            is ClientMessage.Pair -> "pair" to buildJsonObject {
                put("code", message.code); put("deviceName", message.deviceName); put("version", message.version)
            }
            is ClientMessage.Attach -> "attach" to buildJsonObject {
                put("channel", message.channel); put("pane", session(message.pane))
                put("columns", message.columns); put("rows", message.rows)
            }
            is ClientMessage.TakeOver -> "takeOver" to buildJsonObject { put("channel", message.channel) }
            is ClientMessage.Detach -> "detach" to buildJsonObject { put("channel", message.channel) }
            is ClientMessage.Input -> "input" to buildJsonObject {
                put("bytes", Base64.getEncoder().encodeToString(message.bytes)); put("channel", message.channel)
            }
            is ClientMessage.Resize -> "resize" to buildJsonObject {
                put("channel", message.channel); put("columns", message.columns); put("rows", message.rows)
            }
            is ClientMessage.Scroll -> "scroll" to buildJsonObject {
                put("channel", message.channel); put("lines", message.lines); put("up", message.up)
            }
            is ClientMessage.Prompt -> "prompt" to buildJsonObject { put("pane", session(message.pane)); put("text", message.text) }
            ClientMessage.CompassRun -> "compassRun" to JsonObject(emptyMap())
            ClientMessage.CompassCancel -> "compassCancel" to JsonObject(emptyMap())
            is ClientMessage.CompassPage -> "compassPage" to buildJsonObject { message.day?.let { put("day", it) } }
            ClientMessage.Ping -> "ping" to JsonObject(emptyMap())
        }
        return JsonObject(mapOf(name to body)).toString()
    }

    /** The Mac's message, or null when this phone can't read it. */
    fun decodeServer(text: String): ServerMessage? = try {
        val root = json.parseToJsonElement(text).jsonObject
        val (name, value) = root.entries.single()
        val body = value.jsonObject
        fun string(key: String) = body[key]?.jsonPrimitive?.contentOrNull
        fun int(key: String) = body[key]!!.jsonPrimitive.int
        when (name) {
            "welcome" -> ServerMessage.Welcome(string("macName")!!, body["version"]?.jsonPrimitive?.intOrNull ?: 0)
            "paired" -> ServerMessage.Paired(string("deviceID")!!, string("token")!!, string("macName")!!)
            "refused" -> ServerMessage.Refused(string("reason") ?: "")
            "queue" -> ServerMessage.Queue(decode(QueueSnapshot.serializer(), body["_0"]!!))
            "terminal" -> ServerMessage.Terminal(int("channel"), decode(RemoteTerminalState.serializer(), body["state"]!!), string("message"))
            "reset" -> ServerMessage.Reset(int("channel"))
            "failure" -> ServerMessage.Failure(string("message") ?: "")
            "compassPage" -> ServerMessage.CompassPage(string("day")!!, string("html"))
            "pong" -> ServerMessage.Pong
            else -> null
        }
    } catch (_: Exception) {
        null
    }

    /** The phone's message, as the Mac would read it; for tests. */
    fun decodeClient(text: String): Map<String, JsonObject> =
        json.parseToJsonElement(text).jsonObject.mapValues { it.value.jsonObject }

    private fun <T> decode(serializer: KSerializer<T>, element: JsonElement): T = json.decodeFromJsonElement(serializer, element)

    private fun session(id: RemoteSessionID): JsonObject = buildJsonObject {
        put("machineID", id.machineID); put("terminalID", id.terminalID)
    }
}
