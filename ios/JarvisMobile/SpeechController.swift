import AVFoundation
import Speech
import SwiftUI

@MainActor
final class SpeechController: ObservableObject {
    @Published var status = "Sesli komut için basılı tutun."
    @Published var transcript = ""
    @Published var recording = false
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var pressed = false
    private var tapped = false
    private let synthesizer = AVSpeechSynthesizer()
    func begin() async {
        guard !pressed else { return }; pressed = true
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let microphone = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard pressed else { return }
        guard speech, microphone else { status = "Mikrofon veya konuşma izni yok. Yazarak devam edebilirsiniz."; pressed = false; return }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            status = "Bu cihazda çevrimdışı Türkçe tanıma kullanılamıyor. Yazarak devam edin."; pressed = false; return
        }
        do {
            synthesizer.stopSpeaking(at: .immediate)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            self.request = request; transcript = ""
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
            tapped = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let finished = result?.isFinal == true || error != nil
                Task { @MainActor in
                    guard let self else { return }
                    if let text { self.transcript = text }
                    if finished { self.stop(); self.status = error == nil ? "Metni kontrol edip Gönder'e dokunun." : "Tanıma tamamlanamadı. Yazarak devam edin." }
                }
            }
            engine.prepare(); try engine.start(); recording = true; status = "Dinleniyor…"
        } catch { stop(); status = "Mikrofon başlatılamadı. Yazarak devam edin." }
    }
    func stop() {
        pressed = false; engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        request?.endAudio(); task?.cancel(); task = nil; request = nil; recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    func speak(_ text: String) {
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let utterance = AVSpeechUtterance(string: text); utterance.voice = AVSpeechSynthesisVoice(language: "tr-TR")
            synthesizer.speak(utterance)
        } catch { status = "Sesli cevap başlatılamadı." }
    }
}
