# JARVIS Mobile
Türkçe, iPhone öncelikli SwiftUI asistanı. İlk işlevsel dilim: şifreli yerel hafıza, 90 günlük konuşmalar, en fazla 30 günlük uygun cevap önbelleği, kalıcı kişisel hafıza, yerel komutlar ve isteğe bağlı cihaz içi Türkçe sesli giriş/TTS.

## Çalıştırma
Swift 5.9+ ile `swift test`. iOS uygulaması için macOS, Xcode 16+ ve XcodeGen gerekir:

```sh
brew install xcodegen
cd ios
xcodegen generate
open JarvisMobile.xcodeproj
```

Xcode'da imzalama takımını seçip iPhone'da çalıştırın. Speech desteği cihaza bağlıdır. Üretilen proje/Info.plist kaynak denetimine alınmaz; yapılandırma `ios/project.yml` içindedir. `.github/workflows/swift.yml` macOS üzerinde test ve simulator derlemesi yapar.

## Komutlar
`hatırla ki kahveyi severim`, `ne hatırlıyorsun`, `unut <UUID>`, `geçmiş`. Hafıza sekmesinden kayıtları düzenleyebilir, silebilir ve verileri JSON olarak dışa aktarabilirsiniz. Dışa aktarılan JSON kişisel veri içerir ve şifreli değildir.

Konuşmacı doğrulaması, bulut AI, web kaynakları ve telefon kontrolü etkin değildir. Önbellek altyapısı API düzeyindedir; harici cevap sağlayıcısı henüz bağlı değildir. Süresi dolan veriler erişimde/açılışta temizlenir; uygulama kapalıyken kesin zamanlı arka plan silme garantisi yoktur.

Ayrıntılar: [mimari](docs/ARCHITECTURE.md), [gereksinimler](docs/PRD.md), [yol haritası](docs/ROADMAP.md), [test planı](docs/TEST_PLAN.md), [konuşmacı güvenliği](docs/SPEAKER_SECURITY.md), [doğrulama raporu](docs/VALIDATION.md).
