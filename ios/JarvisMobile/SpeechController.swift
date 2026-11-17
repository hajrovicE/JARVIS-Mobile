import AVFoundation
import JarvisCore
import Speech
import SwiftUI
import UIKit

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
  @Published private(set) var outputStreaming = false
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
      .first
  }()
  private var outputQueue = SpeechResponseQueue()
  private var pendingUtterances: [ObjectIdentifier: (response: UUID, utterance: UUID)] = [:]
  private var speechStream = TurkishSpeechStream()
  private var streamingRate = AVSpeechUtteranceDefaultSpeechRate
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

  func begin(autoStopOnSilence: Bool = false,
             onCaptureStarted: (@MainActor (UUID) -> Void)? = nil) async {
    guard UIApplication.shared.applicationState == .active,
          !Task.isCancelled, !pressed, !requestingPermissions, !finishing else { return }
    let id = captureGate.begin()
    self.autoStopOnSilence = autoStopOnSilence
    recognitionID = id
    pressed = true
    transcript = ""
    finishedVoiceTurn = nil
    onCaptureStarted?(id)
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
            if isFinal && !failed && !finalText.isEmpty {
              self.finishedVoiceTurn = FinishedVoiceTurn(id: id, text: finalText)
            }
            self.status =
              failed
              ? "Tanıma tamamlanamadı. Metni kontrol edip Gönder'e dokunabilir veya yazabilirsiniz."
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
      // A timeout contains only a partial hypothesis. Keep it editable,
      // but do not promote it into an automatically submitted final command.
      self.status =
        finalText.isEmpty
        ? "Konuşma algılanmadı. Yeniden deneyebilir veya yazabilirsiniz."
        : "Sonuç kesinleşmedi. Metni kontrol edip Gönder'e dokunun."
    }
  }

  /// Backgrounding or interruption must not keep an input device or delayed capture alive.
  func cancel() {
    let wasSpeaking = speaking || outputStreaming
    let wasCapturing = pressed || recording || finishing
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
    finishedVoiceTurn = nil
    stopOutput()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    if wasSpeaking {
      status = "Sesli cevap durduruldu. Cevabı okuyabilir veya yeniden dinleyebilirsiniz."
    } else if wasCapturing {
      status = "Sesli giriş durduruldu. Yazarak devam edebilirsiniz."
    }
  }

  /// Explicit opt-in creates a response, but audio starts only once a reliable
  /// sentence arrives. No recording permission is requested by output playback.
  @discardableResult
  func beginStreamingResponse(rate: Float = AVSpeechUtteranceDefaultSpeechRate) -> UUID {
    cancel()
    naturallyFinishedOutputID = nil
    speechStream = TurkishSpeechStream()
    streamingRate = rate.isFinite
      ? min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate))
      : AVSpeechUtteranceDefaultSpeechRate
    let id = outputQueue.begin()
    outputStreaming = true
    return id
  }

  func appendStreamingText(_ delta: String, responseID: UUID) {
    guard outputQueue.responseID == responseID else { return }
    for sentence in speechStream.append(delta) { enqueueSpeech(sentence, responseID: responseID) }
  }

  func finishStreamingResponse(responseID: UUID) {
    guard outputQueue.responseID == responseID else { return }
    for sentence in speechStream.finish() { enqueueSpeech(sentence, responseID: responseID) }
    applyOutputOutcome(outputQueue.finishInput(responseID: responseID))
  }

  /// The completed-response compatibility path uses the same queue and sentence
  /// renderer; a response is never queued both here and in the streaming path.
  func speak(_ text: String, rate: Float = AVSpeechUtteranceDefaultSpeechRate) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    let id = beginStreamingResponse(rate: rate)
    appendStreamingText(text, responseID: id)
    finishStreamingResponse(responseID: id)
  }

  private func enqueueSpeech(_ sentence: String, responseID: UUID) {
    guard UIApplication.shared.applicationState == .active,
          outputQueue.responseID == responseID else { return }
    guard let voice = turkishVoice else {
      stopOutput()
      status = "Türkçe sesli cevap bu cihazda kullanılamıyor. Cevabı okuyabilirsiniz."
      return
    }
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback, mode: .spokenAudio, options: .duckOthers)
      try AVAudioSession.sharedInstance().setActive(true)
      if synthesizer == nil {
        let output = AVSpeechSynthesizer()
        let delegate = SpeechOutputDelegate { @Sendable [weak self] utteranceID, token, finished in
          Task { @MainActor [weak self] in self?.completeOutput(utteranceID, token: token, finished: finished) }
        }
        output.delegate = delegate
        synthesizer = output
        outputDelegate = delegate
      }
      guard let queuedID = outputQueue.enqueue(responseID: responseID) else { return }
      let utterance = AVSpeechUtterance(string: sentence)
      utterance.voice = voice
      utterance.rate = streamingRate
      utterance.postUtteranceDelay = 0.09
      pendingUtterances[ObjectIdentifier(utterance)] = (responseID, queuedID)
      outputDelegate?.register(utterance, token: SpeechOutputToken(response: responseID, utterance: queuedID))
      speaking = true
      status = "Cevap seslendiriliyor…"
      synthesizer?.speak(utterance)
    } catch {
      stopOutput()
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      status = "Sesli cevap başlatılamadı. Cevabı okuyabilirsiniz."
    }
  }

  private func stopOutput() {
    outputQueue.cancel()
    outputDelegate?.invalidate()
    pendingUtterances.removeAll()
    outputStreaming = false
    speaking = false
    naturallyFinishedOutputID = nil
    synthesizer?.stopSpeaking(at: .immediate)
  }

  private func completeOutput(_ id: ObjectIdentifier, token: SpeechOutputToken?, finished: Bool) {
    guard let token, let expected = pendingUtterances[id],
          expected.response == token.response, expected.utterance == token.utterance else { return }
    pendingUtterances.removeValue(forKey: id)
    applyOutputOutcome(outputQueue.complete(utteranceID: token.utterance,
        responseID: token.response, finished: finished))
  }

  private func applyOutputOutcome(_ outcome: SpeechResponseQueue.Outcome) {
    switch outcome {
    case .ignored: return
    case .waiting:
      speaking = outputQueue.hasPendingUtterances
      if !speaking { status = "Yanıtın devamı bekleniyor…" }
    case .cancelled:
      stopOutput()
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      status = "Sesli cevap durduruldu. Cevabı okuyabilir veya yeniden dinleyebilirsiniz."
    case .completed(let id):
      outputStreaming = false
      speaking = false
      if !recording && !finishing {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      }
      status = "Sesli cevap tamamlandı. Yazarak veya konuşarak devam edebilirsiniz."
      naturallyFinishedOutputID = id
    case .empty:
      outputStreaming = false
      speaking = false
      status = "Seslendirilecek metin yok. Cevabı okuyabilirsiniz."
    }
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
struct SpeechOutputToken: Sendable {
  let response: UUID
  let utterance: UUID
}

final class SpeechOutputDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var identities: [ObjectIdentifier: SpeechOutputToken] = [:]
  private let stopped: @Sendable (ObjectIdentifier, SpeechOutputToken?, Bool) -> Void
  init(stopped: @escaping @Sendable (ObjectIdentifier, SpeechOutputToken?, Bool) -> Void) {
    self.stopped = stopped
  }
  func register(_ utterance: AVSpeechUtterance, token: SpeechOutputToken) {
    lock.lock(); defer { lock.unlock() }
    identities[ObjectIdentifier(utterance)] = token
  }
  func invalidate() {
    lock.lock(); defer { lock.unlock() }
    identities.removeAll()
  }
  private func take(_ id: ObjectIdentifier) -> SpeechOutputToken? {
    lock.lock(); defer { lock.unlock() }
    return identities.removeValue(forKey: id)
  }
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    let id = ObjectIdentifier(utterance)
    stopped(id, take(id), true)
  }
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    let id = ObjectIdentifier(utterance)
    stopped(id, take(id), false)
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
