@preconcurrency import AVFoundation
import Foundation
import Observation
import Speech

/// Dictation on the iPhone, with Apple's on-device speech recognition (SpeechAnalyzer). What you
/// say shows as you speak; stopping returns the whole transcript for the composer.
@MainActor @Observable
final class Dictation {
    static let localeKey = "dictationLocale"

    enum State: Equatable {
        case idle
        case preparing(String)
        case recording
        case failed(String)
    }

    private(set) var state: State = .idle
    /// What it heard and may still revise.
    private(set) var volatile = ""
    /// What it settled on so far.
    private var settled = ""

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var input: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var results: Task<Void, Never>?

    var isRecording: Bool { state == .recording }

    func start() async {
        guard state == .idle || isFailed else { return }
        settled = ""
        volatile = ""
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .failed("Shepherdr Remote can't use the microphone. Allow it in Settings → Privacy → Microphone.")
            return
        }
        do {
            let wanted = UserDefaults.standard.string(forKey: Self.localeKey).flatMap { $0.isEmpty ? nil : Locale(identifier: $0) } ?? .current
            guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
                state = .failed("This iPhone can't transcribe \(wanted.identifier) on the device.")
                return
            }
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                                attributeOptions: [])
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                state = .preparing("Downloading speech recognition for \(locale.identifier)…")
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                state = .failed("Speech recognition has no audio format for this iPhone.")
                return
            }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            input = continuation
            results = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        let text = String(result.text.characters)
                        await MainActor.run {
                            guard let self else { return }
                            if result.isFinal {
                                self.settled += text
                                self.volatile = ""
                            } else {
                                self.volatile = text
                            }
                        }
                    }
                } catch {}
            }
            try await analyzer.start(inputSequence: stream)
            try startAudio(into: continuation, format: format)
            state = .recording
        } catch {
            stopAudio()
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops listening and returns everything it heard.
    func stop() async -> String {
        guard state == .recording else { return "" }
        stopAudio()
        input?.finish()
        input = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        await results?.value
        results = nil
        analyzer = nil
        state = .idle
        let text = (settled + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
        settled = ""
        volatile = ""
        return text
    }

    private var isFailed: Bool { if case .failed = state { true } else { false } }

    private func startAudio(into continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let natural = node.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: natural, to: format) else {
            throw DictationError.message("The microphone's audio can't be converted for speech recognition.")
        }
        Self.installTap(on: node, format: natural, box: ConverterBox(converter: converter, format: format, continuation: continuation))
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// The tap runs on the audio thread. A closure written in this main-actor class would be
    /// main-actor too, and Swift stops the app when the audio thread calls it; this one isn't.
    private nonisolated static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, box: ConverterBox) {
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in box.convert(buffer) }
    }

    private func stopAudio() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum DictationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

/// Converts the microphone's buffers to the analyzer's format, on the audio thread.
private final class ConverterBox: @unchecked Sendable {
    let converter: AVAudioConverter
    let format: AVAudioFormat
    let continuation: AsyncStream<AnalyzerInput>.Continuation

    init(converter: AVAudioConverter, format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.converter = converter
        self.format = format
        self.continuation = continuation
    }

    func convert(_ buffer: AVAudioPCMBuffer) {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
    }
}
