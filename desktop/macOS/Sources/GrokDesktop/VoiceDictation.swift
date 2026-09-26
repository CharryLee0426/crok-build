import AppKit
import AVFoundation
import Speech
import SwiftUI

// Dictation (`/voice`) records 16 kHz mono PCM16LE and, as the terminal does (crates/codegen/xai-grok-voice),
// transcribes each utterance with an OpenRouter model. Without an OpenRouter key it falls back to
// on-device Speech recognition, so audio never leaves this Mac.

// MARK: - Transcripts

/// Text from a transcription engine: words still being recognized (shown in grey), or finalized
/// text inserted in the prompt.
enum VoiceTranscriptUpdate: Equatable {
    case interim(String)
    case final(String)
}

/// Where and how dictated text lands in the prompt (P/voice/handle.rs).
enum VoiceTextInsertion {
    /// Adds a leading and/or trailing space around `fragment` only where the neighbouring
    /// character at `location` (UTF-16) is not whitespace, so the fragment reads as its own words.
    static func spaced(_ fragment: String, in text: String, at location: Int) -> String {
        let string = text as NSString
        let location = min(max(0, location), string.length)
        let whitespace = CharacterSet.whitespacesAndNewlines
        func isSpace(_ index: Int) -> Bool {
            guard let scalar = UnicodeScalar(string.character(at: index)) else { return false }
            return whitespace.contains(scalar)
        }
        let leading = location > 0 && !isSpace(location - 1)
        let trailing = location < string.length && !isSpace(location)
        return (leading ? " " : "") + fragment + (trailing ? " " : "")
    }

    /// The prompt after replacing `range` (the selection, or the caret) with `fragment`, and the
    /// caret after it. A blank draft is replaced outright.
    static func merge(_ fragment: String, into existing: String, replacing range: NSRange?) -> (text: String, caret: Int) {
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return (fragment, (fragment as NSString).length) }
        let string = existing as NSString
        let start = min(max(0, range?.location ?? string.length), string.length)
        let end = min(string.length, start + max(0, range?.length ?? 0))
        let base = string.replacingCharacters(in: NSRange(location: start, length: end - start), with: "")
        let insertion = spaced(fragment, in: base, at: start)
        let merged = (base as NSString).replacingCharacters(in: NSRange(location: start, length: 0), with: insertion)
        return (merged, start + (insertion as NSString).length)
    }
}

/// Model, endpoint, and language settings (`[voice]` and the `[ui].voice_stt_*` keys the terminal's
/// settings share). Dictation always transcribes with OpenRouter.
struct VoiceSTTSettings: Equatable {
    var language = "en"
    var sampleRate = 16_000
    /// OpenRouter transcription model slug.
    var model = VoiceSTTSettings.defaultModel
    var openRouterBase = "https://openrouter.ai/api/v1"

    /// DEFAULT_OPENROUTER_STT_MODEL in xai-grok-voice.
    static let defaultModel = "openai/gpt-4o-mini-transcribe"
    /// Offered when OpenRouter's model list can't be fetched.
    static let suggestedModels: [VoiceModelOption] = [
        VoiceModelOption(id: "openai/gpt-4o-mini-transcribe", name: "OpenAI: GPT-4o Mini Transcribe"),
        VoiceModelOption(id: "openai/gpt-4o-transcribe", name: "OpenAI: GPT-4o Transcribe"),
        VoiceModelOption(id: "openai/whisper-large-v3-turbo", name: "OpenAI: Whisper Large V3 Turbo"),
        VoiceModelOption(id: "openai/whisper-1", name: "OpenAI: Whisper 1"),
        VoiceModelOption(id: "mistralai/voxtral-mini-transcribe", name: "Mistral: Voxtral Mini Transcribe"),
        VoiceModelOption(id: "google/gemini-3.5-transcribe", name: "Google: Gemini 3.5 Transcribe"),
        VoiceModelOption(id: "deepgram/nova-3", name: "Deepgram: Nova-3"),
    ]

    init() {}

    /// The trimmed slug, or the default when blank (canonical_stt_model).
    static func canonicalModel(_ value: String?) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    /// `POST {base}/audio/transcriptions`. Plaintext bases are refused so the key never travels unencrypted.
    func transcriptionURL() throws -> URL {
        let base = String(openRouterBase.trimmingCharacters(in: .whitespaces).reversed().drop(while: { $0 == "/" }).reversed())
        let lower = base.lowercased()
        if lower.hasPrefix("http://") {
            throw ComposerCommandMessage("insecure voice openrouter_api_base \"\(openRouterBase)\": voice requires an https:// endpoint. Refusing to send the API key over a plaintext connection.")
        }
        let rest = lower.hasPrefix("https://") ? String(base.dropFirst("https://".count)) : base
        guard let url = URL(string: "https://\(rest)/audio/transcriptions") else {
            throw ComposerCommandMessage("bad transcription URL: https://\(rest)/audio/transcriptions")
        }
        return url
    }

    init(config: GrokConfig) {
        let uiModel = config.string("voice_stt_model", in: "ui")?.trimmingCharacters(in: .whitespacesAndNewlines)
        model = Self.canonicalModel(uiModel?.isEmpty == false ? uiModel : config.string("model", in: "voice"))
        if let value = config.string("openrouter_api_base", in: "voice")?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
            openRouterBase = value
        }
        language = config.string("voice_stt_language", in: "ui") ?? config.string("language", in: "voice") ?? "en"
        if let value = config.int("sample_rate", in: "voice"), value > 0 { sampleRate = value }
    }

    /// Dictation languages (xai-grok-voice language.rs), sorted by English name.
    static let languages: [(code: String, name: String)] = [
        ("ar", "Arabic"), ("cs", "Czech"), ("da", "Danish"), ("nl", "Dutch"), ("en", "English"), ("fil", "Filipino"),
        ("fr", "French"), ("de", "German"), ("hi", "Hindi"), ("id", "Indonesian"), ("it", "Italian"), ("ja", "Japanese"),
        ("ko", "Korean"), ("mk", "Macedonian"), ("ms", "Malay"), ("fa", "Persian"), ("pl", "Polish"), ("pt", "Portuguese"),
        ("ro", "Romanian"), ("ru", "Russian"), ("es", "Spanish"), ("sv", "Swedish"), ("th", "Thai"), ("tr", "Turkish"),
        ("vi", "Vietnamese"),
    ]

    /// A catalog code, or "auto"; blank and unknown values become "en" (canonicalize_stt_language).
    static func canonicalLanguage(_ value: String?) -> String {
        let raw = (value ?? "").trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return "en" }
        if raw.lowercased() == "auto" { return "auto" }
        func match(_ code: String) -> String? { languages.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }?.code }
        if let code = match(raw) { return code }
        let primary = raw.split(whereSeparator: { "_-.".contains($0) }).first.map(String.init) ?? ""
        if let code = match(primary) { return code }
        return primary.lowercased() == "tl" ? "fil" : "en"
    }

    /// The concrete code sent to the API; "auto" follows the system language.
    static func languageForAPI(_ stored: String, preferred: [String] = Locale.preferredLanguages) -> String {
        let canonical = canonicalLanguage(stored)
        guard canonical == "auto" else { return canonical }
        for identifier in preferred {
            let code = canonicalLanguage(identifier)
            if code != "en" || identifier.lowercased().hasPrefix("en") { return code }
        }
        return "en"
    }
}

// MARK: - Audio

/// Converts microphone buffers to 16 kHz mono signed 16-bit little-endian PCM.
final class VoicePCMConverter {
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat

    init?(inputFormat: AVAudioFormat, sampleRate: Double = 16_000) {
        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: output) else { return nil }
        converter.downmix = true
        self.inputFormat = inputFormat
        self.outputFormat = output
        self.converter = converter
    }

    /// Converts one buffer; the resampler keeps its state between calls, as a stream needs.
    func convert(_ buffer: AVAudioPCMBuffer) -> Data {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard buffer.frameLength > 0, let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return Data() }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let samples = output.int16ChannelData, output.frameLength > 0 else { return Data() }
        var data = Data(capacity: Int(output.frameLength) * 2)
        for index in 0..<Int(output.frameLength) {
            var little = samples[0][index].littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Clamps a float sample to the signed 16-bit range.
    static func int16(_ sample: Float) -> Int16 {
        let clamped = max(-1, min(1, sample))
        return Int16(clamped < 0 ? clamped * 32_768 : clamped * 32_767)
    }
}

/// Groups PCM into ~64 ms frames (1,024 samples at 16 kHz) for the utterance segmenter.
struct VoicePCMChunker {
    let frameBytes: Int
    private var pending = Data()

    init(frameBytes: Int = 2_048) { self.frameBytes = frameBytes }

    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var frames: [Data] = []
        while pending.count >= frameBytes {
            frames.append(Data(pending.prefix(frameBytes)))
            pending = Data(pending.dropFirst(frameBytes))
        }
        return frames
    }

    mutating func flush() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }
}

/// The microphone tap. Its block runs on a real-time audio thread.
final class VoiceAudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var running = false

    func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ComposerCommandMessage("No microphone is available.") }
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in onBuffer(buffer) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Converts and frames audio on the capture thread, then hands frames on.
private final class VoiceAudioPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: VoicePCMConverter?
    private var chunker = VoicePCMChunker()
    private let sampleRate: Double
    private let send: (Data) -> Void

    init(sampleRate: Double, send: @escaping (Data) -> Void) {
        self.sampleRate = sampleRate
        self.send = send
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if converter == nil { converter = VoicePCMConverter(inputFormat: buffer.format, sampleRate: sampleRate) }
        let frames = converter.map { chunker.append($0.convert(buffer)) } ?? []
        lock.unlock()
        frames.forEach(send)
    }

    func flush() {
        lock.lock()
        let rest = chunker.flush()
        lock.unlock()
        if let rest { send(rest) }
    }
}

// MARK: - OpenRouter

/// Cuts 16-bit mono PCM into utterances at pauses so each one can be transcribed with a request
/// (xai-grok-voice segment.rs). A frame is speech when its RMS clears a multiple of the tracked
/// noise floor; silence-only audio is never sent.
struct VoiceSegmenter {
    static let pauseMS = 700
    static let minSegmentMS = 800
    static let softMaxMS = 12_000
    static let softMaxGapMS = 150
    static let hardMaxMS = 25_000
    static let prerollMS = 300
    static let minSpeechRMS = 250.0
    static let maxSpeechRMS = 1_500.0

    struct Push: Equatable {
        var voiced = false
        var segment: Data?
    }

    let sampleRate: Int
    private var buffer = Data()
    private var hasSpeech = false
    private var trailingSilenceMS = 0
    private var noiseFloor: Double?

    init(sampleRate: Int = 16_000) { self.sampleRate = max(1, sampleRate) }

    func milliseconds(_ bytes: Int) -> Int { bytes / 2 * 1_000 / sampleRate }
    private func bytes(forMS ms: Int) -> Int { ms * sampleRate / 1_000 * 2 }

    static func rms(_ pcm: Data) -> Double {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                sum += sample * sample
            }
        }
        return (sum / Double(count)).squareRoot()
    }

    private mutating func classify(_ frame: Data) -> Bool {
        let level = Self.rms(frame)
        let floor = noiseFloor ?? level
        let threshold = min(max(floor * 3, Self.minSpeechRMS), Self.maxSpeechRMS)
        let voiced = level >= threshold
        noiseFloor = level < floor ? level : (voiced ? floor : floor + (level - floor) * 0.05)
        return voiced
    }

    mutating func push(_ frame: Data) -> Push {
        guard !frame.isEmpty else { return Push() }
        let voiced = classify(frame)
        buffer.append(frame)
        if voiced { hasSpeech = true; trailingSilenceMS = 0 } else { trailingSilenceMS += milliseconds(frame.count) }
        let length = milliseconds(buffer.count)
        guard hasSpeech else {
            let keep = bytes(forMS: Self.prerollMS)
            if buffer.count > keep { buffer = Data(buffer.suffix(keep - keep % 2)) }
            return Push(voiced: voiced)
        }
        let cut = (trailingSilenceMS >= Self.pauseMS && length >= Self.minSegmentMS)
            || (length >= Self.softMaxMS && trailingSilenceMS >= Self.softMaxGapMS)
            || length >= Self.hardMaxMS
        return Push(voiced: voiced, segment: cut ? take() : nil)
    }

    /// The trailing utterance when capture ends, if it has speech.
    mutating func finish() -> Data? {
        guard hasSpeech else { buffer = Data(); return nil }
        return take()
    }

    private mutating func take() -> Data {
        hasSpeech = false
        trailingSilenceMS = 0
        defer { buffer = Data() }
        return buffer
    }
}

/// Feeds frames from the capture thread into a segmenter. Closed utterances wait in order until the
/// main thread drains them, so the one flushed at stop can never overtake an earlier one.
final class VoiceSegmentSink: @unchecked Sendable {
    private let lock = NSLock()
    private var segmenter: VoiceSegmenter
    private var ready: [Data] = []
    private var heardVoice = false
    private var reportedVoice = false
    private let notify: () -> Void

    /// `notify` runs on the capture thread when speech is first heard or an utterance closes.
    init(sampleRate: Int, notify: @escaping () -> Void) {
        segmenter = VoiceSegmenter(sampleRate: sampleRate)
        self.notify = notify
    }

    func push(_ frame: Data) {
        lock.lock()
        let push = segmenter.push(frame)
        if push.voiced { heardVoice = true }
        if let segment = push.segment { ready.append(segment) }
        let signal = push.segment != nil || (heardVoice && !reportedVoice)
        if heardVoice { reportedVoice = true }
        lock.unlock()
        if signal { notify() }
    }

    /// Whether speech has been heard, and the utterances closed since the last drain, oldest first.
    func drain() -> (voiced: Bool, segments: [Data]) {
        lock.lock(); defer { lock.unlock() }
        let segments = ready
        ready = []
        return (heardVoice, segments)
    }

    /// Everything left when capture stops, including the trailing utterance if it has speech.
    func finish() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        var segments = ready
        ready = []
        if let rest = segmenter.finish() { segments.append(rest) }
        return segments
    }
}

/// One request per utterance to OpenRouter's `/audio/transcriptions` (xai-grok-voice stt/openrouter.rs).
struct VoiceOpenRouterTranscriber {
    let url: URL
    let model: String
    let language: String
    let sampleRate: Int
    let key: String

    init(settings: VoiceSTTSettings, key: String) throws {
        url = try settings.transcriptionURL()
        model = VoiceSTTSettings.canonicalModel(settings.model)
        language = VoiceSTTSettings.languageForAPI(settings.language)
        sampleRate = settings.sampleRate
        self.key = key
    }

    /// PCM16LE mono wrapped in a RIFF/WAVE header.
    static func wav(_ pcm: Data, sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + pcm.count)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    static func requestBody(model: String, language: String, wav: Data) -> Data {
        let body: [String: Any] = [
            "model": model,
            "input_audio": ["data": wav.base64EncodedString(), "format": "wav"],
            "language": language,
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// The transcript, or a message for the banner.
    static func result(status: Int, body: Data, model: String) -> Result<String, ComposerCommandMessage> {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if (200..<300).contains(status) {
            guard let object else { return .failure(ComposerCommandMessage("OpenRouter response parse error")) }
            return .success((object["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let reported = ((object?["error"] as? [String: Any])?["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = reported.flatMap { $0.isEmpty ? nil : $0 } ?? "HTTP \(status)"
        if (status == 400 || status == 404) && message.contains(model) {
            return .failure(ComposerCommandMessage("OpenRouter: \(message). Pick a transcription model in Settings › Behavior."))
        }
        switch status {
        case 401: return .failure(ComposerCommandMessage("OpenRouter rejected the API key (\(message)). Sign in to OpenRouter again in Settings."))
        case 402: return .failure(ComposerCommandMessage("OpenRouter: \(message) (add credits to use transcription)"))
        default: return .failure(ComposerCommandMessage("OpenRouter: \(message)"))
        }
    }

    func transcribe(_ pcm: Data) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Grok Desktop", forHTTPHeaderField: "X-Title")
        request.httpBody = Self.requestBody(model: model, language: language, wav: Self.wav(pcm, sampleRate: sampleRate))
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try Self.result(status: status, body: data, model: model).get()
    }
}

/// The OpenRouter key shared with the terminal: `OPENROUTER_API_KEY`, else `grok login openrouter`'s
/// `provider-auth/openrouter.json` (read_provider_credential).
enum VoiceOpenRouterCredential {
    static func read(home: URL = GrokPaths.home, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        func valid(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
            return value
        }
        if let key = valid(environment["OPENROUTER_API_KEY"]) { return key }
        let url = home.appendingPathComponent("provider-auth/openrouter.json")
        guard let data = try? Data(contentsOf: url), data.count <= 1_048_576,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["provider"] as? String == "openrouter" else { return nil }
        return valid(object["access_token"] as? String)
    }
}

/// A transcription model offered in Settings.
struct VoiceModelOption: Identifiable, Equatable {
    let id: String
    let name: String
}

/// OpenRouter's transcription models, for the settings menu.
enum VoiceModelCatalog {
    static let url = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=transcription")!

    static func parse(_ data: Data) -> [VoiceModelOption] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = object["data"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard let id = model["id"] as? String, !id.isEmpty else { return nil }
            return VoiceModelOption(id: id, name: model["name"] as? String ?? id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func fetch() async -> [VoiceModelOption] {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return parse(data)
    }
}

// MARK: - Dictation controller

/// Microphone capture and transcription for the composer. Everything published here changes only
/// while dictating, and only the recording row and microphone button observe it.
@MainActor
final class VoiceDictationController: ObservableObject {
    enum Phase: Equatable { case idle, starting, recording, finishing }
    enum Engine: Equatable { case onDevice, openRouter }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var engine: Engine = .openRouter
    /// Words heard but not final yet, shown in grey.
    @Published private(set) var interim = ""
    /// An utterance is on its way to OpenRouter.
    @Published private(set) var transcribing = false

    var isActive: Bool { phase != .idle }
    /// OpenRouter transcribes each utterance after it ends, so stopping must wait for the last one
    /// rather than sending right away.
    var finalArrivesAfterStop: Bool { engine == .openRouter && phase != .idle }

    /// Receives finalized text to insert at the cursor.
    var insertFinal: ((String) -> Void)?
    /// Receives a one-line message for the banner.
    var report: ((String) -> Void)?

    static let noSpeechTimeout: TimeInterval = 10
    private var session = UUID()
    private var capture: VoiceAudioCapture?
    private var pipe: VoiceAudioPipe?
    private var heardSpeech = false
    private var timers: [Task<Void, Never>] = []
    private var recognition: VoiceOnDeviceRecognition?
    private var sink: VoiceSegmentSink?
    private var transcriber: VoiceOpenRouterTranscriber?
    private var transcriptionQueue: Task<Void, Never>?
    private var pendingTranscriptions = 0 {
        didSet { if transcribing != (pendingTranscriptions > 0) { transcribing = pendingTranscriptions > 0 } }
    }
    /// A stopped OpenRouter session waits this long for its last transcripts (requests time out at 60 s).
    static let openRouterFinishTimeout: TimeInterval = 65

    /// The app bundle declares why it needs the microphone. Without it macOS terminates the
    /// process on the first capture, so an unbundled build must not touch the microphone.
    static var canRequestMicrophone: Bool { infoBundle.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") is String }
    static var canRequestSpeechRecognition: Bool { infoBundle.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") is String }
    /// The bundle whose Info.plist declares the usage descriptions.
    static var infoBundle = Bundle.main

    /// Asks for microphone access when macOS has not asked yet.
    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// Whether this Mac can transcribe `language` without sending audio anywhere, asking for
    /// speech recognition access when macOS has not asked yet.
    static func prepareOnDeviceRecognition(language: String) async -> Bool {
        guard canRequestSpeechRecognition, VoiceOnDeviceRecognition.isAvailable(language: language) else { return false }
        let status: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        } else {
            status = SFSpeechRecognizer.authorizationStatus()
        }
        return status == .authorized
    }

    /// Marks the controller as preparing (reading the key and permissions) so the UI responds at once.
    func beginStarting() {
        session = UUID()
        phase = .starting
        interim = ""
    }

    /// Stops without keeping anything that has not been finalized.
    func cancel() {
        session = UUID()
        teardown()
    }

    /// Records locally and transcribes each utterance with an OpenRouter model once it ends.
    func startOpenRouter(key: String, settings: VoiceSTTSettings) {
        let id = UUID()
        session = id
        engine = .openRouter
        heardSpeech = false
        pendingTranscriptions = 0
        do {
            transcriber = try VoiceOpenRouterTranscriber(settings: settings, key: key)
            let sink = VoiceSegmentSink(sampleRate: settings.sampleRate) { [weak self] in
                DispatchQueue.main.async { self?.drainSegments(session: id) }
            }
            self.sink = sink
            let pipe = VoiceAudioPipe(sampleRate: Double(settings.sampleRate)) { frame in sink.push(frame) }
            self.pipe = pipe
            let capture = VoiceAudioCapture()
            try capture.start { buffer in pipe.push(buffer) }
            self.capture = capture
            phase = .recording
            armNoSpeechWatchdog(session: id)
        } catch {
            fail((error as? ComposerCommandMessage)?.text ?? error.localizedDescription, session: id)
        }
    }

    private func drainSegments(session id: UUID) {
        guard id == session, let sink else { return }
        let (voiced, segments) = sink.drain()
        if voiced { heardSpeech = true }
        for pcm in segments { enqueueTranscription(pcm, session: id) }
    }

    /// Transcribes utterances one at a time so they land in the order they were spoken.
    private func enqueueTranscription(_ pcm: Data, session id: UUID) {
        guard let transcriber else { return }
        pendingTranscriptions += 1
        let previous = transcriptionQueue
        transcriptionQueue = Task { [weak self] in
            await previous?.value
            let result: Result<String, Error>
            do { result = .success(try await transcriber.transcribe(pcm)) } catch { result = .failure(error) }
            guard let self, self.session == id else { return }
            self.pendingTranscriptions -= 1
            switch result {
            case .success(let text):
                if !text.isEmpty { self.apply(.final(text)) }
                self.finishIfTranscribed(session: id)
            case .failure(let error):
                self.fail((error as? ComposerCommandMessage)?.text ?? error.localizedDescription, session: id)
            }
        }
    }

    private func finishIfTranscribed(session id: UUID) {
        guard id == session, phase == .finishing, pendingTranscriptions == 0 else { return }
        completeFinishing()
    }

    /// Transcribes on this Mac with the Speech framework.
    func startOnDevice(language: String) {
        let id = UUID()
        session = id
        engine = .onDevice
        heardSpeech = false
        let recognition = VoiceOnDeviceRecognition(language: language) { [weak self] update in
            DispatchQueue.main.async { self?.receiveOnDevice(update, session: id) }
        }
        do {
            try recognition.start()
            self.recognition = recognition
            phase = .recording
            armNoSpeechWatchdog(session: id)
        } catch {
            fail((error as? ComposerCommandMessage)?.text ?? error.localizedDescription, session: id)
        }
    }

    /// Stops listening but keeps the words still being transcribed; they land when final.
    func stop() {
        guard phase == .recording || phase == .starting else { return }
        guard phase == .recording else { cancel(); return }
        phase = .finishing
        capture?.stop()
        pipe?.flush()
        recognition?.finish()
        let id = session
        if engine == .openRouter {
            for pcm in sink?.finish() ?? [] { enqueueTranscription(pcm, session: id) }
            finishIfTranscribed(session: id)
            schedule(after: Self.openRouterFinishTimeout, session: id) { controller in controller.completeFinishing() }
            return
        }
        schedule(after: 5, session: id) { controller in controller.completeFinishing() }
    }

    /// Enter while dictating: take the pending words now and stop without waiting for a final.
    func stopForSubmit() -> String? {
        let pending = interim.trimmingCharacters(in: .whitespacesAndNewlines)
        cancel()
        return pending.isEmpty ? nil : pending
    }

    private func receiveOnDevice(_ update: VoiceOnDeviceRecognition.Update, session id: UUID) {
        guard id == session else { return }
        switch update {
        case .partial(let text): apply(.interim(text))
        case .final(let text):
            if !text.isEmpty { apply(.final(text)) }
            if phase == .finishing { completeFinishing() }
        case .failed(let message):
            if phase == .finishing { completeFinishing() } else { fail(message, session: id) }
        }
    }

    private func apply(_ update: VoiceTranscriptUpdate) {
        switch update {
        case .interim(let text):
            heardSpeech = true
            if interim != text { interim = text }
        case .final(let text):
            heardSpeech = true
            interim = ""
            insertFinal?(text)
        }
    }

    private func completeFinishing() {
        guard phase == .finishing else { return }
        // Words still pending when the service goes quiet are kept rather than lost.
        let pending = interim.trimmingCharacters(in: .whitespacesAndNewlines)
        interim = ""
        if !pending.isEmpty { insertFinal?(pending) }
        session = UUID()
        teardown()
    }

    private func armNoSpeechWatchdog(session id: UUID) {
        schedule(after: Self.noSpeechTimeout, session: id) { controller in
            guard !controller.heardSpeech, controller.phase == .recording else { return }
            controller.fail("No speech was detected. Voice stopped.", session: id)
        }
    }

    private func fail(_ message: String, session id: UUID) {
        guard id == session, phase != .idle else { return }
        session = UUID()
        teardown()
        report?("Voice: \(message)")
    }

    private func schedule(after seconds: TimeInterval, session id: UUID, _ action: @escaping (VoiceDictationController) -> Void) {
        timers.append(Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.session == id else { return }
            action(self)
        })
    }

    private func teardown() {
        timers.forEach { $0.cancel() }
        timers = []
        capture?.stop(); capture = nil
        pipe = nil
        recognition?.cancel(); recognition = nil
        sink = nil
        transcriber = nil
        transcriptionQueue?.cancel(); transcriptionQueue = nil
        pendingTranscriptions = 0
        interim = ""
        phase = .idle
    }

    /// Shows a fixed recording state, for rendering snapshots of the composer.
    func showPreview(phase: Phase, engine: Engine = .openRouter, interim: String = "") {
        self.phase = phase
        self.engine = engine
        self.interim = interim
    }
}

/// On-device speech recognition, used when there is no OpenRouter key for dictation.
private final class VoiceOnDeviceRecognition: @unchecked Sendable {
    enum Update { case partial(String), final(String), failed(String) }

    private let lock = NSLock()
    private let language: String
    private let deliver: (Update) -> Void
    private let capture = VoiceAudioCapture()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finishing = false

    init(language: String, deliver: @escaping (Update) -> Void) {
        self.language = language
        self.deliver = deliver
    }

    static func isAvailable(language: String) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale(for: language)) else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    /// Speech models are per region: prefer the Mac's own region for the language, then any.
    static func locale(for language: String) -> Locale {
        let supported = SFSpeechRecognizer.supportedLocales()
        let current = Locale.current
        func code(_ locale: Locale) -> String? { locale.language.languageCode?.identifier }
        let candidates = supported.filter { code($0) == language }
        if code(current) == language, let match = candidates.first(where: { $0.region == current.region }) { return match }
        // Otherwise the language's most likely region, such as en → US or pt → BR.
        let likely = Locale.Language(identifier: Locale.Language(identifier: language).maximalIdentifier).region
        return candidates.first { $0.region == likely } ?? candidates.min { $0.identifier < $1.identifier } ?? Locale(identifier: language)
    }

    func start() throws {
        guard let recognizer = SFSpeechRecognizer(locale: Self.locale(for: language)), recognizer.supportsOnDeviceRecognition else {
            throw ComposerCommandMessage("on-device dictation is not available for this language")
        }
        self.recognizer = recognizer
        beginTask()
        try capture.start { [weak self] buffer in
            guard let self else { return }
            self.lock.lock(); let request = self.request; self.lock.unlock()
            request?.append(buffer)
        }
    }

    private func beginTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Audio never leaves this Mac on the fallback path.
        request.requiresOnDeviceRecognition = true
        request.addsPunctuation = true
        lock.lock(); self.request = request; lock.unlock()
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.isFinal {
                    self.deliver(.final(text))
                    self.lock.lock(); let finishing = self.finishing; self.lock.unlock()
                    // Recognition ends an utterance after a long pause; keep listening with a new one.
                    if !finishing { self.beginTask() }
                } else if !text.isEmpty {
                    self.deliver(.partial(text))
                }
            } else if let error {
                self.deliver(.failed(error.localizedDescription))
            }
        }
        lock.lock(); self.task = task; lock.unlock()
    }

    func finish() {
        lock.lock(); finishing = true; let request = self.request; lock.unlock()
        capture.stop()
        request?.endAudio()
    }

    func cancel() {
        lock.lock(); finishing = true; let task = self.task; lock.unlock()
        capture.stop()
        task?.cancel()
    }
}

// MARK: - Recording row

/// "Recording" above the prompt: a pulsing dot, the words heard so far, and Stop.
struct VoiceRecordingRow: View {
    @ObservedObject var voice: VoiceDictationController
    var onStop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        if voice.isActive {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Circle().fill(ComposerPalette.recording).frame(width: 8, height: 8)
                    .opacity(voice.phase == .recording && pulse ? 0.35 : 1)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink).fixedSize()
                Text(voice.interim.isEmpty ? placeholder : voice.interim)
                    .font(.system(size: 13)).foregroundStyle(Theme.muted.opacity(voice.interim.isEmpty ? 0.7 : 1))
                    .lineLimit(2).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Theme.hover, in: Capsule())
                }.buttonStyle(.plain).help("Stop dictation · esc").accessibilityLabel("Stop dictation")
                    .disabled(voice.phase == .finishing)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(ComposerPalette.recording.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ComposerPalette.recording.opacity(0.25), lineWidth: 0.5))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Dictation: \(title)")
        }
    }

    private var title: String {
        switch voice.phase {
        case .starting: return "Starting…"
        case .finishing: return voice.engine == .openRouter ? "Transcribing…" : "Finishing…"
        default:
            switch voice.engine {
            case .onDevice: return "Recording · On this Mac"
            case .openRouter: return "Recording · OpenRouter"
            }
        }
    }

    private var placeholder: String {
        if voice.phase == .starting { return "Getting the microphone ready" }
        guard voice.engine == .openRouter else { return "Speak — words appear at the cursor. ↵ sends, esc stops." }
        if voice.phase == .finishing { return "Adding your last words…" }
        return voice.transcribing ? "Transcribing… keep talking." : "Speak — words appear after each pause. ↵ or esc stops."
    }
}

/// The microphone button in the composer controls.
struct VoiceMicButton: View {
    @ObservedObject var voice: VoiceDictationController
    var shortcut: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: voice.isActive ? "mic.fill" : "mic")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(voice.isActive ? ComposerPalette.recording : Theme.ink)
                .frame(width: 36, height: 40).contentShape(Circle())
        }
        .buttonStyle(ComposerControlStyle())
        .help(voice.isActive ? "Stop dictation" : "Dictate" + (shortcut.map { " · \($0)" } ?? ""))
        .accessibilityLabel(voice.isActive ? "Stop dictation" : "Dictate")
    }
}
