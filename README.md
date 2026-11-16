# JARVIS Mobile
Türkçe, iPhone öncelikli SwiftUI asistanı. Güncel sahip tercihi: cihaz içinde GGUF/llama.cpp sohbeti, kullanıcı silene kadar JSON hafıza ve konuşma geçmişi, yerel komutlar ve isteğe bağlı cihaz içi Türkçe sesli giriş/TTS. Önbelleğin 30 günlük tazelik sınırı arşiv kayıtlarını silmez. [Güncel kapsamlı doğrulama ve sınırlar](docs/VALIDATION.md).

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

Sahibin doğrudan öğrettiği bilgi kaydedilir; model metni kendi başına öğrenmeyi onaylayamaz. Kullanıcı düzeltmesi çelişkili eski kayda üstün gelir. [Learning Engine temeli ve kapsamı](docs/LEARNING_ENGINE.md).

iPhone sohbeti `LocalAIProvider` üzerinden gerçek yerel çıkarım motorunu kullanır; harici AI API anahtarı veya ağ geri dönüşü yoktur. Model kurulmadığında veya çalışmadığında açık hata gösterilir. Önceki sunucu/relay modülleri ayrı tutulur; mobil sohbet yoluna bağlı değildir.

Sahibin güncel doğrudan komutu desteklenen işlemi başlatır. Uygulama ek biyometri, yetki süresi veya SHA-256 sabitlemesi istemez; model metni, geçmiş ve dış içerik işlem yetkisi vermez. iOS mikrofon/Speech izinleri korunur. JSON ayrıca uygulama tarafından şifrelenmez; eski AES hafıza doğrulanarak bir defa taşınır. Gerçek konuşmacı tanıma, web arama, telefon kontrolü ve imzalı beceri yükleme etkin değildir.

Yalnızca iPhone sahibi kullanıcı için: GitHub Actions → **iOS Release preparation** → `build-only`. Bu işlem imzasız Release paketi üretir; iPhone'a kurulamaz. Ücretli üyelik/Secrets olmadan TestFlight yüklemesi denenmez. [Manuel hesap ve dağıtım hazırlığı](docs/IPHONE_DISTRIBUTION.md).

Ayrıntılar: [mimari](docs/ARCHITECTURE.md), [gereksinimler](docs/PRD.md), [yol haritası](docs/ROADMAP.md), [test planı](docs/TEST_PLAN.md), [konuşmacı güvenliği](docs/SPEAKER_SECURITY.md), [doğrulama raporu](docs/VALIDATION.md).

## Cihaz içinde JARVIS modeli
JARVIS'in iPhone sohbeti artık harici API yerine yerel GGUF çıkarımını hedefler. Başlangıç ağırlıklarını kullanabilir veya llama.cpp tarafından desteklenen sohbet şablonuna sahip GGUF dosyasını seçebilirsiniz. Kurulum, sınırlamalar ve eğitim süreci: [docs/JARVIS_OWN_MODEL.md](docs/JARVIS_OWN_MODEL.md). Model kurulmadığında uygulama sahte cevap üretmez.
