# JARVIS Mobile
Türkçe, iPhone öncelikli SwiftUI asistanı. İlk işlevsel dilim: şifreli yerel hafıza, 90 günlük konuşmalar, en fazla 30 günlük uygun cevap önbelleği, kalıcı kişisel hafıza, yerel komutlar ve isteğe bağlı cihaz içi Türkçe sesli giriş/TTS.

## Çalıştırma
Swift 6.0+ ile `swift test`. iOS uygulaması için macOS, Xcode 16.4+ ve XcodeGen gerekir:

```sh
brew install xcodegen
cd ios
xcodegen generate
open JarvisMobile.xcodeproj
```

Xcode'da imzalama takımını seçip iPhone'da çalıştırın. Speech desteği cihaza bağlıdır. Üretilen proje/Info.plist kaynak denetimine alınmaz; yapılandırma `ios/project.yml` içindedir. `.github/workflows/swift.yml` macOS üzerinde Swift 6 testleri, simulator ve imzasız iPhone SDK derlemesi, iOS Keychain/şifreleme testleri ve uygulama arayüz testini çalıştırır. Sonuç logları, xcresult ve simulator uygulaması ve imzasız cihaz uygulaması Actions artifact olarak saklanır. Bunlar imzalı IPA/TestFlight dağıtımı değildir; gerçek iPhone kurulumu için Xcode ile geliştirici takımınızın imzası gerekir.

## Komutlar
`hatırla ki kahveyi severim` (veya `bunu hatırla …`), `ne hatırlıyorsun`, `unut <UUID>`, `geçmiş`, `öğrendiklerin`. Hafıza sekmesinden kayıtları düzenleyebilir, silebilir ve verileri JSON olarak dışa aktarabilirsiniz. Dışa aktarılan JSON kişisel veri içerir ve şifreli değildir.

Hafıza sekmesindeki öğrenme önerileri ayrı onay bekler; kullanıcı düzeltmesi çelişkili eski kayda üstün gelir. [Learning Engine temeli ve kapsamı](docs/LEARNING_ENGINE.md).

Alpha 0.3, modüler AIProvider + gerçek OpenAI API aracı servis kodu, açık paylaşım onayı, kaynak/zaman metadata'sı, öğrenme revizyonları ve güvenli yerel ActionExecutor içerir. **Canlı model bağlantısı bu geliştirmede kurulmadı**; yapılandırma yoksa sahte cevap yerine açık hata gösterilir. [Alpha 0.3 kapsamı](docs/ALPHA_0_3.md), [AI sunucusu kurulumu](docs/AI_RELAY_SERVER.md).

AI varsayılan kapalı; sağlayıcı API anahtarı yalnızca sunucuda, aracı servis erişim bilgisi Keychain'dedir. Yerel hafıza internet olmadan çalışır. Silme ve dışa aktarma kullanıcı onayı + cihaz biyometrisi ister; cihaz biyometrisi kullanılamıyorsa işlem reddedilir. Gerçek konuşmacı tanıma, web arama, telefon kontrolü ve imzalı beceri yükleme etkin değildir.

Yalnızca iPhone sahibi kullanıcı için: GitHub Actions → **iOS Release preparation** → `build-only`. Bu işlem imzasız Release paketi üretir; iPhone'a kurulamaz. Ücretli üyelik/Secrets olmadan TestFlight yüklemesi denenmez. [Manuel hesap ve dağıtım hazırlığı](docs/IPHONE_DISTRIBUTION.md).

Ayrıntılar: [mimari](docs/ARCHITECTURE.md), [gereksinimler](docs/PRD.md), [yol haritası](docs/ROADMAP.md), [test planı](docs/TEST_PLAN.md), [konuşmacı güvenliği](docs/SPEAKER_SECURITY.md), [doğrulama raporu](docs/VALIDATION.md).

## Cihaz içinde JARVIS modeli
JARVIS'in iPhone sohbeti artık harici API yerine yerel GGUF çıkarımını hedefler. Başlangıç ağırlıklarını kullanabilir veya sahibinin eğittiği Qwen3-uyumlu GGUF dosyasını seçebilirsiniz. Kurulum, sınırlamalar ve eğitim süreci: [docs/JARVIS_OWN_MODEL.md](docs/JARVIS_OWN_MODEL.md). Model kurulmadığında uygulama sahte cevap üretmez.
