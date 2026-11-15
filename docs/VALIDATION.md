# Doğrulama raporu — 15 Kasım 2026
- Başlangıçta Swift kurulu değildi; ilk `swift test` çalıştırılamadı. Swift 6.0.3 Ubuntu 24.04 araç zinciri çalışma alanına kuruldu.
- Linux üzerinde `swift test`: 6 XCTest, 0 hata. JarvisCore ve komut yönlendiricisi derlendi. TTL sınırları, zamana duyarlı önbellek, kalıcı hafıza, yeniden açma/düzenleme/silme/export, sürüm geçişi, başarısız yazma ve komut yönlendirme testleri geçti.
- `git diff --check`: geçti.
- CryptoKit/Security şifreleme testi yalnızca Apple üzerinde derlenir; Linux test sonucuna dahil değildir.
- Xcode ve Apple SDK yok: SwiftUI hedefi, simulator, Keychain/CryptoKit entegrasyonu ve Türkçe sesli giriş çalıştırılmadı. Simulator ekran görüntüsü yok. macOS CI yapılandırması eklendi; bu rapor CI başarısı iddia etmez.
- Gerçek cihaz kabulü ve güvenlik kontrol listesindeki açık maddeler tamamlanmadan üretime hazır kabul edilmemeli.

Linux'ta yeniden çalıştırma için yazılabilir Swift/Clang önbellek yolları gerekebilir; araç zinciri ve geçici önbellekler depoya eklenmez.
