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
  @State private var deleting = false
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
        }
      }
    }
    .task { await open() }
    .onChange(of: speech.transcript) { _, text in input = text }
    .onChange(of: tts) { _, enabled in if !enabled { speech.cancel() } }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active {
        speech.cancel()
      } else {
        Task { if store == nil { await open() } else { perform { try await refresh() } } }
      }
    }
    .onDisappear { speech.cancel() }
    .alert(
      "İşlem tamamlanamadı",
      isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    ) {
      Button("Tamam") { errorText = nil }
    } message: {
      Text(errorText ?? "")
    }
    .confirmationDialog(
      "Tüm konuşmalar, önbellek, kişisel hafıza ve öğrenme kayıtları silinsin mi?",
      isPresented: $deleting, titleVisibility: .visible
    ) {
      Button("Tümünü sil", role: .destructive) {
        perform {
          try await store?.deleteAll()
          reply = "Tüm kayıtlar silindi."
        }
      }.accessibilityIdentifier("memory.confirmDeleteAll")
    }
    .confirmationDialog(
      "Dışa aktarılan JSON kişisel verilerinizi içerir ve şifreli değildir. Devam edilsin mi?",
      isPresented: $confirmingExport, titleVisibility: .visible
    ) {
      Button("JSON dışa aktar") {
        perform {
          if let data = try await store?.export() {
            document = ExportDocument(data: data)
            exporting = true
          }
        }
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
              DragGesture(minimumDistance: 0).onChanged { _ in Task { await speech.begin() } }
                .onEnded { _ in
                  speech.stop()
                  input = speech.transcript
                }
            )
            .accessibilityAddTraits(.isButton)
          Button(speech.recording ? "Kaydı bitir" : "Ses kaydını başlat") {
            if speech.recording {
              speech.stop()
              input = speech.transcript
            } else {
              Task { await speech.begin() }
            }
          }
          .disabled(speech.requestingPermissions || speech.finishing)
          Toggle("Cevapları sesli oku", isOn: $tts)
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
            Button("Sil", role: .destructive) { perform { try await store?.forget(id: memory.id) } }
              .accessibilityIdentifier("memory.delete.\(memory.id)")
          }
        }
        Button("Verilerimi dışa aktar") { confirmingExport = true }
        Button("Tüm verileri sil", role: .destructive) { deleting = true }.accessibilityIdentifier(
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
                perform { try await store?.deleteLearning(id: record.id) }
              }
            }
          }
        }

      }.disabled(store == nil || busy).navigationTitle("Kişisel hafıza")
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
        Text("Bulut AI, web arama ve telefon kontrolü: bağlı değil.")
        Text("Önbellek altyapısı hazır; dış cevap sağlayıcısı henüz yok.")
      }.navigationTitle("Yetenek durumu")
    }.tabItem { Label("Durum", systemImage: "info.circle") }
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
      history = state.conversations
      learningRecords = state.learning.records
    }
  }
  private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
    guard !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        try await operation()
        try await refresh()
      } catch LearningError.staleProposal {
        errorText =
          "Öneri metni değişti. Düzenlediğiniz metni kaydetmek için Düzelt ve onayla seçeneğini kullanın."
      } catch LearningError.conflictingRecord {
        errorText =
          "Aynı konuda farklı bir bilgi var. Tercihinizi değiştirmek için Düzelt ve onayla seçeneğini kullanın."
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
      let result = try await CommandRouter(store: store).executeWithHistory(command)
      reply = result.reply
      input = ""
      if result.historyWriteFailed {
        errorText = "Komut tamamlandı ancak konuşma geçmişi kaydedilemedi."
      }
      if tts { speech.speak(result.reply) }
    }
  }
}
