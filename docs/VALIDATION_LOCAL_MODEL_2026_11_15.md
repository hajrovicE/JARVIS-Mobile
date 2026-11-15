# Yerel model kapsamlı denetimi — 15 Kasım 2026

Başlangıç ve en güncel kontrol edilen `main`: `e0e710f714dd31b40f49354b6ca23fa89e86f45b`. Düzeltmeler `fix/comprehensive-local-model-validation-20261115` dalındadır. Güncel sahip kararları AGENTS.md içindedir; eski Alpha belgelerindeki şifreleme, 90 günlük silme ve ek biyometri şartları aktif ürün davranışı değildir.

## Gerçekten çalıştırılan kontroller

| Kontrol | Sonuç ve sınır |
| --- | --- |
| Swift 6.0.3, Linux | 105 test, 0 hata; tüm mevcut testler ve yeni regresyonlar |
| Python sunucu | 22 test başarılı; gerçek sağlayıcı çağrısı yok |
| Python Release politikası | 9 test başarılı; Apple Secrets kullanılmadı |
| Python model/veri/routing | 8 test başarılı; eğitim veya model kalitesi kanıtı değildir |
| Üretimdeki Swift çıkarım kaynağı + gerçek llama.cpp | Derlendi ve gerçek Qwen GGUF ile CPU çıkarımı yapıldı |
| İnternet kapalı çıkarım | Docker `--network none`, gerçek GGUF; kanıt kaydı aşağıda |
| Sistem talimatı | Çok satırlı Türkçe/Unicode metin eksiksiz model sohbet şablonuna aktarıldı; 1220 tokenlık prompt çoklu 512-token prefill ile işlendi |
| Model ayarları | Gerçek üretimde 1/2/48 token bütçeleri, 1024/4096 bağlam, greedy ve temperature 0.6/topP 0.7, 1/2 CPU thread; geçersiz ayar, iptal ve bağlam taşması açık hata |
| GGUF içe aktarma | Gerçek 410 MB ağırlık kopyalandı, aynı kimlik değiştirildi, bozuk değişiklik reddedilip kurulu dosya korundu, manifest yeniden açıldı; SHA sabitlemesi yok |
| Yerel sohbet + hafıza | Gerçek LocalAIProvider → AssistantService → kişisel bağlam → model cevabı → JSON; yeni MemoryStore ile yeniden açma başarılı |
| Hafıza/öğrenme | Kaydet/düzenle/sil/export/restart, başarısız yazma, sürüm reddi, tazelik ile kalıcılık ayrımı, çelişki/düzeltme/ilişkili silme, saat geri alma regresyonları |
| İşlem sınırı | Doğrudan sahip komutu çalışır; model yanıtı/geçmiş/dış veri eylem başlatmaz; iptal öncesi yan etki yok; başarısız makbuz başarı demez |
| Swift iOS sözdizimi/YAML/shell | Ayrıştırma ve `git diff --check` başarılı; Apple SDK ile typecheck/derleme yerine geçmez |

Yerel test kanıtları: [Swift](validation-artifacts/2026-11-15/swift-tests.log), [sunucu](validation-artifacts/2026-11-15/python-server.log), [Release](validation-artifacts/2026-11-15/python-release.log), [model kuralları](validation-artifacts/2026-11-15/python-model.log), [ağ kapalı gerçek çıkarım](validation-artifacts/2026-11-15/real-runtime-network-none.log). Bunlar bu geliştirme ortamının kayıtlarıdır; GitHub macOS koşusu değildir. Tüm metinler sentetik test verisidir.

## Model kalitesi: başarısız gözlem

Küçük `Qwen3-0.6B-Q4_0` test modeli, deterministik ayarlarda “Türkiye'nin başkenti neresidir?” sorusuna **İstanbul** yanıtını verdi. Bu yanlış cevaptır. Kişisel bağlamlı ikinci soruda Ankara cevabı üretildi. Çıkarımın çalışması, modelin doğruluğu, sistem talimatlarına semantik itaati veya çok adımlı muhakemesinin güvenilirliğini kanıtlamaz. `MODEL_QUALITY_FAIL` satırı kanıtta korunmuştur. Bu denetimde model eğitilmedi; yanıt uygulama tarafından örnek cevapla değiştirilmedi.

## Düzeltilen gerçek sorunlar

- SwiftUI hata yolunda artık mevcut olmayan `connectionStatus` değişkeni kullanılıyordu; yerel model durumu ve açık ayar/bağlam/şablon hataları gösteriliyor.
- Eski SHA checker arayüzünü kullanan testler derlenmiyordu. Sahip tercihi korunarak gerçek GGUF yapısal doğrulaması eklendi; model kurulu diye çıkarım başarılı denmiyor.
- Model içe aktarma aynı kimlikte eski dosyayı döndürüyordu. Önce doğrulama ve kopya, sonra atomik değiştirme uygulanıyor; başarısızlık eski modeli koruyor.
- Sabit sohbet şablonu yerine modelin gerçek şablonu kullanılıyor; sahibin sistem metni değiştirilmeden aktarılıyor. Ayarların sessizce minimuma yükseltilmesi ve son token sonrasında gereksiz decode kaldırıldı.
- AES geçişi ham içeriği doğrulamadan JSON'a yazıyor ve eski dosyayı bırakıyordu. Şema doğrulanıp atomik JSON yazıldıktan sonra eski kayıt kaldırılıyor; mevcut JSON varken anahtar aranmıyor. Hatalı geçiş kaynak veriyi korur; tam silme sonrası eski veriler dirilmez.
- Geçerli hafıza ve etkinlik günlüğünü açmak gereksiz disk yazmasına bağlıydı. Disk yazma hatasında okunabilir mevcut kayıtlar açılabilir.
- Hafıza düzeltmesi önbellek tekrar kullanımını geçersiz kılmıyordu. Tazelik ve contextEpoch güncellenirken arşiv cevaplar silinmiyor. Saat geri alındığında gelecekteki cevap/etkinlik güncel sayılmıyor.
- Çekirdek sohbet servisinde doğrudan düzenle/sil/export komutları işlenmiyordu; gerçek yürütme sonucu ve export verisi döndürülüyor. Model metni tekrar komut parser'ına verilmez.
- Geçmiş komutu AI konuşmalarını göstermiyordu; kronolojik geçmişe dahil ediliyor. Öğret komutu sondaki boşlukları kırparak mevcut testi bozuyordu; metin korunuyor.
- İptal edilmiş görev yürütücüsü yan etki başlatabiliyordu. Başlangıç ve yetki tüketimi sonrasında iptal kontrolü eklendi.
- TTS `didCancel` olayı tamamlanmış gibi raporlanıyordu; iptal ve bitiş ayrıldı.
- UI testi kaldırılmış ikinci biyometrik onayı bekliyordu; doğrudan silme/yeniden açma ve sistem talimatı kalıcılığı testleri güncellendi. Bunlar iOS'ta henüz çalıştırılmadı.
- Sunucu testinde erken HTTP413 reddine rağmen 4 MB gövde gönderilmesi BrokenPipe yarışına yol açıyordu. Gerçek HTTP testi aşırı Content-Length başlığının gövde okunmadan reddedildiğini doğruluyor.

## Çalıştırılamayan kabul ve GitHub engeli

Referans main [Actions koşusu](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/43710329593) hiçbir test adımı başlamadan başarısız oldu:

> The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the 'Billing & plans' section in your settings.

Bu ortam Linux'tur. Mevcut kaynak için macOS Swift testleri, Xcode simulator/iPhone SDK derlemesi, hosted Apple AES/Keychain geçişi ve UI testleri **ÇALIŞTIRILAMADI**. Yeni workflow gerçek GGUF dosyasını test bundle'ına alır; CI'da dosya eksikse gerçek çıkarımı sessizce atlamak yerine başarısız olur. Yerel ağırlık indirme ve eğitim veri setleri Git'e alınmaz. Ücretli servis başlatılmadı, harici AI API çağrısı yapılmadı, Apple imzası/TestFlight yüklemesi yapılmadı.

**Fiziksel iPhone/Metal, mikrofon-Speech izin diyalogları, canlı Türkçe tanıma/TTS, bellek basıncı, kilit/arka plan, VoiceOver, Dosyalar'dan güvenlik kapsamlı import ve paylaşım paneli: AYRICA DOĞRULANMADI.** Linux'taki aynı Swift kaynakla CPU çıkarımı bu kontrolleri karşılamaz.

Etkinlik günlüğü/alışkanlık önerisi çekirdeği testlidir, fakat SwiftUI uygulamasına bağlı değildir. Gerçek konuşmacı biyometrisi, genel telefon kontrolü, web doğrulama ve imzalı beceri yükleme uygulanmış değildir. LoRA eğitim araçları bu görevde eğitilmedi veya uçtan uca doğrulanmadı. Sahibin seçeceği başka modelin sohbet şablonu/quantization/memory gereksinimi o gerçek dosyayla ayrıca test edilmelidir.

Tüm gerekli iOS kontrolleri geçmediği için dal main'e birleştirilmemeli ve sürüm gerçek iPhone'a hazır ilan edilmemelidir. Hesap sahibi GitHub Billing & plans engelini kaldırdıktan sonra aynı PR'da macOS/iOS ve build-only Release koşuları yeniden çalıştırılmalıdır. Gerçek cihaz kurulumu için uygun Apple imzalama, TestFlight için aktif ücretli üyelik ve mevcut dağıtım belgesindeki Secrets gerekir.

## Yeniden üretme

`swift test -Xswiftc -swift-version -Xswiftc 6` ve üç Python unittest keşif komutu workflow içinde bulunur. Linux gerçek çıkarımı: `scripts/model/verify_runtime.sh /tmp/jarvis-native-proof` (Swift 6, CMake, Ninja, C/C++ derleyici, git ve curl). Public Apache-2.0 Qwen test ağırlığı revision `afe8ad3577aa22500b3cd1c880f153b3b0e1cae8`; llama.cpp `b2e5e9b28b2484fbf94b543432ece638996a8b97` (b10549). iOS LlamaSwift tam `2.10549.0` sürümüne sabitlendi. SHA-256 kullanıcı modeli için kabul kapısı değildir.

Ağ kapalı kanıt, derlenen RuntimeProof executable'ı ve salt okunur test dosyalarıyla `docker run --network none --read-only` altında üretildi; geçici hafıza ve içe aktarma dosyaları ayrı yazılabilir geçici dizinde tutulup silindi. Runtime kaynak kopyası `cmp` ile uygulamanın gerçek Swift dosyasıyla eşleştirildi.
