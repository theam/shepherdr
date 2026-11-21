package com.theagilemonkeys.shepherdr.remote.dictation

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import java.util.Locale

/**
 * Dictation on the phone, with Android's speech recognition, on the device when it can. What you
 * say shows as you speak; stopping returns the whole transcript for the composer. Android ends a
 * recognition after a pause, so while you keep the microphone on it starts listening again.
 */
class Dictation(context: Context) {
    sealed interface State {
        data object Idle : State
        data class Preparing(val message: String) : State
        data object Recording : State
        data class Failed(val message: String) : State
    }

    private val appContext = context.applicationContext

    var state by mutableStateOf<State>(State.Idle)
        private set
    /** What it heard and may still revise. */
    var volatile by mutableStateOf("")
        private set
    /** What it settled on so far. */
    private var settled = ""
    private var recognizer: SpeechRecognizer? = null
    private var finished: CompletableDeferred<Unit>? = null
    private var stopping = false

    val isRecording: Boolean get() = state == State.Recording

    /** Starts listening; the caller has asked for the microphone already. */
    fun start() {
        if (state != State.Idle && state !is State.Failed) return
        settled = ""
        volatile = ""
        stopping = false
        if (!SpeechRecognizer.isRecognitionAvailable(appContext)) {
            state = State.Failed("This phone has no speech recognition. Install or enable Google's speech services.")
            return
        }
        val onDevice = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && SpeechRecognizer.isOnDeviceRecognitionAvailable(appContext)
        val recognizer = if (onDevice) SpeechRecognizer.createOnDeviceSpeechRecognizer(appContext)
        else SpeechRecognizer.createSpeechRecognizer(appContext)
        this.recognizer = recognizer
        recognizer.setRecognitionListener(listener)
        state = State.Preparing("Starting the microphone…")
        isListening = true
        listen()
    }

    /** Stops listening and returns everything it heard. */
    suspend fun stop(): String {
        if (state != State.Recording && state !is State.Preparing) return ""
        stopping = true
        val done = CompletableDeferred<Unit>().also { finished = it }
        recognizer?.stopListening()
        withTimeoutOrNull(2500) { done.await() }
        release()
        state = State.Idle
        val text = listOf(settled, volatile).filter { it.isNotBlank() }.joinToString(" ").trim()
        settled = ""
        volatile = ""
        return text
    }

    /** Lets go of the microphone at once, such as when the screen goes. */
    fun cancel() {
        recognizer?.cancel()
        release()
        state = State.Idle
    }

    private fun release() {
        recognizer?.destroy()
        recognizer = null
        finished = null
        isListening = false
    }

    private fun listen() {
        val locale = appContext.getSharedPreferences("shepherdr", Context.MODE_PRIVATE).getString(LOCALE_KEY, "")
            ?.takeIf { it.isNotEmpty() } ?: Locale.getDefault().toLanguageTag()
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale)
            .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            .putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            .putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 4000L)
            .putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 4000L)
        recognizer?.startListening(intent)
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) { state = State.Recording }
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onPartialResults(partialResults: Bundle?) {
            best(partialResults)?.let { volatile = it }
        }

        override fun onResults(results: Bundle?) {
            best(results)?.takeIf { it.isNotBlank() }?.let { settled = listOf(settled, it).filter(String::isNotBlank).joinToString(" ") }
            volatile = ""
            if (stopping) finished?.complete(Unit) else listen()
        }

        override fun onError(error: Int) {
            if (stopping) {
                finished?.complete(Unit)
                return
            }
            when (error) {
                // A pause: carry on listening.
                SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> listen()
                else -> {
                    release()
                    state = State.Failed(describe(error))
                }
            }
        }
    }

    private fun best(bundle: Bundle?): String? = bundle?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()

    private fun describe(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
            "Shepherdr Remote can't use the microphone. Allow it in Settings → Apps → Shepherdr → Permissions."
        SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT, SpeechRecognizer.ERROR_SERVER ->
            "Speech recognition needs its language downloaded to work without a connection."
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE ->
            "This phone can't transcribe that language. Download it in the phone's speech settings."
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "The speech recognizer is busy. Try again in a moment."
        SpeechRecognizer.ERROR_AUDIO -> "The microphone didn't record."
        else -> "Speech recognition stopped (error $error)."
    }

    companion object {
        const val LOCALE_KEY = "dictationLocale"

        /** Whether any dictation has the microphone, so that herd mode's sounds wait. */
        @Volatile
        var isListening = false
            private set
    }
}
