package com.theagilemonkeys.shepherdr.remote.relay

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.theagilemonkeys.shepherdr.remote.protocol.ClientMessage
import com.theagilemonkeys.shepherdr.remote.protocol.PairingInvite
import com.theagilemonkeys.shepherdr.remote.protocol.QueueSnapshot
import com.theagilemonkeys.shepherdr.remote.protocol.RemoteCodec
import com.theagilemonkeys.shepherdr.remote.protocol.RemoteFrame
import com.theagilemonkeys.shepherdr.remote.protocol.RemoteSessionID
import com.theagilemonkeys.shepherdr.remote.protocol.RemoteTerminalState
import com.theagilemonkeys.shepherdr.remote.protocol.ServerMessage
import com.theagilemonkeys.shepherdr.remote.store.PairedMac
import com.theagilemonkeys.shepherdr.remote.store.PairedMacs
import com.theagilemonkeys.shepherdr.remote.ui.arcade.Arcade
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.min
import kotlin.math.pow

/**
 * The connection to Shepherdr on a Mac: one WebSocket over TLS, trusting only the certificate the
 * Mac showed when pairing. It keeps the queue the Mac sends and the terminals the phone shows.
 * Everything here runs on the main thread.
 */
class RelayClient(context: Context) {
    sealed interface Phase {
        data object Idle : Phase
        data object Connecting : Phase
        data object Connected : Phase
        data class Failed(val message: String) : Phase
    }

    private val appContext = context.applicationContext
    private val store = PairedMacs(appContext)

    var phase by mutableStateOf<Phase>(Phase.Idle)
        private set
    var queue by mutableStateOf<QueueSnapshot?>(null)
        private set
    var mac by mutableStateOf<PairedMac?>(null)
        private set
    /** A message for a moment, such as a prompt that didn't go through. */
    var notice by mutableStateOf<String?>(null)
    /** A session a link asked to open, once the queue shows it. */
    var pendingSession by mutableStateOf<RemoteSessionID?>(null)
    /** The last Compass page the Mac sent. */
    var compassPage by mutableStateOf<CompassPage?>(null)
        private set
    var macs by mutableStateOf(store.load())
        private set
    /** Herd mode's game, which follows the queue and what you type. */
    val arcade = Arcade(appContext) { phase == Phase.Connected }

    private val scope = MainScope()
    private var socket: WebSocket? = null
    private var receiving: Job? = null
    private var retrying: Job? = null
    private var heartbeat: Job? = null
    private var attempts = 0
    private val terminals = mutableMapOf<Int, RemoteTerminal>()
    private var nextChannel = 1
    /** Why the last address tried didn't answer, to say so. */
    private var lastProblem: String? = null
    /** Whether the app is in front: only then does it stay connected. */
    private var inForeground = true

    init {
        mac = macs.lastOrNull()
    }

    // Connecting

    fun start() {
        inForeground = true
        val mac = mac ?: return
        if (socket != null || receiving?.isActive == true) return
        open(Target.Hello(mac))
    }

    /** Android stops the app's work in the background, so the connection goes, and comes back on return. */
    fun suspend() {
        inForeground = false
        close()
        phase = Phase.Idle
    }

    fun select(mac: PairedMac) {
        close()
        this.mac = mac
        queue = null
        open(Target.Hello(mac))
    }

    fun forget(mac: PairedMac) {
        store.remove(mac)
        macs = store.load()
        if (this.mac?.id == mac.id) {
            close()
            this.mac = macs.lastOrNull()
            queue = null
            phase = Phase.Idle
            this.mac?.let { open(Target.Hello(it)) }
        }
    }

    /** Pairs with the Mac a scanned code points at, and stays connected to it. */
    fun pair(invite: PairingInvite) {
        close()
        queue = null
        open(Target.Pair(invite))
    }

    private sealed interface Target {
        val hosts: List<String>
        val port: Int
        val fingerprint: String

        data class Hello(val mac: PairedMac) : Target {
            override val hosts get() = mac.hosts
            override val port get() = mac.port
            override val fingerprint get() = mac.fingerprint
        }

        data class Pair(val invite: PairingInvite) : Target {
            override val hosts get() = invite.hosts
            override val port get() = invite.port
            override val fingerprint get() = invite.fingerprint
        }
    }

    private sealed interface SocketEvent {
        class Text(val text: String) : SocketEvent
        class Binary(val bytes: ByteArray) : SocketEvent
        class Closed(val error: Throwable?) : SocketEvent
    }

    private fun open(target: Target) {
        retrying?.cancel()
        phase = Phase.Connecting
        lastProblem = null
        receiving = scope.launch {
            for (host in target.hosts) {
                ensureActive()
                if (connect(host, target)) return@launch
            }
            ensureActive()
            if (phase == Phase.Connecting) {
                val reason = lastProblem?.let { " ($it)" } ?: ""
                phase = Phase.Failed(
                    "Shepherdr didn't answer at ${target.hosts.joinToString(", ")}:${target.port}$reason. " +
                        "Is the relay on, and Tailscale connected on both?",
                )
            }
            retryLater(target)
        }
    }

    /** Tries one address. Returns true once the Mac answered, after the connection ends. */
    private suspend fun connect(host: String, target: Target): Boolean {
        val address = if (host.contains(":")) "[$host]" else host
        val refusal = AtomicReference<String?>(null)
        val events = Channel<SocketEvent>(Channel.UNLIMITED)
        val http = RelaySocket.client(target.fingerprint, refusal)
        val request = try {
            Request.Builder().url("wss://$address:${target.port}/v1").build()
        } catch (_: IllegalArgumentException) {
            return false
        }
        val socket = http.newWebSocket(request, object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) { events.trySend(SocketEvent.Text(text)) }
            override fun onMessage(webSocket: WebSocket, bytes: ByteString) { events.trySend(SocketEvent.Binary(bytes.toByteArray())) }
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(1000, null)
                events.trySend(SocketEvent.Closed(null))
            }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { events.trySend(SocketEvent.Closed(null)) }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { events.trySend(SocketEvent.Closed(t)) }
        })
        this.socket = socket
        var answered = false
        try {
            when (target) {
                is Target.Hello -> {
                    val token = store.token(target.mac)
                    if (token == null) {
                        phase = Phase.Failed("This phone lost its key for ${target.mac.name}. Pair it again.")
                        socket.cancel()
                        this.socket = null
                        return true
                    }
                    send(ClientMessage.Hello(target.mac.deviceID, token))
                }
                is Target.Pair -> send(ClientMessage.Pair(target.invite.code, deviceName()))
            }
            var error: Throwable? = null
            while (true) {
                // A Mac that takes the connection but never answers counts as not answering.
                val event = if (answered) events.receive() else withTimeoutOrNull(12_000) { events.receive() }
                    ?: SocketEvent.Closed(TooSlow())
                if (event is SocketEvent.Closed) {
                    error = event.error
                    break
                }
                if (!answered) {
                    answered = true
                    attempts = 0
                }
                when (event) {
                    is SocketEvent.Text -> RemoteCodec.decodeServer(event.text)?.let { handle(it, host, target) }
                    is SocketEvent.Binary -> RemoteFrame.decode(event.bytes)?.let { terminals[it.channel]?.show(it) }
                    else -> {}
                }
            }
            if (!answered) {
                lastProblem = refusal.get() ?: if (error is TooSlow) "it took too long to answer" else RelaySocket.describe(error)
                Log.i(TAG, "$host:${target.port} didn't answer: $error")
            }
            if (this.socket !== socket) return answered
            this.socket = null
            socket.cancel()
            heartbeat?.cancel()
            if (answered && inForeground && phase == Phase.Connected) {
                phase = Phase.Connecting
                // A Mac paired on this connection says hello from now on.
                retryLater(mac?.let { Target.Hello(it) } ?: target)
            }
            return answered
        } catch (cancelled: CancellationException) {
            socket.cancel()
            throw cancelled
        } finally {
            http.dispatcher.executorService.shutdown()
            http.connectionPool.evictAll()
        }
    }

    private class TooSlow : Exception("it took too long to answer")

    private fun handle(message: ServerMessage, host: String, target: Target) {
        when (message) {
            is ServerMessage.Welcome -> {
                phase = Phase.Connected
                val current = mac
                if (current != null && (current.name != message.macName || current.hosts.firstOrNull() != host)) {
                    // The address that worked goes first next time.
                    val updated = current.copy(name = message.macName, hosts = listOf(host) + current.hosts.filter { it != host })
                    mac = updated
                    store.save(macs.map { if (it.id == updated.id) updated else it })
                    macs = store.load()
                }
                startHeartbeat()
                // Terminals open before a reconnect stream again.
                terminals.values.forEach { it.reattach() }
            }
            is ServerMessage.Paired -> {
                if (target !is Target.Pair) return
                val invite = target.invite
                val paired = PairedMac(
                    deviceID = message.deviceID, name = message.macName, hosts = listOf(host) + invite.hosts.filter { it != host },
                    port = invite.port, fingerprint = invite.fingerprint,
                )
                if (!store.add(paired, message.token)) {
                    phase = Phase.Failed("This phone couldn't keep the key for ${message.macName}, so the pairing can't be saved.")
                    close()
                    return
                }
                macs = store.load()
                mac = paired
            }
            is ServerMessage.Refused -> {
                phase = Phase.Failed(message.reason)
                retrying?.cancel()
                close()
            }
            is ServerMessage.Queue -> {
                queue = message.snapshot
                arcade.observe(message.snapshot.rows)
            }
            is ServerMessage.Terminal -> terminals[message.channel]?.update(message.state, message.message)
            is ServerMessage.Reset -> terminals[message.channel]?.onReset?.invoke()
            is ServerMessage.Failure -> notice = message.message
            is ServerMessage.CompassPage -> compassPage = CompassPage(message.day, message.html)
            ServerMessage.Pong -> {}
        }
    }

    private fun retryLater(target: Target) {
        if (!inForeground) return
        attempts += 1
        val delaySeconds = min(15.0, 2.0.pow(min(attempts, 4)))
        retrying = scope.launch {
            delay((delaySeconds * 1000).toLong())
            if (!inForeground || socket != null) return@launch
            when (target) {
                is Target.Hello -> mac?.let { open(Target.Hello(it)) }
                is Target.Pair -> {}
            }
        }
    }

    private fun startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = scope.launch {
            while (true) {
                delay(20_000)
                send(ClientMessage.Ping)
            }
        }
    }

    private fun close() {
        retrying?.cancel()
        receiving?.cancel()
        heartbeat?.cancel()
        socket?.cancel()
        socket = null
    }

    fun send(message: ClientMessage) {
        socket?.send(RemoteCodec.encode(message))
    }

    private fun deviceName(): String =
        Settings.Global.getString(appContext.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: "${Build.MANUFACTURER.replaceFirstChar { it.uppercase() }} ${Build.MODEL}"

    // Terminals

    fun terminal(pane: RemoteSessionID): RemoteTerminal {
        val channel = nextChannel++
        return RemoteTerminal(channel, pane, this).also { terminals[channel] = it }
    }

    fun release(terminal: RemoteTerminal) {
        if (terminals.remove(terminal.channel) == null) return
        send(ClientMessage.Detach(terminal.channel))
    }

    fun prompt(text: String, pane: RemoteSessionID) {
        send(ClientMessage.Prompt(pane, text))
        arcade.touch(pane, queue?.rows)
    }

    // Compass

    /** Asks the Mac for a day's page, or today's. */
    fun requestCompassPage(day: String?) = send(ClientMessage.CompassPage(day))
    fun runCompass() = send(ClientMessage.CompassRun)
    fun cancelCompassRun() = send(ClientMessage.CompassCancel)

    private companion object {
        const val TAG = "RelayClient"
    }
}

/** A Compass page as the Mac sent it: null HTML when that day has none. */
data class CompassPage(val day: String, val html: String?)

/** One pane the phone shows, on a channel of its own. */
class RemoteTerminal(val channel: Int, val pane: RemoteSessionID, private val client: RelayClient) {
    var state by mutableStateOf(RemoteTerminalState.Connecting)
        private set
    var message by mutableStateOf<String?>(null)
        private set
    var onFrame: ((RemoteFrame) -> Unit)? = null
    var onReset: (() -> Unit)? = null
    private var size: Pair<Int, Int>? = null

    fun show(frame: RemoteFrame) {
        onFrame?.invoke(frame)
    }

    fun update(state: RemoteTerminalState, message: String?) {
        this.state = state
        this.message = message
    }

    /** The first size attaches; later ones resize. */
    fun resize(columns: Int, rows: Int) {
        if (columns <= 1 || rows <= 1) return
        val first = size == null
        if (size == columns to rows) return
        size = columns to rows
        client.send(if (first) ClientMessage.Attach(channel, pane, columns, rows) else ClientMessage.Resize(channel, columns, rows))
    }

    fun reattach() {
        val (columns, rows) = size ?: return
        state = RemoteTerminalState.Connecting
        client.send(ClientMessage.Attach(channel, pane, columns, rows))
    }

    fun input(bytes: ByteArray) {
        client.send(ClientMessage.Input(channel, bytes))
        client.arcade.touch(pane, client.queue?.rows)
    }

    fun scroll(up: Boolean, lines: Int) = client.send(ClientMessage.Scroll(channel, up, lines))
    fun takeOver() = client.send(ClientMessage.TakeOver(channel))
}
