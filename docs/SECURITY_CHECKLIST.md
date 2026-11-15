# Güvenlik kontrolü
- [x] AES-GCM, Keychain ThisDeviceOnly, iOS complete file protection kaynakta mevcut.
- [x] API anahtarı, ham ses veya kişisel içerik loglama yok.
- [x] Harici eylem veya prompt tabanlı araç çalıştırma yok.
- [x] Kalıcı hafıza düzenleme/silme/dışa aktarma; tüm veri silme onayı.
- [x] Yalnızca cihaz içi Speech; izin reddinde metin alternatifi.
- [x] macOS şifreleme testinin CI sonucu doğrulandı (25 test, 0 hata).
- [x] iOS simulator ve iPhone SDK derlemeleri başarılı.
- [x] iOS Keychain, şifreli kişisel/öğrenme hafızası ve yeniden açma/silme testleri başarılı.
- [x] Üretim UI akışında kaydetme/yeniden başlatma/okuma/silme doğrulandı.
- [ ] Fiziksel iPhone Data Protection ve kilitli cihaz testi (simulator üzerinde açıklamalı atlandı).
- [ ] Gerçek cihaz kilit, izin, ses, erişilebilirlik testi.
- [ ] Yeni harici eylemler için risk, onay, biyometri ve makbuz altyapısı.
- [ ] SpeakerSecurity bağımsız inceleme ve saldırı testleri.

Kanıt: docs/VALIDATION.md, Actions koşusu 43676038209. İzin politikası ve Info.plist testleri canlı ses testi yerine geçmez.

## Alpha 0.3
- [x] API sağlayıcı anahtarı mobil binary'de yok; relay oturumu ayrı Keychain kaydında.
- [x] AI kullanımı varsayılan kapalı; bağlam kategorileri ayrı opt-in, türetilmiş geçmiş paylaşımı da kategori onayına uyar.
- [x] Model metni yürütülmez; allowlist/scope/tek kullanımlı yetki ve hata/başarı makbuzu ayrımı test edildi.
- [x] Hassas silme ve export için gerçek LocalAuthentication adapter'ı; biyometri yokluğunda fail-closed.
- [x] SpeakerSecurity açıkça unavailable/notImplemented; konuşma tanıma kimlik yetkisi sağlamaz.
- [x] Release build-only başarılı; signing/upload gerçek üyelik + Secrets + manual protected environment gerektirir ve bu görevde çalıştırılmadı.
- [ ] Canlı sahipli AI sunucusu/LLM ve sağlayıcı saklama/gizlilik politikası kabulü.
- [ ] Fiziksel Face ID/Touch ID, Speech/TTS, locked-device DataProtection ve erişilebilirlik.
- [ ] Gerçek Apple signing/TestFlight ve hesap metadata'sı.
- [ ] İmzalı beceri kataloğu, çok kullanıcılı sunucu auth ve bağımsız güvenlik incelemesi.

Son kanıt: docs/VALIDATION.md, CI 43696051313 ve Release 43696133368. 90/30 günlük kurallar, kalıcı hafıza ve eski sürüm migration testleri korunur.
