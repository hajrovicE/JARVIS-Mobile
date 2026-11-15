# Doğrulama
`swift test`: tam 90/30 gün ve bir saniye önceki sınırlar, kalıcı hafıza, zaman duyarlı önbellek dışlama, yeniden açma, düzenleme, tekli ve toplu silme, dışa aktarma, başarısız yazma, sürüm geçişi ve güvenli komut yönlendirme. Apple platformlarında ek AES-GCM yeniden açma ve değiştirilmiş şifreli dosyayı reddetme testi.

macOS: `brew install xcodegen`; `cd ios && xcodegen generate`; kökten `xcodebuild -project ios/JarvisMobile.xcodeproj -scheme JarvisMobile -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`. CI bu adımları uygular.

Gerçek iPhone: temiz kurulum/onboarding; izin kabul/ret ve Ayarlar'dan iptal; basılı tutup bırakma/izin ekranında bırakma; arka plana geçiş; çevrimdışı tr-TR destek yokken yazı; sesli yanıt opt-in; uygulama sonlandırma sonrası hafıza; kilitli cihaz erişim hatası; düzenleme/silme/dışa aktarma/iptal; 90/30 gün sınırları; VoiceOver. Konuşmacı doğrulaması daima etkin değil görünmeli.
