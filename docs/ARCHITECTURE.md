# Mimari
`JarvisCore`: actor tabanlı MemoryStore, Sendable SnapshotStorage arayüzü ve sürümlü yerel komutlar. Öğrenme, görev ve konuşma kayıtları kullanıcı silene kadar korunur; kaynak güncelliği kayıt silmeden ayrı değerlendirilir. Her değişiklik önce diske yazılır; başarısız yazma canlı durumu değiştirmez.

Apple platformlarında EncryptedFileStorage, CryptoKit AES-256-GCM ve atomik dosya değişimi kullanır. 256 bit anahtar Keychain WhenUnlockedThisDeviceOnly erişimiyle saklanır; iOS dosyaları completeFileProtection kullanır ve yedeklemeye dahil edilmez. Mevcut dosyada anahtar yoksa veri ezilmez. Bozuk şifreli veri hata üretir. JSON yalnızca şifre çözülmüş bellekte veya kullanıcının açık dışa aktarma işlemi sırasında bulunur. Dışa aktarılan dosya şifreli değildir; kullanıcı paylaşacağı yeri seçer.

Güncel şema v3; v0/v1/v2 payloadları korunarak AI konuşma arşivi alanı eklenir. Öğrenme revizyonları ve görev düzeltmesi referansı eski kayıtlarda isteğe bağlıdır. Açılışta TTL temizliği uygulanır. Bilinmeyen sürümler reddedilir; önceki depoda veri uygulaması bulunmadığından başka eski biçim içe aktarımı yoktur. Silme mevcut şifreli dosyayı kayıtlar olmadan yeniden yazar; flash depolamada adli düzey fiziksel silme garantisi verilmez.

SwiftUI uygulaması yalnızca uygulama tercihlerini UserDefaults içinde tutar. Ses ham dosyaya veya loga kaydedilmez. Yerel Speech zorunludur; uzak tanımaya otomatik geçilmez. Kimlik güvenliği ses transkripsiyonundan ayrıdır. Harici araçlar çalıştırılmaz; desteklenmeyen metinler güvenli açıklama döndürür.

## İkinci aşama değişiklikleri
Swift 6 dili hem paket hem uygulama hedefinde etkin. Şema v2, `learning` alanını ekler; v0/v1 kayıtları bozulmadan geçer. LearningEngine ve veri akışı için docs/LEARNING_ENGINE.md.

Şifreli depolama artık kilitle seri I/O yapar. Şifreli geçici dosyaya koruma, 0600 izin ve backup dışlama metadata'sı uygulandıktan sonra aynı dizinde atomik rename yapılır; sonradan metadata hatasıyla yanlış başarısızlık bildirilmez. Başarısız değişimde geçici dosya temizlenir. Keychain oluşturma yarışında mevcut anahtar tekrar okunur. Tek uygulama bir MemoryStore sahibi kullanır; ayrı süreçler/ayrı store sahipleri arasında değişiklik birleştirme desteklenmez.

iOS izin adaptörü Speech ve mikrofonu sırayla ister. Ret halinde Ayarlar, kısıt halinde metin alternatifi gösterir. Basılı tutma sırasında izin ekranında bırakma veya arka plana geçiş bekleyen kaydı iptal eder. Normal bırakma son transkripsiyonu kısa süre bekler; kesinti/arka plan kaydı ve TTS'yi iptal eder. Speech tanıması kimlik yetkilendirmesi vermez.


## Alpha 0.3
`AssistantService` yerel komutları önce işler; `AIProvider` yalnızca açık onayla yapılandırılmış HTTPS relay'e soru ve ayrı seçilmiş sınırlı bağlam gönderir. Provider anahtarı yalnızca server/ içinde environment/secret manager'dan alınır; mobil relay oturumu ayrı Keychain kaydındadır. Yönlendirme, hata gövdesi sızıntısı, gömülü anahtar veya sessiz ağ fallback'i yoktur.

`generatedAnswers` soru/yanıt/provider/model/kaynak/zaman metadata'sını kalıcı kullanıcı arşivi olarak saklar. `cacheUntil` yeniden kullanım süresidir (en fazla 30 gün); kaynak/tazelik doğrulanmamışsa yoktur. Canlı relay henüz web araması yapmaz; unverified döndürür, yeniden kullanım açılmaz. Geçmiş paylaşımı açık olduğunda yeni tur için geçmiş bağlam gönderilir ve önbellek kullanımı kapatılır. Geçmişteki AI cevabının kişisel/öğrenme verisinden türemiş olması kategoriyle izlenir; o kategori için onay geri çekilince sonraki paylaşımda dışlanır.

MemoryStore bir contextEpoch kullanır. Yerel bağlam değişince bekleyen yanıtlar eski epoch ile geri yazılamaz; geçmişteki AI arşivi kullanıcı tarafından silinmedikçe korunur. Cache dönüşü de epoch kontrolünden geçer. AI kullanımı kapatılırsa bekleyen istek iptal edilir; gönderilmiş verinin dış sağlayıcıdan geri alınabildiği iddia edilmez. Model metni eylem yürütme veya öğrenme onayı değildir.

`PermissionManager` doğrudan kullanıcı arayüzü komutundan tek kullanımlık yetki üretir; yeni onay penceresi veya Face ID istemez. Model üretimi ve hafıza metni tek başına yetki vermez. `ActionExecutor` başarılı gerçek etki sonrası makbuz ve redakte görev deneyimi üretir; etki/audit hataları ayrıdır. Model kaynağından gelen öneri doğrudan çalıştırılamaz. Bütün veri silindiğinde kalıcı audit yazıp silinen veriyi yeniden yaratmaz.

`LearningEngine` düzeltmelerin flat revizyon arşivini, görev deneyimi kaynaklarını ve açık onay bekleyen kuralları tutar. Silme ilgili eski sürüm ve bağlı deneyimleri kaldırır. `SpeakerSecurity` ayrı fail-closed arayüzdür; mevcut adaptör notImplemented döndürür. Speech/TTS kaynakları yalnızca ses isteğinde oluşturulur.

Kapsam ve sınırlar: docs/ALPHA_0_3.md. Manuel hesap/CI imzalama: docs/IPHONE_DISTRIBUTION.md. Canlı model, fiziksel cihaz ve TestFlight doğrulamaları derleme/test sonucundan ayrı raporlanır.
