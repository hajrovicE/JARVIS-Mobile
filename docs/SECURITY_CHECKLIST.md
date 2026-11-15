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
