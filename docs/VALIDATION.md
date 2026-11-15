# İkinci aşama doğrulama — 15 Kasım 2026

## Kapsam
GitHub görevi #1 incelendi. Bu iterasyon kararlı yerel MVP ve öğrenme motorunun temel şema/onay/kalıcılık akışını kapsar. Görev #1 açık kalır: gerçek araç yürütücüsü, beceri imzalama/kataloğu, web kaynak sağlayıcısı, otomatik öneriler ve konuşmacı güvenliği tamamlanmış değildir.

## Doğrulanan yerel kontroller
Swift 6.0.3/Linux: 19 XCTest, 0 hata. Tam 90/30 gün sınırları, zaman duyarlı önbellek dışlama, kalıcı hafıza, yazma hatasında geri alma, yeniden açma/export/silme, v1→v2 geçişi, onay bekleyen öğrenme kayıtları, çelişki/düzeltme/arama, eski taslak onayı reddi ve geçmiş sorgusunun içeriği yeniden kaydetmemesi test edildi. Apple testleri bu sayıya dahil değildir.

## CI kaydı
Son kaynak revizyonu: `b42a4b68544f548480c14da65b4b48c15b893d69`.
Koşu: https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/43676038209

**Sonuç: başarı.** macOS-15, Xcode 16.4 (16F6), Swift 6.1.2; iPhone 16 Pro simulator, iOS 18.5.

| Kontrol | Sonuç |
| --- | --- |
| Swift 6 macOS testleri | 25 başarılı, 0 hata |
| Simulator uygulama derlemesi | BUILD SUCCEEDED; ad-hoc imzalı host |
| iPhone SDK derlemesi | BUILD SUCCEEDED; imzasız cihaz hedefi |
| iOS hosted birim/entegrasyon testleri | 26 başarılı, 1 açıklamalı donanım testi atlandı, 0 hata |
| iOS arayüz kabul testi | 1 başarılı, 0 hata; 59.566 saniye |
| Toplam iOS | 27 başarılı, 1 atlanan, 0 hata |
| Kaynak biçim kontrolü | git diff --check başarılı |

Xcode test sonucu `TEST SUCCEEDED`. Keychain erişim sınıfı/senkronizasyonu, AES-GCM nonce ve kurcalama, eksik/bozuk anahtar, şifreli kişisel/öğrenme hafızasını yeniden açma ve silme testleri simulator üzerinde geçti. Onboarding, yazılı komutla kaydetme, uygulamayı sonlandırıp tekrar okuyabilme, silme sonrası tekrar açmada kaydın bulunmaması ve konuşmacı doğrulamasının etkin değil gösterilmesi arayüzde doğrulandı. İzin politikası ve uygulamanın gerçek Türkçe Info.plist açıklamaları test edildi.

**Atlanan test:** `testIOSFileProtectionSurvivesReplacement`. Simulator, host Mac dosya sisteminde NSFileProtectionKey alanını döndürmez. Test fiziksel iOS hedefinde kesin `.complete` kontrolünü korur; bu donanım koruması ve kilitli cihaz davranışı henüz doğrulanmış sayılmaz. Hiçbir Keychain veya şifreli kalıcılık testi atlanmadı.

[Uygulama ve test artifact'ı](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/43676038209/artifacts/14146721895):
- `JarvisMobile-simulator.zip`: simulator için uygulama.
- `JarvisMobile-iphone-unsigned.zip`: iPhone SDK ile derlenmiş, imzasız uygulama.
- `TestResults.xcresult`: test sonuçları ve yalnızca sentetik test verisi içeren kalıcı screenshot ekleri; Xcode ile açılır.
- Swift, simulator, iPhone ve iOS test logları.

Artifact GitHub politikasıyla 14 gün saklanır. Bu rapor commit'i yalnızca belgelerdir; doğrulanan uygulama/test/workflow kaynağı yukarıdaki tam SHA'dır.

## Bulunan ve düzeltilen sorunlar
- Swift 6 XCTest keşfinde Sendable gereksinimi ve senkron test fonksiyonu cast sorunu; izole, paylaşılan değişken durumu olmayan test sınıfları ve async test girişleriyle düzeltildi.
- macOS login Keychain iOS erişim sınıfını döndürmüyor. Kesin `WhenUnlockedThisDeviceOnly` kontrolü iOS testinde korundu; macOS'ta diğer şifreleme/Keychain kontrolleri sürer.
- `CODE_SIGNING_ALLOWED=NO` ile simulator uygulamasının Keychain çağrıları `-34018` verdi; yalnızca derlenmiş olması çalıştığını kanıtlamadı. Simulator host için ad-hoc imza ve açık simulator uygulama kimliği eklendi. Cihaz hedefi bu simulator entitlement dosyasını kullanmaz; gerçek cihaz yetkileri provisioning profile'dan gelir.
- Şifreli dosya değişiminden sonraki metadata hatası yanlış başarısızlık bildirebiliyordu; metadata yeni geçici dosyada hazırlanıp atomik değişim son işlem yapıldı.
- Simulatorun fiziksel Data Protection alanı için açıklamalı atlama eklendi; gerçek cihaz testi zorunlu kaldı.
- Hafıza satırlarında birden çok SwiftUI List düğmesi için bağımsız button style eklendi.
- Düzenlenmiş önerinin eski metnini onaylama, beklenen metin kontrolüyle engellendi.
- `geçmiş` cevabının yeniden kaydedilmesi içeriği çoğaltıp TTL'yi uzatıyordu; listelemeler yeniden kaydedilmez. Hafıza komutları yalnızca içeriksiz işlem işareti bırakır.

## Fiziksel iPhone için kalan kabul
Gerçek cihazda canlı Türkçe ses transkripsiyonu, izin kabul/ret/kısıt, desteklenmeyen cihaz, arka plan/kesinti, kilitli cihazın dosya/Keychain koruması, VoiceOver, dışa aktarma ve imzalı kurulum manuel doğrulanmalıdır. İzin politikası/Info.plist testleri gerçek mikrofon sesi testi değildir. Simulator testleri fiziksel cihazın donanım korumasını kanıtlamaz.

Simulator `.app` ve imzasız iPhone SDK `.app` dosyaları TestFlight/IPA dağıtımı değildir. Gerçek cihaza kurulum için Xcode'da geliştirici takımı seçilip imzalanmalıdır.
