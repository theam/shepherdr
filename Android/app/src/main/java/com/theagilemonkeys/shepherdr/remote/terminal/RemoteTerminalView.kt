package com.theagilemonkeys.shepherdr.remote.terminal

import android.annotation.SuppressLint
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.text.Editable
import android.text.InputType
import android.util.TypedValue
import android.view.Choreographer
import android.view.GestureDetector
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.Toast
import androidx.core.content.res.ResourcesCompat
import com.termux.terminal.KeyHandler
import com.termux.terminal.TerminalColors
import com.termux.terminal.TerminalEmulator
import com.termux.terminal.TerminalOutput
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import com.termux.terminal.TextStyle
import com.termux.view.TerminalRenderer
import com.theagilemonkeys.shepherdr.remote.R
import com.theagilemonkeys.shepherdr.remote.protocol.RemoteFrame
import com.theagilemonkeys.shepherdr.remote.relay.RemoteTerminal
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.pow

/**
 * A pane's live terminal: Termux's emulator and renderer, fed with Herdr's frames. Herdr keeps the
 * history and paints whatever part of it is shown, so swiping up and down asks Herdr to scroll,
 * line by line as the finger moves; a flick carries on and slows down, as a list does. Tapping
 * opens the keyboard, and a long press copies the screen.
 */
@SuppressLint("ViewConstructor")
class RemoteTerminalView(context: Context) : View(context) {
    private var terminal: RemoteTerminal? = null

    /**
     * What the emulator would answer a program, such as a cursor report, goes nowhere: the frames
     * are Herdr's paint of a screen, not a program asking this terminal anything.
     */
    private val output = object : TerminalOutput() {
        override fun write(data: ByteArray?, offset: Int, count: Int) {}
        override fun titleChanged(oldTitle: String?, newTitle: String?) {}
        override fun onCopyTextToClipboard(text: String?) { text?.let { copy(it) } }
        override fun onPasteTextFromClipboard() {}
        override fun onBell() {}
        override fun onColorsChanged() { invalidate() }
    }

    private val emulator = TerminalEmulator(output, 80, 24, TerminalEmulator.TERMINAL_TRANSCRIPT_ROWS_MIN, QuietClient)
    private val typeface: Typeface = ResourcesCompat.getFont(context, R.font.firacode_regular) ?: Typeface.MONOSPACE
    private var renderer = TerminalRenderer(textPixels(11f), typeface)

    var fontSize: Float = 11f
        set(value) {
            if (abs(field - value) < 0.1f) return
            field = value
            renderer = TerminalRenderer(textPixels(value), typeface)
            updateSize()
        }

    init {
        isFocusable = true
        isFocusableInTouchMode = true
        emulator.mColors.reset()
    }

    fun attach(terminal: RemoteTerminal) {
        this.terminal = terminal
        terminal.onFrame = { show(it) }
        terminal.onReset = {
            emulator.reset()
            emulator.append(CLEAR, CLEAR.size)
            invalidate()
        }
        updateSize()
    }

    fun detach() {
        stopCoasting()
        terminal?.onFrame = null
        terminal?.onReset = null
        terminal = null
    }

    private fun show(frame: RemoteFrame) {
        if (frame.columns > 0 && frame.rows > 0 && (emulator.mColumns != frame.columns || emulator.mRows != frame.rows)) {
            emulator.resize(frame.columns, frame.rows)
        }
        emulator.append(frame.bytes, frame.bytes.size)
        invalidate()
    }

    private fun textPixels(size: Float): Int =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, size, resources.displayMetrics).toInt().coerceAtLeast(4)

    // Size

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        updateSize()
    }

    /** The columns and rows that fit; the first size attaches the pane, later ones resize it. */
    private fun updateSize() {
        if (width == 0 || height == 0) return
        val columns = max(4, ((width - paddingLeft - paddingRight) / renderer.fontWidth).toInt())
        val rows = max(4, (height - paddingTop - paddingBottom) / renderer.fontLineSpacing)
        if (columns != emulator.mColumns || rows != emulator.mRows) emulator.resize(columns, rows)
        terminal?.resize(columns, rows)
        invalidate()
    }

    private val background = Paint()

    override fun onDraw(canvas: Canvas) {
        // Only this view's own rectangle: inside Compose, the canvas reaches beyond it.
        canvas.save()
        canvas.clipRect(0, 0, width, height)
        background.color = emulator.mColors.mCurrentColors[TextStyle.COLOR_INDEX_BACKGROUND]
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), background)
        canvas.translate(paddingLeft.toFloat(), paddingTop.toFloat())
        renderer.render(emulator, canvas, 0, -1, -1, -1, -1)
        canvas.restore()
    }

    // Typing

    override fun onCheckIsTextEditor(): Boolean = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD or
            InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_FULLSCREEN or EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_ACTION_NONE
        return object : BaseInputConnection(this, true) {
            override fun commitText(text: CharSequence?, newCursorPosition: Int): Boolean {
                super.commitText(text, newCursorPosition)
                flush(editable)
                return true
            }

            override fun finishComposingText(): Boolean {
                super.finishComposingText()
                flush(editable)
                return true
            }

            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                if (editable.isNullOrEmpty()) {
                    repeat(beforeLength) { send(byteArrayOf(DELETE)) }
                    return true
                }
                return super.deleteSurroundingText(beforeLength, afterLength)
            }
        }
    }

    private fun flush(editable: Editable?) {
        val text = editable?.toString().orEmpty()
        editable?.clear()
        if (text.isNotEmpty()) send(text.replace("\n", "\r").toByteArray(Charsets.UTF_8))
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK) return super.onKeyDown(keyCode, event)
        var modifiers = 0
        if (event.isAltPressed) modifiers = modifiers or KeyHandler.KEYMOD_ALT
        if (event.isCtrlPressed) modifiers = modifiers or KeyHandler.KEYMOD_CTRL
        if (event.isShiftPressed) modifiers = modifiers or KeyHandler.KEYMOD_SHIFT
        KeyHandler.getCode(keyCode, modifiers, emulator.isCursorKeysApplicationMode, emulator.isKeypadApplicationMode)?.let {
            send(it.toByteArray(Charsets.UTF_8))
            return true
        }
        val plain = event.getUnicodeChar(event.metaState and (KeyEvent.META_CTRL_MASK or KeyEvent.META_ALT_MASK).inv())
        if (plain == 0) return super.onKeyDown(keyCode, event)
        var code = plain
        if (event.isCtrlPressed) {
            code = when (code) {
                in 'a'.code..'z'.code -> code - 96
                in '@'.code..'_'.code -> code - 64
                ' '.code -> 0
                '?'.code -> 127
                else -> code
            }
        }
        val text = String(Character.toChars(code))
        send((if (event.isAltPressed) "\u001b$text" else text).toByteArray(Charsets.UTF_8))
        return true
    }

    private fun send(bytes: ByteArray) {
        terminal?.input(bytes)
    }

    // Touch

    private val gestures = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent): Boolean {
            stopCoasting()
            return true
        }

        override fun onSingleTapUp(e: MotionEvent): Boolean {
            requestFocus()
            context.getSystemService(InputMethodManager::class.java)?.showSoftInput(this@RemoteTerminalView, 0)
            return true
        }

        override fun onScroll(e1: MotionEvent?, e2: MotionEvent, distanceX: Float, distanceY: Float): Boolean {
            if (abs(distanceY) < abs(distanceX)) return false
            // A finger moving down brings back older lines.
            pending -= distanceY
            sendLines(System.nanoTime(), force = false)
            return true
        }

        override fun onFling(e1: MotionEvent?, e2: MotionEvent, velocityX: Float, velocityY: Float): Boolean {
            if (abs(velocityY) < abs(velocityX) || abs(velocityY) < 300 * resources.displayMetrics.density) return false
            sendLines(System.nanoTime(), force = true)
            velocity = velocityY
            coast()
            return true
        }

        override fun onLongPress(e: MotionEvent) {
            val screen = emulator.screen.getSelectedText(0, 0, emulator.mColumns - 1, emulator.mRows - 1).trimEnd()
            if (screen.isNotEmpty()) {
                copy(screen)
                Toast.makeText(context, "Copied the screen", Toast.LENGTH_SHORT).show()
            }
        }
    })

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(event: MotionEvent): Boolean {
        val handled = gestures.onTouchEvent(event)
        if (event.actionMasked == MotionEvent.ACTION_UP || event.actionMasked == MotionEvent.ACTION_CANCEL) {
            if (frameCallback == null) {
                sendLines(System.nanoTime(), force = true)
                pending = 0f
            }
        }
        return handled || super.onTouchEvent(event)
    }

    /** Pixels moved and not yet sent as whole lines; positive goes back in history. */
    private var pending = 0f
    /** Pixels per second while coasting after a flick. */
    private var velocity = 0f
    private var lastStep = 0L
    private var lastSent = 0L
    private var frameCallback: Choreographer.FrameCallback? = null

    /** Sends the whole lines moved so far, unless one went out a moment ago. */
    private fun sendLines(now: Long, force: Boolean) {
        val height = renderer.fontLineSpacing.toFloat()
        val lines = (pending / height).toInt()
        if (lines == 0 || (!force && now - lastSent < 1_000_000_000L / SENDS_PER_SECOND)) return
        pending -= lines * height
        lastSent = now
        terminal?.scroll(up = lines > 0, lines = abs(lines))
    }

    private fun coast() {
        lastStep = System.nanoTime()
        val callback = object : Choreographer.FrameCallback {
            override fun doFrame(frameTimeNanos: Long) {
                val elapsed = max(0L, frameTimeNanos - lastStep) / 1e9f
                lastStep = frameTimeNanos
                pending += velocity * elapsed
                velocity *= DECELERATION.pow(elapsed * 1000)
                sendLines(frameTimeNanos, force = false)
                if (abs(velocity) < 40 * resources.displayMetrics.density) {
                    sendLines(frameTimeNanos, force = true)
                    stopCoasting()
                } else {
                    Choreographer.getInstance().postFrameCallback(this)
                }
            }
        }
        frameCallback = callback
        Choreographer.getInstance().postFrameCallback(callback)
    }

    /** Stops a flick that's still coasting. */
    private fun stopCoasting() {
        frameCallback?.let { Choreographer.getInstance().removeFrameCallback(it) }
        frameCallback = null
        velocity = 0f
        pending = 0f
    }

    override fun onDetachedFromWindow() {
        stopCoasting()
        super.onDetachedFromWindow()
    }

    private fun copy(text: String) {
        context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("Shepherdr", text))
    }

    companion object {
        /** At most this many scroll messages a second, so a fast flick doesn't flood the relay. */
        private const val SENDS_PER_SECOND = 30L
        /** A list's normal deceleration: what's left of the speed after each millisecond. */
        private const val DECELERATION = 0.998f
        private const val DELETE: Byte = 0x7f
        private val CLEAR = "\u001bc".toByteArray()

        /** The Mac's terminal palette (App/Theme.swift). */
        private val palette = intArrayOf(
            0x0E1310, 0xFF5F57, 0x4DFFA0, 0xFFB547, 0x5C9DFF, 0xD77CFF, 0x5CD6FF, 0xC5D3CA,
            0x4B5E53, 0xFF8A80, 0x8CFFC2, 0xFFD37F, 0x8FBCFF, 0xE6A8FF, 0x9AE6FF, 0xF2FFF7,
        )

        init {
            val colors = TerminalColors.COLOR_SCHEME.mDefaultColors
            palette.forEachIndexed { index, hex -> colors[index] = opaque(hex) }
            colors[TextStyle.COLOR_INDEX_FOREGROUND] = opaque(0xD9E7DE)
            colors[TextStyle.COLOR_INDEX_BACKGROUND] = opaque(0x090C0A)
            colors[TextStyle.COLOR_INDEX_CURSOR] = opaque(0x4DFFA0)
        }

        private fun opaque(hex: Int) = hex or (0xFF shl 24)
    }
}

/** The emulator asks its session's client for a few things; this one has nothing to say. */
private object QuietClient : TerminalSessionClient {
    override fun onTextChanged(changedSession: TerminalSession) {}
    override fun onTitleChanged(changedSession: TerminalSession) {}
    override fun onSessionFinished(finishedSession: TerminalSession) {}
    override fun onCopyTextToClipboard(session: TerminalSession, text: String?) {}
    override fun onPasteTextFromClipboard(session: TerminalSession?) {}
    override fun onBell(session: TerminalSession) {}
    override fun onColorsChanged(session: TerminalSession) {}
    override fun onTerminalCursorStateChange(state: Boolean) {}
    override fun getTerminalCursorStyle(): Int = TerminalEmulator.DEFAULT_TERMINAL_CURSOR_STYLE
    override fun logError(tag: String?, message: String?) {}
    override fun logWarn(tag: String?, message: String?) {}
    override fun logInfo(tag: String?, message: String?) {}
    override fun logDebug(tag: String?, message: String?) {}
    override fun logVerbose(tag: String?, message: String?) {}
    override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) {}
    override fun logStackTrace(tag: String?, e: Exception?) {}
}
