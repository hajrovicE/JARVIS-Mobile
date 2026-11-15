# JARVIS Mobile
Türkçe, iPhone öncelikli SwiftUI asistanı. Kullanıcı silene kadar korunan şifreli yerel geçmiş ve öğrenme kayıtları, kaynak geçerliliğine göre yeniden kullanım, yerel komutlar ve isteğe bağlı cihaz içi Türkçe sesli giriş/TTS içerir.

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

Yapılandırılmış aracı servis, kullanıcı bağlantıyı kaydettikten sonra kullanıcı komutları için etkinleşir. Sağlayıcı anahtarı yalnızca sunucudadır; erişim bilgileri Keychain'de tutulur. Silme ve dışa aktarma için kullanıcı komutu tek başına yeterlidir; model çıktısı hiçbir işlemi başlatamaz. Gerçek konuşmacı tanıma, web arama, genel iOS sistem kontrolü ve yeni beceri yükleme henüz uygulanmamıştır.

Yalnızca iPhone sahibi kullanıcı için: GitHub Actions → **iOS Release preparation** → `build-only`. Bu işlem imzasız Release paketi üretir; iPhone'a kurulamaz. Ücretli üyelik/Secrets olmadan TestFlight yüklemesi denenmez. [Manuel hesap ve dağıtım hazırlığı](docs/IPHONE_DISTRIBUTION.md).

Ayrıntılar: [mimari](docs/ARCHITECTURE.md), [gereksinimler](docs/PRD.md), [yol haritası](docs/ROADMAP.md), [test planı](docs/TEST_PLAN.md), [konuşmacı güvenliği](docs/SPEAKER_SECURITY.md), [doğrulama raporu](docs/VALIDATION.md).
