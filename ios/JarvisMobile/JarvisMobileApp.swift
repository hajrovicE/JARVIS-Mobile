import JarvisCore
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
  @State private var store: MemoryStore?
  @State private var input = ""
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
    .onChange(of: speech.transcript) { _, text in input = text }
    .onChange(of: tts) { _, enabled in if !enabled { speech.cancel() } }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active {
        // A submitted owner's inference request may not run unattended.
        runningOperation?.cancel()
        holdStartTask?.cancel()
        holdStartTask = nil
        speech.cancel()
        if phase == .background {
          Task { await permissions.invalidateAll() }
        }
      } else {
        Task { if store == nil { await open() } else { perform { try await refresh() } } }
      }
    }
    .onDisappear {
      holdStartTask?.cancel()
      speech.cancel()
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
          let manager = try OnDeviceModelManager(directory: localModelDirectory())
          _ = try await manager.importModel(from: url, manifest: manifest)
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
          TextField("Hatırla ki …", text: $input, axis: .vertical).textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("chat.input").focused($chatFocused)
          Button("Gönder") { submit() }.accessibilityIdentifier("chat.send").disabled(
            store == nil || busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Text("Sesli giriş isteğe bağlıdır. Tanıma cihazda yapılır; yazarak devam edebilirsiniz.")
          Button("Ses izinlerini ver") { Task { await speech.requestPermissions() } }
            .disabled(speech.requestingPermissions || speech.recording || speech.finishing)
          if speech.needsSettings, let settings = URL(string: UIApplication.openSettingsURLString) {
            Link("Ses izinleri için Ayarlar'ı aç", destination: settings)
          }
          Text(speech.status)
          Text(speech.recording ? "Dinleniyor…" : "Konuşmak için basılı tutun")
            .padding().background(.blue.opacity(0.15)).cornerRadius(12)
            .gesture(
              DragGesture(minimumDistance: 0).onChanged { _ in
                if holdStartTask == nil { holdStartTask = Task { await speech.begin() } }
              }
              .onEnded { _ in
                holdStartTask?.cancel()
                holdStartTask = nil
                speech.stop()
                input = speech.transcript
              }
            )
            .accessibilityAddTraits(.isButton)
          Button(speech.recording ? "Kaydı bitir" : "Ses kaydını başlat") {
            if speech.recording {
              holdStartTask?.cancel()
              holdStartTask = nil
              speech.stop()
              input = speech.transcript
            } else {
              holdStartTask = Task { await speech.begin() }
            }
          }
          .disabled(speech.requestingPermissions || speech.finishing)
          Toggle("Cevapları sesli oku", isOn: $tts)
          if speech.speaking { Button("Sesli cevabı durdur") { speech.cancel() } }
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
      let plainStorage = try PlainFileStorage(url: jsonURL)
      // Legacy encrypted snapshots are read at most once when upgrading.
      // Future writes use only the owner's plaintext JSON file.
      let legacyURL = directory.appendingPathComponent("memory.aes")
      if !FileManager.default.fileExists(atPath: jsonURL.path),
         FileManager.default.fileExists(atPath: legacyURL.path) {
        let legacyStorage = try EncryptedFileStorage(
          url: legacyURL, keychainAccount: "primary")
        if let old = try legacyStorage.load() {
          try plainStorage.save(old)
        }
      }
      store = try MemoryStore(storage: plainStorage)
      if let manifest = try? selectedModelManifest(),
         let modelURL = try? localModelDirectory().appendingPathComponent(manifest.identifier + ".gguf"),
         FileManager.default.fileExists(atPath: modelURL.path) {
        localModelStatus = "Kurulu model: " + manifest.identifier + ". İlk sorguda SHA-256 doğrulanacak."
      } else {
        localModelStatus = "Yerel model kurulmadı. GGUF dosyasını Dosyalar'dan yükleyin."
      }
      try await refresh()
    } catch {
      errorText = "Şifreli hafıza açılamadı. Cihazın kilidini açıp uygulamayı yeniden başlatın."
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
        busy = false
        runningOperation = nil
      }
      do {
        try await operation()
        try await refresh()
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
        default:
          errorText = "Yerel model kurulumu veya çalıştırılması başarısız."
        }
      } catch let error as AIProviderError {
        connectionStatus = error.userMessage
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

  private func submit() {
    guard let store else { return }
    let command = input
    chatFocused = false
    perform {
      if let operation = CommandRouter.ownerAction(for: command) {
        try await runOwnerAction(operation, using: store)
        input = ""
        return
      }
      let provider: any AIProvider
      var scope = "local-command"
      if CommandRouter.isLocalCommand(command) {
        provider = UnavailableAIProvider()
      } else {
        let manifest = try selectedModelManifest()
        let manager = try OnDeviceModelManager(directory: localModelDirectory())
        provider = LocalAIProvider(manager: manager, manifest: manifest,
            runtime: GGUFInferenceRuntime(
                maxNewTokens: modelMaxNewTokens,
                contextLength: Int32(clamping: modelContextTokens),
                ownerInstructions: ownerInstructions,
                temperature: Float(modelTemperature),
                topP: Float(modelTopP),
                cpuThreads: modelCPUThreads))
        scope = "local:" + manifest.identifier
      }
      let result = try await AssistantService(
        store: store, provider: provider, providerScope: scope,
        processingMode: .onDevice
      ).reply(
        to: command,
        consent: AISharingConsent(networkAllowed: false,
            personalMemory: true, confirmedLearning: true, recentHistory: true))
      try Task.checkCancellation()
      reply = result.text
      activeReply = result.generated
      input = ""
      if result.generated != nil { localModelStatus = "Son yanıt cihaz içindeki modelden üretildi." }
      if result.historyWriteFailed {
        errorText = "Komut tamamlandı ancak konuşma geçmişi kaydedilemedi."
      }
      if tts { speech.speak(result.text) }
    }
  }
}
