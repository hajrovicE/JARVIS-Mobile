# Doğrulama
`swift test`: tam 90/30 gün ve bir saniye önceki sınırlar, kalıcı hafıza, zaman duyarlı önbellek dışlama, yeniden açma, düzenleme, tekli ve toplu silme, dışa aktarma, başarısız yazma, sürüm geçişi ve güvenli komut yönlendirme. Apple platformlarında ek AES-GCM yeniden açma ve değiştirilmiş şifreli dosyayı reddetme testi.

macOS: `brew install xcodegen`; `cd ios && xcodegen generate`; kökten `xcodebuild -project ios/JarvisMobile.xcodeproj -scheme JarvisMobile -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`. CI bu adımları uygular.

Gerçek iPhone: temiz kurulum/onboarding; izin kabul/ret ve Ayarlar'dan iptal; basılı tutup bırakma/izin ekranında bırakma; arka plana geçiş; çevrimdışı tr-TR destek yokken yazı; sesli yanıt opt-in; uygulama sonlandırma sonrası hafıza; kilitli cihaz erişim hatası; düzenleme/silme/dışa aktarma/iptal; 90/30 gün sınırları; VoiceOver. Konuşmacı doğrulaması daima etkin değil görünmeli.

## İkinci aşama CI
Workflow artık elle de başlatılır (`workflow_dispatch`). macOS-15 üzerindeki Xcode/Swift sürümleri loglanır; Swift 6 paket testleri, generic simulator derlemesi, seçilen iPhone simulator üzerinde hosted unit testler ve XCUITest çalışır.

Hosted test hedefi mevcut çekirdek testlerini de iOS'ta çalıştırır. EncryptedStorageTests gerçek Keychain erişim sınıfı, senkronizasyonun kapalı olması, nonce değişimi, kurcalama, anahtar kaybı/bozukluğu, yeniden açma/silme, başarısız dosya değişimi ve iOS complete file protection kontrolü yapar. Kullanılan Keychain kayıtları/dosyalar her testte temizlenir. Kilitli fiziksel cihaz davranışı simulator testiyle kanıtlanmaz.

SmokeTests üretim arayüzüyle onboarding, yazılı komut, yeniden başlatma, okuma, silme ve silme sonrası yeniden başlatmayı sınar. Gizli test yetki bypass'ı veya depolama sıfırlama kodu yoktur. PermissionConfigurationTests uygulamanın gerçek Info.plist dosyasında Türkçe Speech/mikrofon açıklamalarını doğrular. İzin politikası testleri ret/kısıt/sıralama ve cihaz içi tanıma zorunluluğunu sınar. Gerçek sistem izin diyalogları ve canlı Türkçe ses hâlâ fiziksel cihaz kabulü ister.

Her CI koşusu `ios-validation-<SHA>` artifact'ında xcresult, derleme/test logları ve başarılı test sonrası simulator `.app` zip'ini 14 gün saklar. Simulator uygulaması gerçek iPhone'a kurulamaz; cihaz için Xcode'da takım seçip imzalama gerekir.
