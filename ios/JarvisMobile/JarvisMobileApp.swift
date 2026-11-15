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
  @State private var showActionApproval = false
  @State private var runningOperation: Task<Void, Never>?
  @State private var pendingAction: ActionApprovalChallenge?
  @State private var actionRequest: ActionRequest?
  @State private var permissions = PermissionManager(authenticator: DeviceBiometricAuthenticator())
  @State private var holdStartTask: Task<Void, Never>?
  @State private var activeReply: StoredAIAnswer?
  @State private var experiences: [TaskExperience] = []
  @State private var correctionText = ""
  @AppStorage("localModelEnabled") private var localModelEnabled = true
  @State private var importingLocalModel = false
  @State private var localModelStatus = "Qwen3 modeli henüz doğrulanmadı."
  @AppStorage("aiAllowed") private var aiAllowed = false
  @AppStorage("aiSharePersonal") private var aiSharePersonal = false
  @AppStorage("aiShareLearning") private var aiShareLearning = false
  @AppStorage("aiShareHistory") private var aiShareHistory = false
  @AppStorage("relayEndpoint") private var relayEndpoint = ""
  @State private var endpointDraft = ""
  @State private var tokenDraft = ""
  @State private var connectionStatus = "Gerçek model bağlantısı henüz doğrulanmadı."
  @State private var confirmingExport = false
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
          aiSettingsTab
        }
      }
    }
    .task { await open() }
    .onChange(of: speech.transcript) { _, text in input = text }
    .onChange(of: aiAllowed) { _, allowed in
      if !allowed {
        runningOperation?.cancel()
        Task { await store?.invalidatePendingAI() }
      }
    }
    .onChange(of: tts) { _, enabled in if !enabled { speech.cancel() } }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active {
        holdStartTask?.cancel()
        holdStartTask = nil
        speech.cancel()
        if phase == .background {
          Task { await permissions.invalidateAll() }
          pendingAction = nil
          actionRequest = nil
          showActionApproval = false
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
    .confirmationDialog(
      pendingAction?.summary ?? "İşlem onayı",
      isPresented: $showActionApproval, titleVisibility: .visible
    ) {
      Button("Onayla ve biyometriyle doğrula", role: .destructive) { approveAction() }
      Button("İptal", role: .cancel) {
        if let challenge = pendingAction { Task { await permissions.deny(challenge) } }
        pendingAction = nil
        actionRequest = nil
      }
    } message: {
      Text("Bu işlem yalnızca onayınız ve başarılı cihaz biyometrisiyle yapılır.")
    }
    .confirmationDialog(
      "Dışa aktarılan JSON kişisel verilerinizi içerir ve şifreli değildir. Devam edilsin mi?",
      isPresented: $confirmingExport, titleVisibility: .visible
    ) {
      Button("JSON dışa aktar") {
        prepareAction(.exportMemory)
      }
    }
    .fileImporter(isPresented: $importingLocalModel, allowedContentTypes: [.data]) { result in
      switch result {
      case .success(let url):
        perform {
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          guard url.pathExtension.lowercased() == "gguf",
                let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
                (500_000_000...2_500_000_000).contains(bytes.int64Value)
          else { throw LocalModelError.invalidFile }
          let manifest = try localManifest(byteCount: bytes.int64Value)
          let manager = try OnDeviceModelManager(directory: localModelDirectory())
          _ = try await manager.importModel(from: url, manifest: manifest)
          localModelEnabled = true
          localModelStatus = "Qwen3 model dosyası doğrulandı ve cihaz içine kaydedildi."
        }
      case .failure:
        errorText = "Model dosyası seçilemedi."
      }
    }
    .fileExporter(
      isPresented: $exporting, document: document, contentType: .json,
      defaultFilename: "jarvis-verilerim"
    ) { result in
      if case .failure = result { errorText = "Dışa aktarma tamamlanamadı." }
      document = ExportDocument(data: Data())
    }
  }
  private var onboardingView: some View {
    VStack(spacing: 20) {
      Text("JARVIS'e hoş geldiniz").font(.largeTitle)
      Text(
        "Konuşmalar 90 gün, uygun cevap önbelleği en fazla 30 gün saklanır. Kişisel hafıza siz silene kadar kalır. Veriler cihazda şifrelenir."
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
            Text("Bu yanıt görev çalıştırmaz; işlem sonuçları ayrı onay akışında gösterilir.").font(
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
            Button("Sil", role: .destructive) { prepareAction(.deleteMemory(memory.id)) }
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
        Button("Verilerimi dışa aktar") { confirmingExport = true }
        Button("Tüm verileri sil", role: .destructive) { prepareAction(.deleteAllMemory) }
          .accessibilityIdentifier(
            "memory.deleteAll")
        Section("Öğrenme önerileri") {
          Text("Öneriler onaylamadan kullanılmaz. Parola, API anahtarı veya başka sırlar girmeyin.")
          TextField("Konu (ör. içecek tercihi)", text: $learningKey)
          TextField("Tercih önerisi", text: $learningText)
          Button("Onaya sun") { proposeLearning() }
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
                prepareAction(.deleteLearning(record.id))
              }
            }
          }
        }

      }.buttonStyle(.borderless).disabled(store == nil || busy).navigationTitle("Kişisel hafıza")
    }.tabItem { Label("Hafıza", systemImage: "brain") }
  }
  private var historyTab: some View {
    NavigationStack { List(history) { Text($0.text) }.navigationTitle("Son 90 gün") }
      .tabItem { Label("Geçmiş", systemImage: "clock") }
  }
  private var statusTab: some View {
    NavigationStack {
      List {
        Text("Yerel komutlar ve şifreli hafıza kullanılabilir.")
        Text("Türkçe ses: cihazın çevrimdışı desteğine ve izinlere bağlı.")
        Text("Konuşmacı kimlik doğrulaması: ETKİN DEĞİL.").accessibilityIdentifier(
          "status.speakerIdentity")
        Text(localModelEnabled ? "Cihaz içi AI seçili. Model yüklenmişse internet gerekmez." : "Cihaz içi AI kapalı.")
        Text(localModelStatus)
        Text(aiAllowed ? connectionStatus : "Bulut AI kapalı; yerel hafıza kullanılabilir.")
        Text("Web arama ve telefon kontrolü: bağlı değil.")
        Text("Hassas işlemler: açık onay + Face ID/Touch ID. Konuşmacı sesi yetki vermez.")
        Text("Alpha 0.3 · TestFlight yüklemesi yapılmadı.")
      }.navigationTitle("Yetenek durumu")
    }.tabItem { Label("Durum", systemImage: "info.circle") }
  }
  private var aiSettingsTab: some View {
    NavigationStack {
      Form {
        Section("Bağımsız cihaz içi yapay zekâ") {
          Toggle("Yerel modeli kullan (internetsiz)", isOn: $localModelEnabled)
          Text("Qwen3 1.7B Q4_K_M · Apache-2.0. Model dosyası yaklaşık 1,28 GB; kurulum için internete yalnızca ilk indirmede ihtiyaç vardır.")
          Link("Resmî Qwen3 GGUF model dosyasını aç",
               destination: URL(string: "https://huggingface.co/ggml-org/Qwen3-1.7B-GGUF/blob/main/Qwen3-1.7B-Q4_K_M.gguf")!)
          Button("Dosyalardan GGUF modeli yükle") { importingLocalModel = true }
          Text(localModelStatus)
          Text("Model dosyası SHA-256 ile doğrulanır. Desteklenmeyen veya değişmiş dosyalar çalıştırılmaz.")
        }
        Section("Gerçek model bağlantısı") {
          Text(
            "Sağlayıcı API anahtarı yalnızca sunucuda kalır. Buraya yöneticinizin verdiği süreli aracı servis erişim bilgisini girin."
          )
          TextField("HTTPS sunucu adresi (…/v1/chat)", text: $endpointDraft)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          SecureField("Aracı servis erişim bilgisi", text: $tokenDraft).textInputAutocapitalization(
            .never
          ).autocorrectionDisabled()
          Button("Bağlantı ayarlarını kaydet") {
            do {
              guard let endpoint = URL(string: endpointDraft) else {
                throw AIProviderError.invalidConfiguration
              }
              _ = try HTTPRelayAIProvider(endpoint: endpoint, accessToken: tokenDraft)
              try RelayCredentials.save(tokenDraft)
              relayEndpoint = endpoint.absoluteString
              tokenDraft = ""
              aiAllowed = false
              aiSharePersonal = false
              aiShareLearning = false
              aiShareHistory = false
              connectionStatus = "Ayarlar kaydedildi; gerçek model bağlantısı henüz denenmedi."
            } catch { errorText = "HTTPS adresi veya erişim bilgisi kaydedilemedi." }
          }
          Button("Erişim bilgisini kaldır", role: .destructive) {
            do {
              try RelayCredentials.delete()
              aiAllowed = false
              tokenDraft = ""
              connectionStatus = "Model bağlantısı kaldırıldı."
            } catch { errorText = "Erişim bilgisi silinemedi." }
          }
          Text(connectionStatus)
        }
        Section("Veri paylaşım onayı") {
          Text(
            "AI açıldığında yazdığınız sorular yapılandırdığınız sunucuya ve model sağlayıcısına gönderilir. Yerel kayıtlar yalnızca aşağıdaki ayrı seçimlerle paylaşılır. Herkese açık olmayan bir sunucu kullanın."
          )
          Toggle("Sorularımı bu AI sunucusuna göndermeyi kabul ediyorum", isOn: $aiAllowed)
          Toggle("Kişisel hafızamı da paylaş", isOn: $aiSharePersonal).disabled(!aiAllowed)
          Toggle("Onaylı, hassas olmayan öğrenme kayıtlarımı paylaş", isOn: $aiShareLearning)
            .disabled(!aiAllowed)
          Toggle("Son konuşmalarımı da paylaş", isOn: $aiShareHistory).disabled(!aiAllowed)
          Text(
            "Parola ve erişim anahtarları göndermeyin. Otomatik filtre bütün kişisel verileri tespit edemez. İnternet yokken yerel hafıza çalışır."
          )
        }
      }.navigationTitle("AI ayarları")
        .onAppear { endpointDraft = relayEndpoint }
    }.tabItem { Label("AI", systemImage: "sparkles") }
  }
  private func prepareAction(_ operation: ActionOperation) {
    perform {
      let request = ActionRequest(operation: operation)
      let challenge = try await permissions.prepare(request)
      actionRequest = request
      pendingAction = challenge
      showActionApproval = true
    }
  }
  private func approveAction() {
    guard let challenge = pendingAction, let request = actionRequest, let store else { return }
    pendingAction = nil
    actionRequest = nil
    perform {
      let authorization = try await permissions.approve(challenge)
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
  }
  private func open() async {
    guard store == nil else { return }
    do {
      let url = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      ).appendingPathComponent("Jarvis/memory.aes")
      store = try MemoryStore(storage: EncryptedFileStorage(url: url, keychainAccount: "primary"))
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
        case .mismatchedDigest, .mismatchedSize, .invalidFile:
          errorText = "Model dosyası doğrulanamadı. Lütfen resmî Qwen3 GGUF dosyasını seçin."
        case .notInstalled, .runtimeUnavailable:
          errorText = "Yerel model kullanılamıyor veya kurulmamış."
        default: errorText = "Model kurulumu gerçekleştirilemedi."
        }
      } catch let error as AIProviderError {
        connectionStatus = error.userMessage
        errorText = error.userMessage
      } catch let error as AssistantError { errorText = error.userMessage } catch let error
        as ActionPermissionError
      {
        switch error {
        case .biometricUnavailable: errorText = "Cihaz biyometrisi kullanılamıyor. İşlem yapılmadı."
        case .biometricRejected: errorText = "Biyometrik doğrulama tamamlanmadı. İşlem yapılmadı."
        default: errorText = "İşlem yetkisi geçersiz veya süresi dolmuş. Yeniden onaylayın."
        }
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
      try await store?.proposeLearning(record)
      learningKey = ""
      learningText = ""
    }
  }
  private static let localModelID = "qwen3-1-7b-q4km"
  private static let localModelSHA256 = "d2387ca2dbfee2ffabce7120d3770dadca0b293052bc2f0e138fdc940d9bc7b5"

  private func localModelDirectory() throws -> URL {
    try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)
      .appendingPathComponent("Jarvis/models", isDirectory: true)
  }

  private func localManifest(byteCount: Int64) throws -> LocalModelManifest {
    try LocalModelManifest(identifier: Self.localModelID, revision: "daeb8e2",
                           licenseIdentifier: "Apache-2.0", byteCount: byteCount,
                           sha256: Self.localModelSHA256)
  }

  private func submit() {
    guard let store else { return }
    let command = input
    chatFocused = false
    perform {
      let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(
        with: Locale(identifier: "tr_TR"))
      if normalized.hasPrefix("unut "), let id = UUID(uuidString: String(normalized.dropFirst(5))) {
        let request = ActionRequest(operation: .deleteMemory(id))
        let challenge = try await permissions.prepare(request)
        actionRequest = request
        pendingAction = challenge
        showActionApproval = true
        return
      }
      let provider: any AIProvider
      if !CommandRouter.isLocalCommand(command), localModelEnabled {
        let manager = try OnDeviceModelManager(directory: localModelDirectory())
        let modelFile = try localModelDirectory()
          .appendingPathComponent(Self.localModelID + ".gguf")
        let attributes = try? FileManager.default.attributesOfItem(atPath: modelFile.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 1
        provider = LocalAIProvider(
          manager: manager, manifest: try localManifest(byteCount: size),
          runtime: GGUFInferenceRuntime())
      } else if !CommandRouter.isLocalCommand(command), aiAllowed,
        let endpoint = URL(string: relayEndpoint), let credential = try RelayCredentials.load()
      {
        provider = try HTTPRelayAIProvider(endpoint: endpoint, accessToken: credential)
      } else {
        provider = UnavailableAIProvider()
      }
      let mode: AIProcessingMode = localModelEnabled ? .onDevice : .remote
      let result = try await AssistantService(
        store: store, provider: provider,
        providerScope: localModelEnabled ? "local:qwen3-1.7b-q4km" : relayEndpoint,
        processingMode: mode
      ).reply(
        to: command,
        consent: AISharingConsent(
          networkAllowed: aiAllowed,
          personalMemory: localModelEnabled || aiSharePersonal,
          confirmedLearning: localModelEnabled || aiShareLearning,
          recentHistory: localModelEnabled || aiShareHistory))
      try Task.checkCancellation()
      reply = result.text
      activeReply = result.generated
      input = ""
      if result.generated != nil {
        if localModelEnabled { localModelStatus = "Son yanıt cihaz içindeki modelden üretildi." }
        else { connectionStatus = "Son gerçek model yanıtı alındı." }
      }
      if result.historyWriteFailed {
        errorText = "Komut tamamlandı ancak konuşma geçmişi kaydedilemedi."
      }
      if tts { speech.speak(result.text) }
    }
  }
}
