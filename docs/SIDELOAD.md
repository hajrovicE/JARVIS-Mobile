# JARVIS'i App Store'a yüklemeden iPhone'a kurma

Bu yol **App Store, TestFlight, App Review veya ücretli Apple Developer üyeliği gerektirmez**. Uygulama Apple'a gönderilmez. iOS yine de her uygulamanın imzalı olmasını ister; imzayı kendi (ücretsiz) Apple ID'nizle, kendi cihazınız için siz atarsınız. Bu, Apple'ın kişisel geliştirme için sunduğu normal "ücretsiz imzalama" yoludur; bir iOS kısıtını aşmaz.

## 1. İmzasız IPA'yı üretin
GitHub → **Actions → iPhone sideload IPA → Run workflow** (iş akışı `main`'e birleştirildikten sonra bu düğme görünür; `claude/**` dallarına yapılan uygulama değişiklikleri ve `v*` etiketleri derlemeyi kendiliğinden başlatır). İş bitince:
- **Releases** altında `sideload-<numara>` ön sürümünde `JARVIS-unsigned.ipa` bulunur (iPhone Safari'den de indirilebilir), ayrıca
- koşunun **Artifacts** bölümünde aynı dosya ve derleme logu durur.

> Actions koşuları saniyeler içinde "recent account payments have failed or your spending limit needs to be increased" notuyla başarısız oluyorsa GitHub hesabının Actions kotası/ödemesi engellidir; derleme hiç başlamaz. GitHub → Settings → Billing & plans altında düzeltin, aylık kotanın yenilenmesini bekleyin veya depoyu herkese açık yapın (herkese açık depolarda standart runner'lar ücretsizdir). macOS dakikaları özel depolarda 10 kat sayılır; bu yüzden tam iOS doğrulaması artık yalnızca `main`, PR ve elle başlatılan koşularda çalışır.

## 2. Kendi Apple ID'nizle kurun
Aşağıdakilerden biri yeterlidir. Hepsi IPA'yı sizin Apple ID'nizle yeniden imzalar.

| Araç | Gereken | Not |
| --- | --- | --- |
| **Sideloadly** | Windows veya Mac + kablo | En basit ilk kurulum. IPA'yı sürükleyin, Apple ID girin, Start. |
| **AltStore (Classic)** | Windows veya Mac'te AltServer | Bilgisayar aynı Wi‑Fi'deyken imzayı kendiliğinden yeniler. |
| **SideStore** | İlk kurulum için bir kez bilgisayar | Sonrasında yenileme telefondan, bilgisayarsız yapılır. |
| **Xcode** | Mac | `cd ios && xcodegen generate`, takım olarak kişisel Apple ID'nizi seçip iPhone'da çalıştırın. |

Kurulumdan sonra iPhone'da:
1. **Ayarlar → Gizlilik ve Güvenlik → Geliştirici Modu**'nu açın (iOS 16+; telefon yeniden başlar).
2. **Ayarlar → Genel → VPN ve Cihaz Yönetimi** altında kendi Apple ID'nize güvenin.

## Ücretsiz Apple ID'nin sınırları (dürüst liste)
- İmza **7 gün** geçerlidir; süre dolunca uygulama açılmaz. Aynı araçla "refresh/yenile" yapınca verileriniz ve yüklü model **silinmeden** devam eder. Silip yeniden kurarsanız hafıza ve model de silinir.
- Aynı anda en fazla 3 sideload uygulaması ve haftada sınırlı sayıda yeni uygulama kimliği.
- İlk kurulum için **bir kez bilgisayar gerekir**. Hiç bilgisayar kullanmadan, ücretsiz ve Apple'ın izin verdiği bir kurulum yolu yoktur.
- Ücretli Apple Developer üyeliği (yıllık) imza süresini 1 yıla çıkarır; yine App Store'a yükleme veya inceleme gerekmez.
- Bu araçlar üçüncü taraftır; Apple ID parolanızı onlara girersiniz. İsterseniz yalnızca bu iş için ayrı bir Apple ID kullanın.

## 3. Modeli yükleyin
1. Uygulamada **AI** sekmesi → **GGUF başlangıç modelini indir**; Safari'de `Qwen3-1.7B-Q4_K_M.gguf` (~1,28 GB) dosyasını **Dosyalar**'a indirin. Kendi eğittiğiniz Qwen3‑uyumlu GGUF'u da kullanabilirsiniz.
2. **Kendi GGUF modelimi dosyadan seç** ile dosyayı seçin. Dosya uygulamanın özel klasörüne kopyalanır; önceki model silinir. Kopyadan sonra Dosyalar'daki indirilen kopyayı silebilirsiniz.
3. **Sohbet** sekmesinde yazın. İlk yanıtta model belleğe yüklenir; sonraki yanıtlar bunu beklemez.

Bellek: 1,7B Q4 model + 4096 token bağlam kabaca 2 GB çalışma belleği ister. 4 GB RAM'li eski iPhone'larda iOS uygulamayı kapatabilir; AI sekmesinden bağlam penceresini küçültün veya daha küçük bir GGUF seçin.

## Neler doğrulandı, neler doğrulanmadı
- Doğrulandı (Linux, Swift 6.0): `swift test` — JarvisCore testlerinin tamamı; `GGUFInferenceRuntime.swift` dosyası llama.cpp `b10549` başlığına (`llama.swift 2.10549.0`'ın sarmaladığı sürüm) karşı Swift 6 modunda derlendi. `JarvisMobileApp.swift`, SwiftUI yerine konan sahte bir arayüz katmanına karşı Swift 6 modunda tip denetiminden geçti: bu, uygulama mantığını ve çekirdek API kullanımını doğrular, gerçek SwiftUI API uyumunu doğrulamaz. Python testleri (sunucu, sürüm politikası, model betikleri) geçti.
- **Doğrulanmadı:** Xcode/iOS derlemesi, SwiftUI arayüzü, IPA paketleme iş akışı ve gerçek iPhone'da çıkarım hızı/bellek davranışı. GitHub Actions hesabı ödeme/kota nedeniyle koşu başlatmadığı için bu adımlar çalıştırılamadı. Kota açıldığında ilk koşunun sonucuna göre düzeltme gerekebilir.
