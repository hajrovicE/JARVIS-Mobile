import AVFoundation
import JarvisCore
import Speech
import SwiftUI

/// Final, locally recognized speech. No partial or network-backed transcript
/// should trigger an automatic model request.
struct FinishedVoiceTurn: Equatable {
  let id: UUID
  let text: String
}

@MainActor
final class SpeechController: ObservableObject {
  @Published private(set) var status = "Sesli komut için basılı tutun."
  @Published private(set) var transcript = ""
  @Published private(set) var finishedVoiceTurn: FinishedVoiceTurn?
  @Published private(set) var naturallyFinishedOutputID: UUID?
  @Published private(set) var recording = false
  @Published private(set) var requestingPermissions = false
  @Published private(set) var finishing = false
  @Published private(set) var needsSettings = false
  @Published private(set) var speaking = false
  // Text-only use does not construct audio capture, Speech or TTS resources.
  private var engine: AVAudioEngine?
  private lazy var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "tr-TR"))
  private var synthesizer: AVSpeechSynthesizer?
  private var outputDelegate: SpeechOutputDelegate?
  // Prefer an installed enhanced Turkish voice, while keeping the device's
  // default Turkish voice as a reliable offline fallback.
  private lazy var turkishVoice: AVSpeechSynthesisVoice? = {
    AVSpeechSynthesisVoice.speechVoices()
      .filter { $0.language == "tr-TR" }
      .sorted { $0.quality.rawValue > $1.quality.rawValue }
      .first ?? AVSpeechSynthesisVoice(language: "tr-TR")
  }()
  private var activeUtteranceID: ObjectIdentifier?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var finishTimeout: Task<Void, Never>?
  private var silenceTimeout: Task<Void, Never>?
  private var autoStopOnSilence = false
  private var captureGate = SpeechCaptureGate()
  private var recognitionID: UUID?
  private var pressed = false
  private var tapped = false
  private var interruptionObserver: SpeechInterruptionObservation?

  init() {
    // The callback only transfers a signal; AVFoundation objects stay on the main actor.
    interruptionObserver = SpeechInterruptionObservation { @Sendable [weak self] in
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

  func begin(autoStopOnSilence: Bool = false) async {
    guard !Task.isCancelled, !pressed, !requestingPermissions, !finishing else { return }
    let id = captureGate.begin()
    self.autoStopOnSilence = autoStopOnSilence
    recognitionID = id
    pressed = true
    let authorized = await authorize()
    // A release/background event while a system dialog is open invalidates this capture.
    guard authorized, pressed, captureGate.canStart(id, taskCancelled: Task.isCancelled) else {
      if captureGate.isCurrent(id) {
        pressed = false
        captureGate.cancel()
      }
      return
    }
    do {
      stopOutput()
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true)
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.requiresOnDeviceRecognition = true
      request.shouldReportPartialResults = true
      self.request = request
      transcript = ""
      finishedVoiceTurn = nil
      let engine = AVAudioEngine()
      self.engine = engine
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
          guard let self, self.captureGate.isCurrent(id) else { return }
          if let text {
            let changed = text != self.transcript
            self.transcript = text
            if changed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              self.scheduleEndOfSpeech(for: id)
            }
          }
          if isFinal || failed {
            let finalText = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            self.completeRecognition()
            if !finalText.isEmpty {
              self.finishedVoiceTurn = FinishedVoiceTurn(id: UUID(), text: finalText)
            }
            self.status =
              failed && finalText.isEmpty
              ? "Tanıma tamamlanamadı. Yazarak devam edebilirsiniz."
              : "Konuşma metni hazır."
          }
        }
      }
      engine.prepare()
      try engine.start()
      recording = true
      status = "Dinleniyor…"
    } catch {
      cancel()
      status = "Mikrofon başlatılamadı. Yazarak devam edebilirsiniz."
    }
  }

  /// Ends a spoken turn after a short pause, only for foreground hands-free mode.
  /// No microphone is started by this timer. Manual push-to-talk is unaffected.
  private func scheduleEndOfSpeech(for id: UUID) {
    guard autoStopOnSilence, recording, !finishing else { return }
    silenceTimeout?.cancel()
    silenceTimeout = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(1_350)) }
      catch { return }
      guard let self, self.captureGate.isCurrent(id), self.recording, !self.finishing else { return }
      self.stop()
    }
  }

  /// Stop audio capture, but let Speech deliver the final transcription before cleanup.
  func stop() {
    silenceTimeout?.cancel()
    silenceTimeout = nil
    pressed = false
    guard recording else {
      // Cancels a pending authorization-to-capture transition.
      if !finishing { captureGate.cancel() }
      return
    }
    stopAudio()
    request?.endAudio()
    finishing = true
    status = "Konuşma metni tamamlanıyor…"
    let id = recognitionID
    finishTimeout?.cancel()
    finishTimeout = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      guard let self, let id, self.captureGate.isCurrent(id) else { return }
      let finalText = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
      self.completeRecognition()
      if !finalText.isEmpty {
        self.finishedVoiceTurn = FinishedVoiceTurn(id: UUID(), text: finalText)
      }
      self.status =
        finalText.isEmpty
        ? "Konuşma algılanmadı. Yeniden deneyebilir veya yazabilirsiniz."
        : "Konuşma metni hazır."
    }
  }

  /// Backgrounding or interruption must not keep an input device or delayed capture alive.
  func cancel() {
    silenceTimeout?.cancel()
    silenceTimeout = nil
    pressed = false
    captureGate.cancel()
    recognitionID = nil
    finishTimeout?.cancel()
    finishTimeout = nil
    stopAudio()
    request?.endAudio()
    task?.cancel()
    task = nil
    request = nil
    finishing = false
    stopOutput()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  /// The UI calls this only after its explicit TTS opt-in. No recording permission is
  /// requested to play a response, and completion/cancellation releases the audio session.
  func speak(_ text: String, rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
    cancel()
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    guard let voice = turkishVoice else {
      status = "Türkçe sesli cevap bu cihazda kullanılamıyor. Cevabı okuyabilirsiniz."
      return
    }
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback, mode: .spokenAudio, options: .duckOthers)
      try AVAudioSession.sharedInstance().setActive(true)
      if synthesizer == nil {
        let output = AVSpeechSynthesizer()
        let delegate = SpeechOutputDelegate { @Sendable [weak self] utteranceID, cancelled in
          Task { @MainActor [weak self] in self?.completeOutput(utteranceID, cancelled: cancelled) }
        }
        output.delegate = delegate
        synthesizer = output
        outputDelegate = delegate
      }
      let chunks = TurkishSpeechChunker.chunks(value)
      guard !chunks.isEmpty else { return }
      let utterances = chunks.map { chunk -> AVSpeechUtterance in
        let utterance = AVSpeechUtterance(string: chunk)
        utterance.voice = voice
        utterance.rate = min(0.58, max(0.44, rate))
        utterance.postUtteranceDelay = 0.07
        return utterance
      }
      // Only the LAST queued utterance completes the spoken turn. No early
      // microphone restart in the gap between individual sentences.
      activeUtteranceID = utterances.last.map(ObjectIdentifier.init)
      speaking = true
      status = "Cevap seslendiriliyor…"
      for utterance in utterances { synthesizer?.speak(utterance) }
    } catch {
      cancel()
      status = "Sesli cevap başlatılamadı. Cevabı okuyabilirsiniz."
    }
  }

  private func stopOutput() {
    activeUtteranceID = nil
    speaking = false
    synthesizer?.stopSpeaking(at: .immediate)
  }
  private func completeOutput(_ id: ObjectIdentifier, cancelled: Bool) {
    guard activeUtteranceID == id else { return }
    activeUtteranceID = nil
    speaking = false
    if !recording && !finishing {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    status = "Sesli cevap tamamlandı. Yazarak veya konuşarak devam edebilirsiniz."
    if !cancelled { naturallyFinishedOutputID = UUID() }
  }

  private func authorize() async -> Bool {
    guard !Task.isCancelled else { return false }
    requestingPermissions = true
    defer { requestingPermissions = false }
    needsSettings = false
    var policy = permissionPolicy()
    if policy.decision == .requestSpeech {
      status = "Türkçe konuşma tanıma izni bekleniyor…"
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
      }
      guard !Task.isCancelled else { return false }
      policy = permissionPolicy()
    }
    if policy.decision == .requestMicrophone {
      status = "Mikrofon izni bekleniyor…"
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        AVAudioApplication.requestRecordPermission { _ in continuation.resume() }
      }
      policy = permissionPolicy()
    }
    guard !Task.isCancelled else { return false }
    switch policy.decision {
    case .ready:
      status = "Cihaz içi Türkçe tanıma hazır. Konuşmak için basılı tutun."
      return true
    case .denied:
      needsSettings = true
      status =
        "Mikrofon veya konuşma izni kapalı. Ayarlar'dan açabilir veya yazarak devam edebilirsiniz."
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
    return SpeechPermissionPolicy(
      speech: speech, microphone: microphone,
      onDeviceSupported: recognizer?.supportsOnDeviceRecognition == true,
      recognizerAvailable: recognizer?.isAvailable == true)
  }
  private func stopAudio() {
    if let engine {
      engine.stop()
      if tapped { engine.inputNode.removeTap(onBus: 0) }
    }
    tapped = false
    self.engine = nil
    recording = false
  }
  private func completeRecognition() {
    silenceTimeout?.cancel()
    silenceTimeout = nil
    captureGate.cancel()
    recognitionID = nil
    pressed = false
    finishTimeout?.cancel()
    finishTimeout = nil
    stopAudio()
    request?.endAudio()
    task?.cancel()
    task = nil
    request = nil
    finishing = false
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

/// AVFoundation may call these delegate methods away from the main actor. Only an
/// immutable utterance identity crosses that boundary; session state stays on the actor.
private final class SpeechOutputDelegate: NSObject, AVSpeechSynthesizerDelegate {
  private let stopped: @Sendable (ObjectIdentifier, Bool) -> Void
  init(stopped: @escaping @Sendable (ObjectIdentifier, Bool) -> Void) { self.stopped = stopped }
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    stopped(ObjectIdentifier(utterance), false)
  }
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    stopped(ObjectIdentifier(utterance), true)
  }
}

/// The notification token has no actor-bound state and is always removed on release.
private final class SpeechInterruptionObservation {
  private let token: NSObjectProtocol
  init(interrupted: @escaping @Sendable () -> Void) {
    token = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: nil, queue: .main
    ) { _ in interrupted() }
  }
  deinit { NotificationCenter.default.removeObserver(token) }
}
