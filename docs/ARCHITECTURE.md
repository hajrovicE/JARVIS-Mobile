# Mimari
`JarvisCore`: actor tabanlı MemoryStore, Sendable SnapshotStorage arayüzü, Codable sürümlü veri ve sınırlı yerel CommandRouter. Saat parametresi TTL sınırlarını test etmeye izin verir. Her değişiklik önce diske yazılır; yazma başarısızsa canlı durum değiştirilmez. Okumada ve açılışta TTL temizliği kalıcılaştırılır; uygulama aktifleştiğinde tekrar okunur. Uygulama kapalıyken iOS kesin zamanlı arka plan silme garantisi vermez; süre dolmuş kayıtlar sonraki erişimde temizlenir.

Apple platformlarında EncryptedFileStorage, CryptoKit AES-256-GCM ve atomik dosya değişimi kullanır. 256 bit anahtar Keychain WhenUnlockedThisDeviceOnly erişimiyle saklanır; iOS dosyaları completeFileProtection kullanır ve yedeklemeye dahil edilmez. Mevcut dosyada anahtar yoksa veri ezilmez. Bozuk şifreli veri hata üretir. JSON yalnızca şifre çözülmüş bellekte veya kullanıcının açık dışa aktarma işlemi sırasında bulunur. Dışa aktarılan dosya şifreli değildir; kullanıcı paylaşacağı yeri seçer.

Şema v0→v1 aynı veri alanlarıyla yükseltilir ve TTL temizliği uygulanır. Bilinmeyen sürümler reddedilir; önceki depoda veri uygulaması bulunmadığından başka eski biçim içe aktarımı yoktur. Silme mevcut şifreli dosyayı kayıtlar olmadan yeniden yazar; flash depolamada adli düzey fiziksel silme garantisi verilmez.

SwiftUI uygulaması yalnızca uygulama tercihlerini UserDefaults içinde tutar. Ses ham dosyaya veya loga kaydedilmez. Yerel Speech zorunludur; uzak tanımaya otomatik geçilmez. Kimlik güvenliği ses transkripsiyonundan ayrıdır. Harici araçlar çalıştırılmaz; desteklenmeyen metinler güvenli açıklama döndürür.

## İkinci aşama değişiklikleri
Swift 6 dili hem paket hem uygulama hedefinde etkin. Şema v2, `learning` alanını ekler; v0/v1 kayıtları bozulmadan geçer. LearningEngine ve veri akışı için docs/LEARNING_ENGINE.md.

Şifreli depolama artık kilitle seri I/O yapar. Şifreli geçici dosyaya koruma, 0600 izin ve backup dışlama metadata'sı uygulandıktan sonra aynı dizinde atomik rename yapılır; sonradan metadata hatasıyla yanlış başarısızlık bildirilmez. Başarısız değişimde geçici dosya temizlenir. Keychain oluşturma yarışında mevcut anahtar tekrar okunur. Tek uygulama bir MemoryStore sahibi kullanır; ayrı süreçler/ayrı store sahipleri arasında değişiklik birleştirme desteklenmez.

iOS izin adaptörü Speech ve mikrofonu sırayla ister. Ret halinde Ayarlar, kısıt halinde metin alternatifi gösterir. Basılı tutma sırasında izin ekranında bırakma veya arka plana geçiş bekleyen kaydı iptal eder. Normal bırakma son transkripsiyonu kısa süre bekler; kesinti/arka plan kaydı ve TTS'yi iptal eder. Speech tanıması kimlik yetkilendirmesi vermez.
