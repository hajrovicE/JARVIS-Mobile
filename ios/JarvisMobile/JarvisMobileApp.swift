import SwiftUI
import UniformTypeIdentifiers
import JarvisCore

@main
struct JarvisMobileApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}
struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
@MainActor
struct RootView: View {
    @AppStorage("onboarded") private var onboarded = false
    @AppStorage("ttsEnabled") private var tts = false
    @StateObject private var speech = SpeechController()
    @State private var store: MemoryStore?
    @State private var input = ""
    @State private var reply = ""
    @State private var memories: [MemoryItem] = []
    @State private var history: [MemoryItem] = []
    @State private var errorText: String?
    @State private var exporting = false
    @State private var document = ExportDocument(data: Data())
    @State private var deleting = false
    @State private var busy = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if !onboarded {
                VStack(spacing: 20) {
                    Text("JARVIS'e hoş geldiniz").font(.largeTitle)
                    Text("Konuşmalar 90 gün, uygun cevap önbelleği en fazla 30 gün saklanır. Kişisel hafıza siz silene kadar kalır. Veriler cihazda şifrelenir.")
                    Text("Ses isteğe bağlıdır. İlk kullanımda mikrofon ve konuşma izni istenir. Yazarak da kullanabilirsiniz. Konuşmacı kimlik doğrulaması etkin değildir.")
                    Button("Başla") { onboarded = true }
                }.padding()
            } else {
                TabView {
                    NavigationStack {
                        ScrollView { VStack(alignment: .leading, spacing: 16) {
                            Text(reply).textSelection(.enabled)
                            TextField("Hatırla ki …", text: $input, axis: .vertical).textFieldStyle(.roundedBorder)
                            Button("Gönder") { submit() }.disabled(store == nil || busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Text(speech.status)
                            Text(speech.recording ? "Dinleniyor…" : "Konuşmak için basılı tutun")
                                .padding().background(.blue.opacity(0.15)).cornerRadius(12)
                                .gesture(DragGesture(minimumDistance: 0).onChanged { _ in Task { await speech.begin() } }.onEnded { _ in speech.stop(); input = speech.transcript })
                                .accessibilityAddTraits(.isButton)
                            Button(speech.recording ? "Kaydı bitir" : "Ses kaydını başlat") {
                                if speech.recording { speech.stop(); input = speech.transcript } else { Task { await speech.begin() } }
                            }
                            Toggle("Cevapları sesli oku", isOn: $tts)
                        }.padding() }.navigationTitle("JARVIS")
                    }.tabItem { Label("Sohbet", systemImage: "bubble.left") }
                    NavigationStack {
                        List {
                            ForEach(memories) { memory in
                                VStack(alignment: .leading) {
                                    TextField("Kişisel hafıza", text: Binding(get: { memories.first { $0.id == memory.id }?.text ?? "" }, set: { text in if let index = memories.firstIndex(where: { $0.id == memory.id }) { memories[index].text = text } }))
                                    Button("Değişikliği kaydet") { perform { try await store?.edit(id: memory.id, text: memories.first { $0.id == memory.id }?.text ?? "") } }
                                    Button("Sil", role: .destructive) { perform { try await store?.forget(id: memory.id) } }
                                }
                            }
                            Button("Verilerimi dışa aktar") { perform { if let data = try await store?.export() { document = ExportDocument(data: data); exporting = true } } }
                            Button("Tüm verileri sil", role: .destructive) { deleting = true }
                        }.disabled(store == nil || busy).navigationTitle("Kişisel hafıza")
                    }.tabItem { Label("Hafıza", systemImage: "brain") }
                    NavigationStack { List(history) { Text($0.text) }.navigationTitle("Son 90 gün") }
                        .tabItem { Label("Geçmiş", systemImage: "clock") }
                    NavigationStack { List {
                        Text("Yerel komutlar ve şifreli hafıza kullanılabilir.")
                        Text("Türkçe ses: cihazın çevrimdışı desteğine ve izinlere bağlı.")
                        Text("Konuşmacı kimlik doğrulaması: ETKİN DEĞİL.")
                        Text("Bulut AI, web arama ve telefon kontrolü: bağlı değil.")
                        Text("Önbellek altyapısı hazır; dış cevap sağlayıcısı henüz yok.")
                    }.navigationTitle("Yetenek durumu") }.tabItem { Label("Durum", systemImage: "info.circle") }
                }
            }
        }
        .task { await open() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { speech.stop() } else { perform { try await refresh() } } }
        .alert("İşlem tamamlanamadı", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) { Button("Tamam") { errorText = nil } } message: { Text(errorText ?? "") }
        .confirmationDialog("Tüm konuşmalar, önbellek ve kişisel hafıza silinsin mi?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Tümünü sil", role: .destructive) { perform { try await store?.deleteAll(); reply = "Tüm kayıtlar silindi." } }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "jarvis-verilerim") { result in
            if case .failure = result { errorText = "Dışa aktarma tamamlanamadı." }
            document = ExportDocument(data: Data())
        }
    }
    private func open() async {
        guard store == nil else { return }
        do {
            let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Jarvis/memory.aes")
            store = try MemoryStore(storage: EncryptedFileStorage(url: url, keychainAccount: "primary"))
            try await refresh()
        } catch { errorText = "Şifreli hafıza açılamadı. Cihazın kilidini açıp uygulamayı yeniden başlatın." }
    }
    private func refresh() async throws {
        if let state = try await store?.read() { memories = state.personal; history = state.conversations }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task { defer { busy = false }; do { try await operation(); try await refresh() } catch { errorText = "İşlem kaydedilemedi. Lütfen yeniden deneyin." } }
    }
    private func submit() {
        guard let store else { return }; let command = input
        perform {
            let answer = try await CommandRouter(store: store).execute(command)
            reply = answer; input = ""
            // A command can succeed even if the separate conversation write fails.
            do { try await store.record("Siz: \(command)\nJARVIS: \(answer)") }
            catch { errorText = "Komut tamamlandı ancak konuşma geçmişi kaydedilemedi." }
            if tts { speech.speak(answer) }
        }
    }
}
