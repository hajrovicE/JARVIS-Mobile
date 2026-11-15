# Native AI M1 — iPhone'da çevrimdışı çıkarım

Durum: geliştirme dalı `feature/native-ai-m1`; gerçek cihazın kabul testleri henüz yapılmadı. M0 ortak çekirdek `feature/native-ai-m0` tabanındadır. Bu kodlar teknik prototiptir; sistem bağımsız kişisel modelin cihazda kurulduğu ve çalıştığı doğrulanmadan tamamlandı gösterilmez.

## Model ve lisans
- Resmî GGUF: https://huggingface.co/ggml-org/Qwen3-1.7B-GGUF/blob/main/Qwen3-1.7B-Q4_K_M.gguf
- SHA-256: `d2387ca2dbfee2ffabce7120d3770dadca0b293052bc2f0e138fdc940d9bc7b5`
- Kaynak: `ggml-org/Qwen3-1.7B-GGUF`, revision: `daeb8e2`, lisans Apache-2.0.
- İndirilen tek GGUF dosyası yaklaşık 1,28 GB; dosya indirme ve kurulum kullanıcı tarafından açıkça başlatılır, Git deposuna model ağırlığı eklenmez.
- Çıkarım motoru: https://github.com/mattt/llama.swift, sabit sürüm 2.10331.0; llama.cpp önceden derlenmiş XCFramework'u üzerinden Apple Metal/CPU. Swift package MIT ve llama.cpp MIT üçüncü taraf lisans bildirimlerini sürüm öncesi ekle.

## Veri akışı
SwiftUI -> `LocalAIProvider` -> `OnDeviceModelManager` (SHA-256) -> `GGUFInferenceRuntime` -> yerel model.
- `AIProcessingMode.onDevice` seçiliyken ağ izni gerekmez; uzak model için mevcut açık paylaşım onayı korunur.
- Hafıza şifreli `MemoryStore` içinde kalır. Cihaz modeli için en çok 5×400 karakterlik bağlam kullanılır. Kullanıcı izinleri olmadan hiçbir sunucuya aktarılmaz.
- Model yanıtı hiçbir `ActionExecutor` eylemine yetki vermez; hassas işlemlerde mevcut Face ID ve kapsamlı onay gerekir.
- Tokenizasyon Qwen3 için chat özel işaretlerini kullanır. Farklı model aileleri model ve tokenizer şablonu eşleşmeden kullanılamaz. Model kaynağı değiştirilirse yeni digest, revision, lisans ve benchmark zorunlu.
- İlk pakette yerel model dosyası hazır değilse açık hata verir. Buluta sessiz fallback yoktur.
- Sorgu sırasında model dosyası SHA-256 yeniden kontrol edilir; bu büyük bir dosya için yavaş olabilir. Gerçek cihazda benchmark, güvenli doğrulama önbelleği ve RAM/termal performans ölçümleri yapılmalıdır.

## Geliştirme / CI
1. PR #4'ün Swift/macOS/iOS testlerini başarıyla tamamladığını doğrula.
2. PR #5'in Swift/macOS/iOS derlemeleri ve testlerini ayrı doğrula; macOS simulator veya gerçek model taklidi, fiziksel cihaz performans kanıtı değildir.
3. Gerçek iOS cihazda indirilen modelin SHA-256 doğrulamasını, uygulama kapatma/açma, uçak modunda Türkçe soru-cevap, pil/ısınma/RAM, özel veri sızıntısı ve silme testlerini yap.
4. Öncelikle düşük bağlam ve 160 token üretim limitiyle test et; uygulama arka plana geçtiğinde üretimi iptal etmeyi doğrula.
5. Apple Developer üyeliği / uygun cihaz imzalama hazır değilse gerçek cihazda test edilmiş gibi raporlama.

## Sınırlar
- Anlık web bilgi kaynağı yok; yerel cevaplar `unverified`.
- Tamamen çevrimdışı ses için Whisper.cpp/STT ve yerel TTS hâlâ ayrı M2 işidir.
- Modeli özelleştiren LoRA ince ayar şu aşamada yapılmadı.
- Model dağıtımının Türkiye'de ve App Store'da kabulü, gerçek cihaz belleği ve çalışma hızı henüz test edilmedi.
