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
  @AppStorage("aiAllowed") private var aiAllowed = false
  @AppStorage("aiSharePersonal") private var aiSharePersonal = false
  @AppStorage("aiShareLearning") private var aiShareLearning = false
  @AppStorage("aiShareHistory") private var aiShareHistory = false
  @AppStorage("relayEndpoint") private var relayEndpoint = ""
  @State private var endpointDraft = ""
  @State private var tokenDraft = ""
  @State private var connectionStatus = "Gerçek model bağlantısı henüz doğrulanmadı."
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
  }
  private var onboardingView: some View {
    VStack(spacing: 20) {
      Text("JARVIS'e hoş geldiniz").font(.largeTitle)
      Text(
        "Konuşma geçmişi ve öğrenilen bilgiler siz silene kadar korunur. Güncelliği doğrulanmamış cevaplar otomatik güncel sayılmaz. Veriler cihazda şifrelenir."
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
        Text("Yerel komutlar ve şifreli hafıza kullanılabilir.")
        Text("Türkçe ses: cihazın çevrimdışı desteğine ve izinlere bağlı.")
        Text("Konuşmacı kimlik doğrulaması: ETKİN DEĞİL.").accessibilityIdentifier(
          "status.speakerIdentity")
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
          Toggle("Öğrenme kayıtlarımı bu AI sunucusuyla paylaş", isOn: $aiShareLearning)
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
      try await store?.proposeLearning(record)
      learningKey = ""
      learningText = ""
    }
  }
  private func submit() {
    guard let store else { return }
    let command = input
    chatFocused = false
    perform {
      let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(
        with: Locale(identifier: "tr_TR"))
      if let operation = CommandRouter.ownerAction(for: command) {
        try await runOwnerAction(operation, using: store)
        input = ""
        return
      }
      let provider: any AIProvider
      if !CommandRouter.isLocalCommand(command), aiAllowed,
        let endpoint = URL(string: relayEndpoint), let credential = try RelayCredentials.load()
      {
        provider = try HTTPRelayAIProvider(endpoint: endpoint, accessToken: credential)
      } else {
        provider = UnavailableAIProvider()
      }
      let result = try await AssistantService(
        store: store, provider: provider, providerScope: relayEndpoint
      ).reply(
        to: command,
        consent: AISharingConsent(
          networkAllowed: aiAllowed, personalMemory: aiSharePersonal,
          confirmedLearning: aiShareLearning, recentHistory: aiShareHistory))
      try Task.checkCancellation()
      reply = result.text
      activeReply = result.generated
      input = ""
      if result.generated != nil { connectionStatus = "Son gerçek model yanıtı alındı." }
      if result.historyWriteFailed {
        errorText = "Komut tamamlandı ancak konuşma geçmişi kaydedilemedi."
      }
      if tts { speech.speak(result.text) }
    }
  }
}
