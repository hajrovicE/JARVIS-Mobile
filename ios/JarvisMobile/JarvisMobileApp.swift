import JarvisCore
import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct JarvisMobileApp: App {
  var body: some Scene { WindowGroup { RootView() } }
}
struct ExportDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data
  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
@MainActor
struct RootView: View {
  @AppStorage("onboarded") private var onboarded = false
  @AppStorage("ttsEnabled") private var tts = false
  @StateObject private var speech = SpeechController()
  @State private var inferenceRuntime = GGUFInferenceRuntime()
  @AppStorage("jarvis.voice.autoSend") private var voiceAutoSend = true
  @AppStorage("jarvis.voice.handsFree") private var handsFreeVoice = false
  @AppStorage("jarvis.conversation.quickMode") private var quickMode = true
  @AppStorage("jarvis.voice.speechRate") private var speechRate = 0.53
  @State private var voiceCoordinator = NaturalVoiceTurnCoordinator()
  @State private var responseSeconds: Double?
  @State private var firstVisibleTokenSeconds: Double?
  @State private var generationStartedAt: TimeInterval?
  @State private var localRuntimeMetrics: LocalRuntimeMetrics?
  @State private var store: MemoryStore?
  @State private var modelManager: OnDeviceModelManager?
  @State private var draft = ChatDraft()
  @State private var activeGenerationID: UUID?
  @State private var hasStreamedReply = false
  @State private var lastResumedOutputID: UUID?
  @FocusState private var chatFocused: Bool
  @State private var reply = ""
  @State private var memories: [MemoryItem] = []
  @State private var history: [MemoryItem] = []
  @State private var learningRecords: [LearnedMemory] = []
  @State private var learningKey = ""
  @State private var learningText = ""
  @State private var errorText: String?
  @State private var exporting = false
  @State private var document = ExportDocument(data: Data())
  @State private var runningOperation: Task<Void, Never>?
  @State private var permissions = PermissionManager()
  @State private var holdStartTask: Task<Void, Never>?
  @State private var activeReply: StoredAIAnswer?
  @State private var experiences: [TaskExperience] = []
  @State private var correctionText = ""
  @State private var importingLocalModel = false
  @State private var localModelStatus = "Yerel JARVIS modeli henüz kurulmadı."
  @AppStorage("activeLocalModelManifest") private var activeLocalModelManifest = ""
  @AppStorage("jarvis.ownerInstructions") private var ownerInstructions = ""
  @AppStorage("jarvis.model.maxNewTokens") private var modelMaxNewTokens = 2048
  @AppStorage("jarvis.model.contextTokens") private var modelContextTokens = 8192
  @AppStorage("jarvis.model.temperature") private var modelTemperature = 0.8
  @AppStorage("jarvis.model.topP") private var modelTopP = 1.0
  @AppStorage("jarvis.model.cpuThreads") private var modelCPUThreads = 0
  @State private var busy = false
  @Environment(\.scenePhase) private var scenePhase
  var body: some View {
    Group {
      if !onboarded {
        onboardingView
      } else {
        TabView {
          chatTab
          memoryTab
          historyTab
          statusTab
          localModelTab
        }
      }
    }
    .task { await open() }
    .onChange(of: speech.transcript) { _, text in
      if !text.isEmpty { draft.edit(text) }
    }
    .onChange(of: speech.finishedVoiceTurn?.id) { _, id in
      guard let turn = speech.finishedVoiceTurn, id == turn.id, store != nil,
            voiceCoordinator.acceptFinal(
              id: turn.id, text: turn.text,
              appInForeground: scenePhase == .active,
              isBusy: busy, autoSend: voiceAutoSend,
              handsFree: handsFreeVoice, speakReplies: tts) else { return }
      draft.edit(turn.text)
      submit()
    }
    .onChange(of: speech.naturallyFinishedOutputID) { _, _ in resumeListeningIfEligible() }
    .onChange(of: busy) { _, isBusy in if !isBusy { resumeListeningIfEligible() } }
    .onChange(of: tts) { _, enabled in if !enabled { stopVoiceConversation(cancelGeneration: false) } }
    .onChange(of: handsFreeVoice) { _, enabled in if !enabled { stopVoiceConversation(cancelGeneration: false) } }
    .onChange(of: voiceAutoSend) { _, enabled in if !enabled { stopVoiceConversation(cancelGeneration: false) } }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
      stopVoiceConversation()
      Task { await inferenceRuntime.unload() }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active {
        // A submitted owner's inference request may not run unattended.
        runningOperation?.cancel()
        holdStartTask?.cancel()
        holdStartTask = nil
        voiceCoordinator.stopConversation()
        speech.cancel()
        if phase == .background {
          Task {
            await permissions.invalidateAll()
            await inferenceRuntime.unload()
          }
        }
      } else {
        Task { if store == nil { await open() } else { perform { try await refresh() } } }
      }
    }
    .onDisappear {
      stopVoiceConversation()
    }
    .alert(
      "İşlem tamamlanamadı",
      isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    ) {
      Button("Tamam") { errorText = nil }
    } message: {
      Text(errorText ?? "")
    }
    .fileExporter(
      isPresented: $exporting, document: document, contentType: .json,
      defaultFilename: "jarvis-verilerim"
    ) { result in
      if case .failure = result { errorText = "Dışa aktarma tamamlanamadı." }
      document = ExportDocument(data: Data())
    }
    .fileImporter(
      isPresented: $importingLocalModel,
      allowedContentTypes: [UTType(filenameExtension: "gguf") ?? .data, .data]
    ) { result in
      switch result {
      case .success(let url):
        perform {
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          guard let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
                size.int64Value > 0 else { throw LocalModelError.invalidFile }
          let manifest = try LocalModelManifest(
            identifier: "owner-model-" + UUID().uuidString.lowercased(),
            revision: "owner-selected", licenseIdentifier: "owner-provided",
            byteCount: size.int64Value, sha256: "")
          let manager = try sharedModelManager()
          _ = try await manager.importModel(from: url, manifest: manifest)
          await inferenceRuntime.unload()
          activeLocalModelManifest = String(
            decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
          localModelStatus = "Seçtiğin model içeriği yüklendi. Çıkarım testi bekleniyor."
        }
      case .failure:
        errorText = "Model dosyası seçilemedi."
      }
    }
  }
  private var onboardingView: some View {
    VStack(spacing: 20) {
      Text("JARVIS'e hoş geldiniz").font(.largeTitle)
      Text(
        "Konuşma geçmişi ve öğrenilen bilgiler siz silene kadar korunur. Güncelliği doğrulanmamış cevaplar otomatik güncel sayılmaz. Veriler uygulama tarafından ayrıca şifrelenmez."
      )
      Text(
        "Ses isteğe bağlıdır. İlk kullanımda mikrofon ve konuşma izni istenir. Yazarak da kullanabilirsiniz. Konuşmacı kimlik doğrulaması etkin değildir."
      )
      Button("Başla") { onboarded = true }.accessibilityIdentifier("onboarding.start")
    }.padding()
  }
  private var chatTab: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text(reply).textSelection(.enabled).accessibilityIdentifier("chat.reply")
          if let answer = activeReply {
            Text("AI yanıtı · \(answer.response.provider) / \(answer.response.model)").font(
              .caption)
            Text(answer.response.generatedAt, style: .date).font(.caption)
            Text(
              "Güncellik: \(answer.response.freshness == .verifiedStatic ? "kaynak metadata'sı doğrulanmış" : "doğrulanmadı")"
            ).font(.caption)
            Text("Bu yanıt otomatik işlem başlatmaz; yalnızca gönderdiğiniz komutlar çalışır.").font(
              .caption)
            ForEach(answer.response.sources) { source in
              Link(source.title, destination: source.url)
              Text(source.retrievedAt, style: .date).font(.caption)
            }
          }
          TextField("Hatırla ki …", text: Binding(
            get: { draft.text }, set: { draft.edit($0) }), axis: .vertical).textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("chat.input").focused($chatFocused)
          Button("Gönder") { submit() }.accessibilityIdentifier("chat.send").disabled(
            store == nil || busy || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Text("Sesli giriş isteğe bağlıdır. Tanıma cihazda yapılır; yazarak devam edebilirsiniz.")
          Button("Ses izinlerini ver") { Task { await speech.requestPermissions() } }
            .disabled(speech.requestingPermissions || speech.recording || speech.finishing)
          if speech.needsSettings, let settings = URL(string: UIApplication.openSettingsURLString) {
            Link("Ses izinleri için Ayarlar'ı aç", destination: settings)
          }
          Text(speech.status).accessibilityIdentifier("voice.status")
          Text(speech.recording ? "Dinleniyor…" : "Konuşmak için basılı tutun")
            .padding().background(.blue.opacity(0.15)).cornerRadius(12)
            .gesture(
              DragGesture(minimumDistance: 0).onChanged { _ in
                if holdStartTask == nil { startVoiceCapture(autoStop: false) }
              }
              .onEnded { _ in
                holdStartTask?.cancel()
                holdStartTask = nil
                speech.stop()
              }
            )
            .accessibilityAddTraits(.isButton)
          Button(speech.recording ? "Kaydı bitir" : "Ses kaydını başlat") {
            if speech.recording {
              holdStartTask?.cancel()
              holdStartTask = nil
              speech.stop()
            } else {
              startVoiceCapture(autoStop: handsFreeVoice)
            }
          }
          .disabled(speech.requestingPermissions || speech.finishing)
          Toggle("Akıcı sohbet · kısa ve hızlı yanıt", isOn: $quickMode).accessibilityIdentifier("conversation.quickMode")
          Text("Hızlı mod yanıt bütçesini azaltır; Qwen3'te kısa sohbet için /no_think kullanır. Sistem talimatınız ve açık düşünme seçiminiz korunur.")
            .font(.caption).foregroundStyle(.secondary)
          Toggle("Konuşmam bitince otomatik yanıtla", isOn: $voiceAutoSend).accessibilityIdentifier("voice.autoSend")
          Toggle("Ön planda kesintisiz sesli sohbet", isOn: $handsFreeVoice).accessibilityIdentifier("voice.handsFree")
            .disabled(!tts || !voiceAutoSend)
          Text("Kesintisiz sohbet yalnızca uygulama açıkken ve ilk sesli komutu başlattığınızda dinler. Başka uygulamaları veya arka planı izlemez.")
            .font(.caption).foregroundStyle(.secondary)
          Toggle("Cevapları sesli oku", isOn: $tts).accessibilityIdentifier("voice.tts")
          Slider(value: $speechRate,
                 in: Double(AVSpeechUtteranceMinimumSpeechRate)...Double(AVSpeechUtteranceMaximumSpeechRate),
                 step: 0.01) { Text("Konuşma hızı") }
            .accessibilityIdentifier("voice.rate")
          Text("Konuşma hızı: \(speechRate, format: .number.precision(.fractionLength(2)))")
            .font(.caption).foregroundStyle(.secondary)
          if let responseSeconds {
            Text("Son yanıt: \(responseSeconds, format: .number.precision(.fractionLength(1))) saniye")
              .font(.caption).foregroundStyle(.secondary)
          }
          if let firstVisibleTokenSeconds {
            Text("İlk görünür metin: \(firstVisibleTokenSeconds, format: .number.precision(.fractionLength(2))) sn")
              .font(.caption).foregroundStyle(.secondary)
          }
          if let localRuntimeMetrics {
            Text("İlk token: \(localRuntimeMetrics.firstTokenSeconds, format: .number.precision(.fractionLength(2))) sn · Hız: \(localRuntimeMetrics.tokensPerSecond, format: .number.precision(.fractionLength(1))) token/sn · \(localRuntimeMetrics.warmModel ? "Hazır model" : "İlk yükleme")")
              .font(.caption).foregroundStyle(.secondary)
            Text("Model yükleme: \(localRuntimeMetrics.modelLoadSeconds, format: .number.precision(.fractionLength(3))) sn · Bağlam: \(localRuntimeMetrics.contextInitSeconds, format: .number.precision(.fractionLength(3))) sn · İstek işleme: \(localRuntimeMetrics.prefillSeconds, format: .number.precision(.fractionLength(3))) sn")
              .font(.caption).foregroundStyle(.secondary)
            if let bytes = localRuntimeMetrics.residentMemoryBytes {
              Text("İşlem belleği: \(Double(bytes) / 1_048_576, format: .number.precision(.fractionLength(0))) MiB")
                .font(.caption).foregroundStyle(.secondary)
            }
            if let thermal = localRuntimeMetrics.thermalState {
              Text("İşletim sistemi termal durumu: " + thermal).font(.caption).foregroundStyle(.secondary)
            }
          }
          if speech.speaking || speech.outputStreaming { Button("Sesli cevabı durdur") { stopVoiceConversation() } }
          if busy { Button("Yanıtı durdur") { stopVoiceConversation() }.accessibilityIdentifier("chat.cancel") }
          if handsFreeVoice { Button("Sesli sohbeti bitir") { stopVoiceConversation() } }
        }.padding()
      }.navigationTitle("JARVIS")
    }.tabItem { Label("Sohbet", systemImage: "bubble.left") }
  }
  private var memoryTab: some View {
    NavigationStack {
      List {
        ForEach(memories) { memory in
          VStack(alignment: .leading) {
            TextField(
              "Kişisel hafıza",
              text: Binding(
                get: { memories.first { $0.id == memory.id }?.text ?? "" },
                set: { text in
                  if let index = memories.firstIndex(where: { $0.id == memory.id }) {
                    memories[index].text = text
                  }
                })
            )
            .accessibilityIdentifier("memory.text.\(memory.id)")
            Button("Değişikliği kaydet") {
              perform {
                try await store?.edit(
                  id: memory.id, text: memories.first { $0.id == memory.id }?.text ?? "")
              }
            }
            Button("Sil", role: .destructive) { executeOwnerCommand(.deleteMemory(memory.id)) }
              .accessibilityIdentifier("memory.delete.\(memory.id)")
          }
        }
        Section("Görev deneyimleri") {
          TextField("Görev için düzeltmeniz", text: $correctionText)
          ForEach(experiences.suffix(10).reversed()) { experience in
            VStack(alignment: .leading) {
              Text(experience.action)
              Text(experience.outcome == .succeeded ? "Gerçekleşti" : "Başarı kaydı yok")
              Button("Düzeltmeyi onaya sun") {
                perform {
                  try await store?.proposeTaskCorrection(
                    experienceID: experience.id,
                    key: "task:\(experience.action)", text: correctionText)
                  correctionText = ""
                }
              }.disabled(correctionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
          }
        }
        Button("Verilerimi dışa aktar") { executeOwnerCommand(.exportMemory) }
        Button("Tüm verileri sil", role: .destructive) { executeOwnerCommand(.deleteAllMemory) }
          .accessibilityIdentifier(
            "memory.deleteAll")
        Section("Öğrenme önerileri") {
          Text("Buradan doğrudan öğrettiğiniz bilgiler kaydedilir. Modelin önerileri ayrı değerlendirilir.")
          TextField("Konu (ör. içecek tercihi)", text: $learningKey)
          TextField("Tercih önerisi", text: $learningText)
          Button("Doğrudan öğret ve kaydet") { proposeLearning() }
            .disabled(
              learningKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || learningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          ForEach(learningRecords.filter { $0.supersededBy == nil }) { record in
            VStack(alignment: .leading) {
              Text(record.key).font(.headline)
              TextField(
                "Öğrenilen bilgi",
                text: Binding(
                  get: { learningRecords.first { $0.id == record.id }?.text ?? "" },
                  set: { value in
                    if let index = learningRecords.firstIndex(where: { $0.id == record.id }) {
                      learningRecords[index].text = value
                    }
                  }))
              Text(
                record.userConfirmed
                  ? "Kullanıcı onaylı · sürüm \(record.revision)" : "Onay bekliyor")
              Text(
                "Kaynak: \(record.provenance.sourceID) · güven: \(record.confidence, format: .number.precision(.fractionLength(2)))"
              )
              if !record.userConfirmed {
                Button("Onayla") {
                  perform {
                    try await store?.confirmLearning(
                      id: record.id,
                      expectedText: learningRecords.first { $0.id == record.id }?.text ?? "")
                  }
                }
              }
              Button("Düzelt ve onayla") {
                perform {
                  try await store?.correctLearning(
                    id: record.id, text: learningRecords.first { $0.id == record.id }?.text ?? "")
                }
              }
              Button("Öneriyi sil", role: .destructive) {
                executeOwnerCommand(.deleteLearning(record.id))
              }
            }
          }
        }

      }.buttonStyle(.borderless).disabled(store == nil || busy).navigationTitle("Kişisel hafıza")
    }.tabItem { Label("Hafıza", systemImage: "brain") }
  }
  private var historyTab: some View {
    NavigationStack { List(history) { Text($0.text) }.navigationTitle("Konuşma geçmişi") }
      .tabItem { Label("Geçmiş", systemImage: "clock") }
  }
  private var statusTab: some View {
    NavigationStack {
      List {
        Text("JARVIS modeli: cihazda çalışacak; bulut sağlayıcısı bağlı değil.")
        Text(localModelStatus)
        Text("Kişisel hafıza ve öğrenme verileri cihazda saklanır.")
        Text("Türkçe ses: cihazın çevrimdışı desteğine ve izinlere bağlı.")
        Text("Konuşmacı kimlik doğrulaması: ETKİN DEĞİL.")
          .accessibilityIdentifier("status.speakerIdentity")
        Text("Web arama ve telefon kontrolü: bağlı değil.")
        Text("Dış işlemler yalnızca doğrudan kullanıcı komutuyla başlatılır.")
        Text("Gerçek cihaz performans testi ve TestFlight yüklemesi henüz doğrulanmadı.")
      }.navigationTitle("Yetenek durumu")
    }.tabItem { Label("Durum", systemImage: "info.circle") }
  }

  private var localModelTab: some View {
    NavigationStack {
      Form {
        Section("JARVIS kendi yerel AI çekirdeği") {
          Text("Sohbet, modeli yükledikten sonra iPhone üzerinde çalışır. API anahtarı, model sağlayıcı hesabı veya bulut bağlantısı kullanılmaz.")
          Text("Başlangıç ağırlıkları: Qwen3 1.7B Q4_K_M (Apache-2.0). Bu, henüz JARVIS'e özel eğitilmiş bir ağırlık değildir.")
          Link("GGUF başlangıç modelini indir",
            destination: URL(string: "https://huggingface.co/ggml-org/Qwen3-1.7B-GGUF/blob/daeb8e2/Qwen3-1.7B-Q4_K_M.gguf")!)
          Button("Kendi GGUF modelimi dosyadan seç") { importingLocalModel = true }
          Text(localModelStatus)
          Text("Dosya uzantısı, SHA-256 sabitlemesi veya model kaynağı kısıtı yoktur. Çalıştırılabilir GGUF biçimi gereklidir.")
          Text("Hazır başlangıç modeli yaklaşık 1,28 GB; telefonda çalışma belleği ayrıca gerekir.")
        }
        Section("Sahibin davranış kuralları") {
          Text("Modelin cevap tarzını ve çalışma talimatlarını yalnızca siz belirliyorsunuz. Boş bırakırsanız ek davranış talimatı uygulanmaz.")
          TextEditor(text: $ownerInstructions)
            .frame(minHeight: 160)
            .accessibilityIdentifier("model.ownerInstructions")
          Text("Bu metin modele her istekte yerel olarak gönderilir; buluta aktarılmaz.")
          Text("Telefon üzerinde eylem başlatma yetkisi yalnızca o anki doğrudan komutunuzdan gelir.")
        }
        Section("Modelin üretim ayarları") {
          TextField("Yanıt için token bütçesi", value: $modelMaxNewTokens, format: .number)
            .keyboardType(.numberPad)
            .accessibilityIdentifier("model.maxNewTokens")
          TextField("Bağlam penceresi (token)", value: $modelContextTokens, format: .number)
            .keyboardType(.numberPad)
            .accessibilityIdentifier("model.contextTokens")
          TextField("Sıcaklık (0 = deterministik)", value: $modelTemperature, format: .number)
            .keyboardType(.decimalPad)
            .accessibilityIdentifier("model.temperature")
          TextField("Top-p (0–1)", value: $modelTopP, format: .number)
            .keyboardType(.decimalPad)
            .accessibilityIdentifier("model.topP")
          TextField("CPU iş parçacıkları (0 = otomatik)", value: $modelCPUThreads, format: .number)
            .keyboardType(.numberPad)
            .accessibilityIdentifier("model.cpuThreads")
          Text("Uygulama yapay karakter/token üst limiti koymaz. Modelin bağlam kapasitesi ve iPhone belleği aşılırsa çıkarım hata verebilir.")
        }
        Section("Çalışma biçimi") {
          Text("İnternetsiz varsayılan: JARVIS yalnızca kurulu modeli kullanır. Model yoksa hata verir, uzaktaki sağlayıcıya geçmez.")
          Text("Sahibinin açık komutu olmadan işlem başlatılmaz. Model yanıtı telefon eylemi değildir.")
          Text("Kendi eğittiğiniz uyumlu GGUF ağırlıklarını Dosyalar'dan seçerek başlangıç modelini değiştirebilirsiniz. Eğitim işlemi telefonda otomatik yapılmaz.")
        }
      }.navigationTitle("Yerel yapay zekâ")
    }.tabItem { Label("AI", systemImage: "cpu") }
  }

  private func executeOwnerCommand(_ operation: ActionOperation) {
    perform {
      guard let store else { return }
      try await runOwnerAction(operation, using: store)
    }
  }
  /// This method is reachable only from a direct user UI gesture / typed command.
  /// An AI reply is never an executable command.
  private func runOwnerAction(_ operation: ActionOperation, using store: MemoryStore) async throws {
    let request = ActionRequest(operation: operation, origin: .userInterface)
    let authorization = try await permissions.authorizeOwnerCommand(request)
    let result = try await ActionExecutor(store: store, permissions: permissions).execute(
      request, authorization: authorization)
    if let data = result.exportedData {
      document = ExportDocument(data: data)
      exporting = true
    }
    reply = result.message
    activeReply = nil
    if !result.succeeded || result.auditWriteFailed { errorText = result.message }
  }
  private func open() async {
    guard store == nil else { return }
    do {
      let directory = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      ).appendingPathComponent("Jarvis", isDirectory: true)
      let jsonURL = directory.appendingPathComponent("memory.json")
      let legacyURL = directory.appendingPathComponent("memory.aes")
      let plainStorage = try PlainFileStorage.migratingLegacySnapshot(
        to: jsonURL, legacyURL: legacyURL
      ) { try EncryptedFileStorage(url: legacyURL, keychainAccount: "primary").load() }
      store = try MemoryStore(storage: plainStorage)
      if let manifest = try? selectedModelManifest(),
         let modelURL = try? localModelDirectory().appendingPathComponent(manifest.identifier + ".gguf"),
         FileManager.default.fileExists(atPath: modelURL.path) {
        localModelStatus = "Kurulu model: " + manifest.identifier + ". GGUF çıkarımı ilk sohbet isteğinde çalıştırılacak."
      } else {
        localModelStatus = "Yerel model kurulmadı. GGUF dosyasını Dosyalar'dan yükleyin."
      }
      try await refresh()
    } catch {
      errorText = "Hafıza açılamadı veya eski kayıtlar taşınamadı. Kayıtlar korunmuştur; yeniden deneyin."
    }
  }
  private func refresh() async throws {
    if let state = try await store?.read() {
      memories = state.personal
      history =
        (state.conversations
        + state.generatedAnswers.map {
          MemoryItem(
            id: $0.id, text: "Siz: \($0.question)\nAI: \($0.response.text)", createdAt: $0.savedAt)
        }).sorted { $0.createdAt < $1.createdAt }
      learningRecords = state.learning.records
      experiences = state.learning.experiences
      if let current = activeReply, !state.generatedAnswers.contains(where: { $0.id == current.id })
      {
        activeReply = nil
        if reply == current.response.text {
          reply = "Hafıza değiştiği için önceki AI yanıtı temizlendi."
        }
      }
    }
  }
  private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    runningOperation = Task {
      defer {
        if activeGenerationID != nil { abortPartialReply(); voiceCoordinator.stopConversation() }
        busy = false
        runningOperation = nil
      }
      do {
        try await operation()
        try await refresh()
      } catch is CancellationError {
        abortPartialReply()
        voiceCoordinator.stopConversation()
      } catch LearningError.staleProposal {
        errorText =
          "Öneri metni değişti. Düzenlediğiniz metni kaydetmek için Düzelt ve onayla seçeneğini kullanın."
      } catch LearningError.conflictingRecord {
        errorText =
          "Aynı konuda farklı bir bilgi var. Tercihinizi değiştirmek için Düzelt ve onayla seçeneğini kullanın."
      } catch let error as LocalModelError {
        switch error {
        case .notInstalled, .runtimeUnavailable:
          errorText = "Yerel JARVIS modeli kurulu değil veya çıkarım motoru kullanılamıyor."
        case .invalidFile:
          errorText = "Dosya yerel GGUF motoruyla açılamadı."
        case .invalidSettings:
          errorText = "Model ayarları geçersiz. Bağlam, yanıt uzunluğu ve örneklemeyi kontrol edin."
        case .contextExceeded:
          errorText = "İstek seçilen model bağlamına sığmıyor. Bağlamı artırın veya isteği kısaltın."
        case .unsupportedTemplate:
          errorText = "Modelin sohbet şablonu bu yerel motor tarafından desteklenmiyor."
        default:
          errorText = "Yerel model kurulumu veya çalıştırılması başarısız."
        }
      } catch let error as AIProviderError {
        localModelStatus = error.userMessage
        errorText = error.userMessage
      } catch let error as AssistantError { errorText = error.userMessage } catch let error
        as ActionPermissionError
      {
        errorText = "Kullanıcı komutu doğrulanamadı veya işlem yetkisi geçersiz: \(error)."
      } catch { errorText = "İşlem kaydedilemedi. Lütfen yeniden deneyin." }
    }
  }
  private func proposeLearning() {
    let record = LearnedMemory(
      kind: .preference, key: learningKey, text: learningText,
      source: .userInput, confidence: 1,
      provenance: .init(
        sourceID: "kullanıcı-önerisi", explanation: "Kullanıcı tarafından yazılan tercih"))
    perform {
      guard let store else { return }
      try await store.proposeLearning(record)
      // This is already a direct owner gesture; a second confirmation is unnecessary.
      try await store.confirmLearning(id: record.id, expectedText: record.text)
      learningKey = ""
      learningText = ""
      reply = "Öğrettiğiniz bilgi kaydedildi."
    }
  }

  private func localModelDirectory() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
      .appendingPathComponent("Jarvis/models", isDirectory: true)
  }

  private func selectedModelManifest() throws -> LocalModelManifest {
    guard !activeLocalModelManifest.isEmpty,
          let bytes = activeLocalModelManifest.data(using: .utf8),
          let manifest = try? JSONDecoder().decode(LocalModelManifest.self, from: bytes)
    else { throw LocalModelError.notInstalled }
    return manifest
  }

  private func receiveModelDelta(_ delta: String, generationID: UUID, outputID: UUID?) throws {
    try Task.checkCancellation()
    guard activeGenerationID == generationID, scenePhase == .active else { throw CancellationError() }
    if !hasStreamedReply, let generationStartedAt {
      firstVisibleTokenSeconds = ProcessInfo.processInfo.systemUptime - generationStartedAt
    }
    hasStreamedReply = true
    reply += delta
    if let outputID, tts { speech.appendStreamingText(delta, responseID: outputID) }
  }

  private func abortPartialReply() {
    guard activeGenerationID != nil else { return }
    activeGenerationID = nil
    hasStreamedReply = false
    activeReply = nil
    reply = "Yanıt tamamlanmadı; konuşma geçmişine kaydedilmedi."
    speech.cancel()
  }

  private func stopVoiceConversation(cancelGeneration: Bool = true) {
    voiceCoordinator.stopConversation()
    holdStartTask?.cancel()
    holdStartTask = nil
    if cancelGeneration {
      runningOperation?.cancel()
      abortPartialReply()
    }
    speech.cancel()
  }

  private func startVoiceCapture(autoStop: Bool) {
    let previous = runningOperation
    stopVoiceConversation()
    holdStartTask = Task {
      await previous?.value
      guard !Task.isCancelled, scenePhase == .active else { return }
      await speech.begin(autoStopOnSilence: autoStop) { id in
        voiceCoordinator.beginUserCapture(id: id)
      }
    }
  }

  private func resumeListeningIfEligible() {
    guard let output = speech.naturallyFinishedOutputID, output != lastResumedOutputID,
      voiceCoordinator.canResumeListening(
        speechFinishedNaturally: true, appInForeground: scenePhase == .active,
        isBusy: busy, handsFree: handsFreeVoice, autoSend: voiceAutoSend, speakReplies: tts)
    else { return }
    lastResumedOutputID = output
    holdStartTask?.cancel()
    holdStartTask = Task {
      guard !Task.isCancelled, scenePhase == .active else { return }
      await speech.begin(autoStopOnSilence: true) { id in voiceCoordinator.beginUserCapture(id: id) }
    }
  }

  private func sharedModelManager() throws -> OnDeviceModelManager {
    if let modelManager { return modelManager }
    let manager = try OnDeviceModelManager(directory: localModelDirectory())
    modelManager = manager
    return manager
  }

  private func submit() {
    guard let store, !busy else { return }
    holdStartTask?.cancel()
    holdStartTask = nil
    speech.cancel()
    let submission = draft.submission()
    let command = submission.text
    chatFocused = false
    perform {
      if let operation = CommandRouter.ownerAction(for: command) {
        try await runOwnerAction(operation, using: store)
        draft.complete(submission)
        if errorText != nil { voiceCoordinator.stopConversation() }
        if tts { speech.speak(reply, rate: Float(speechRate)) }
        return
      }
      let provider: any AIProvider
      var scope = "local-command"
      if CommandRouter.isLocalCommand(command) {
        provider = UnavailableAIProvider()
      } else {
        let manifest = try selectedModelManifest()
        let manager = try sharedModelManager()
        let budget = LocalTurnBudget.select(
            prompt: command, fastConversation: quickMode,
            ownerMaxNewTokens: modelMaxNewTokens,
            ownerContextTokens: modelContextTokens)
        guard let contextTokens = Int32(exactly: budget.contextTokens) else {
          throw LocalModelError.invalidSettings
        }
        await inferenceRuntime.configure(
            maxNewTokens: budget.maxNewTokens,
            contextLength: contextTokens,
            ownerInstructions: ownerInstructions,
            temperature: Float(modelTemperature),
            topP: Float(modelTopP),
            cpuThreads: modelCPUThreads,
            preferFastResponse: quickMode && !budget.needsDetail)
        provider = LocalAIProvider(manager: manager, manifest: manifest,
            runtime: inferenceRuntime)
        scope = "local:" + manifest.identifier
      }
      let answerStart = ProcessInfo.processInfo.systemUptime
      generationStartedAt = answerStart
      firstVisibleTokenSeconds = nil
      localRuntimeMetrics = nil
      let generationID = UUID()
      activeGenerationID = generationID
      hasStreamedReply = false
      activeReply = nil
      reply = ""
      // Starting an output session never starts the microphone. It stays open
      // until generation completes, even if its first sentence finishes earlier.
      let outputID = tts ? speech.beginStreamingResponse(rate: Float(speechRate)) : nil
      let result = try await AssistantService(
        store: store, provider: provider, providerScope: scope,
        processingMode: .onDevice
      ).reply(
        to: command,
        consent: AISharingConsent(networkAllowed: false,
            personalMemory: true, confirmedLearning: true, recentHistory: true),
        onToken: { delta in
          try await receiveModelDelta(delta, generationID: generationID, outputID: outputID)
        })
      try Task.checkCancellation()
      guard activeGenerationID == generationID, scenePhase == .active else { throw CancellationError() }
      responseSeconds = ProcessInfo.processInfo.systemUptime - answerStart
      if result.generated != nil { localRuntimeMetrics = await inferenceRuntime.metrics }
      reply = result.text
      activeReply = result.generated
      draft.complete(submission)
      if result.generated != nil { localModelStatus = "Son yanıt cihaz içindeki modelden üretildi." }
      if result.historyWriteFailed {
        errorText = "Komut tamamlandı ancak konuşma geçmişi kaydedilemedi."
      }
      if let outputID, tts {
        if !hasStreamedReply { speech.appendStreamingText(result.text, responseID: outputID) }
        speech.finishStreamingResponse(responseID: outputID)
      }
      activeGenerationID = nil
    }
  }
}
