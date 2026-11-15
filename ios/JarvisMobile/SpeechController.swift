import AVFoundation
import Speech
import SwiftUI
import JarvisCore

@MainActor
final class SpeechController: ObservableObject {
    @Published private(set) var status = "Sesli komut için basılı tutun."
    @Published private(set) var transcript = ""
    @Published private(set) var recording = false
    @Published private(set) var requestingPermissions = false
    @Published private(set) var finishing = false
    @Published private(set) var needsSettings = false
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    private let synthesizer = AVSpeechSynthesizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finishTimeout: Task<Void, Never>?
    private var sessionID: UUID?
    private var pressed = false
    private var tapped = false
    private var interruptionObserver: NSObjectProtocol?

    init() {
        // The callback only transfers a signal; AVFoundation objects stay on the main actor.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancel()
                self?.status = "Ses oturumu kesildi. Yeniden deneyebilir veya yazarak devam edebilirsiniz."
            }
        }
    }

    /// This explicit onboarding action asks for access without opening the microphone.
    func requestPermissions() async {
        guard !requestingPermissions, !recording, !finishing else { return }
        _ = await authorize()
    }

    func begin() async {
        guard !pressed, !requestingPermissions, !finishing else { return }
        let id = UUID(); sessionID = id; pressed = true
        let authorized = await authorize()
        // A release/background event while a system dialog is open invalidates this capture.
        guard authorized, pressed, sessionID == id else {
            if sessionID == id { pressed = false; sessionID = nil }
            return
        }
        do {
            synthesizer.stopSpeaking(at: .immediate)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            self.request = request; transcript = ""
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noAudioInput }
            let sink = AudioRequestSink(request: request)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [sink] buffer, _ in
                sink.append(buffer)
            }
            tapped = true
            task = recognizer?.recognitionTask(with: request) { @Sendable [weak self] result, error in
                // Transfer only value types from the Speech callback.
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal == true
                let failed = error != nil
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == id else { return }
                    if let text { self.transcript = text }
                    if isFinal || failed {
                        self.completeRecognition()
                        self.status = failed && self.transcript.isEmpty
                            ? "Tanıma tamamlanamadı. Yazarak devam edebilirsiniz."
                            : "Metni kontrol edip Gönder'e dokunun."
                    }
                }
            }
            engine.prepare(); try engine.start()
            recording = true; status = "Dinleniyor…"
        } catch {
            cancel(); status = "Mikrofon başlatılamadı. Yazarak devam edebilirsiniz."
        }
    }

    /// Stop audio capture, but let Speech deliver the final transcription before cleanup.
    func stop() {
        pressed = false
        guard recording else {
            // Cancels a pending authorization-to-capture transition.
            if !finishing { sessionID = nil }
            return
        }
        stopAudio(); request?.endAudio(); finishing = true
        status = "Konuşma metni tamamlanıyor…"
        let id = sessionID
        finishTimeout?.cancel()
        finishTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.sessionID == id else { return }
            self.completeRecognition()
            self.status = self.transcript.isEmpty
                ? "Konuşma algılanmadı. Yeniden deneyebilir veya yazabilirsiniz."
                : "Metni kontrol edip Gönder'e dokunun."
        }
    }

    /// Backgrounding or interruption must not keep an input device or delayed capture alive.
    func cancel() {
        pressed = false; sessionID = nil
        finishTimeout?.cancel(); finishTimeout = nil
        stopAudio(); request?.endAudio(); task?.cancel(); task = nil; request = nil
        finishing = false
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func speak(_ text: String) {
        cancel()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "tr-TR")
            synthesizer.speak(utterance)
        } catch { status = "Sesli cevap başlatılamadı." }
    }

    private func authorize() async -> Bool {
        requestingPermissions = true
        defer { requestingPermissions = false }
        needsSettings = false
        var policy = permissionPolicy()
        if policy.decision == .requestSpeech {
            status = "Türkçe konuşma tanıma izni bekleniyor…"
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
            }
            policy = permissionPolicy()
        }
        if policy.decision == .requestMicrophone {
            status = "Mikrofon izni bekleniyor…"
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                AVAudioApplication.requestRecordPermission { _ in continuation.resume() }
            }
            policy = permissionPolicy()
        }
        switch policy.decision {
        case .ready:
            status = "Cihaz içi Türkçe tanıma hazır. Konuşmak için basılı tutun."
            return true
        case .denied:
            needsSettings = true
            status = "Mikrofon veya konuşma izni kapalı. Ayarlar'dan açabilir veya yazarak devam edebilirsiniz."
        case .restricted:
            status = "Ses erişimi cihaz tarafından kısıtlanıyor. Yazarak devam edebilirsiniz."
        case .unavailable:
            status = "Bu cihazda çevrimdışı Türkçe tanıma kullanılamıyor. Yazarak devam edebilirsiniz."
        case .requestSpeech, .requestMicrophone:
            status = "Ses izni tamamlanmadı. Yeniden deneyebilir veya yazabilirsiniz."
        }
        return false
    }

    private func permissionPolicy() -> SpeechPermissionPolicy {
        let speech: SpeechPermissionPolicy.Authorization
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = .authorized
        case .notDetermined: speech = .notDetermined
        case .denied: speech = .denied
        case .restricted: speech = .restricted
        @unknown default: speech = .restricted
        }
        let microphone: SpeechPermissionPolicy.Authorization
        switch AVAudioApplication.shared.recordPermission {
        case .granted: microphone = .authorized
        case .undetermined: microphone = .notDetermined
        case .denied: microphone = .denied
        @unknown default: microphone = .restricted
        }
        return SpeechPermissionPolicy(speech: speech, microphone: microphone,
            onDeviceSupported: recognizer?.supportsOnDeviceRecognition == true,
            recognizerAvailable: recognizer?.isAvailable == true)
    }
    private func stopAudio() {
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        recording = false
    }
    private func completeRecognition() {
        sessionID = nil; pressed = false
        finishTimeout?.cancel(); finishTimeout = nil
        stopAudio(); request?.endAudio(); task?.cancel(); task = nil; request = nil; finishing = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private enum CaptureError: Error { case noAudioInput }
}

/// SFSpeechAudioBufferRecognitionRequest is designed to accept buffers on the audio tap
/// thread. Only this append operation crosses that thread; controller state never does.
private final class AudioRequestSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    init(request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
}
