# JARVIS Native AI — Tam Çevrimdışı Çekirdek (taslak v1)

**Ürün kararı (15 Kasım 2026):** JARVIS'in temel sohbeti, Türkçe ses işlem hattı, kişisel hafızası, öğrenme kayıtları ve izinli yerel eylemleri **cihaz üzerinde**, model sağlayıcısına veya üretim sunucusuna bağlı olmadan çalışabilmeli. Bu karar, mevcut uzaktaki sağlayıcı kodunu silme yetkisi değildir. GitHub deposunun ve ürünün adı JARVIS Mobile olarak kalır.

## Gerçekçilik / kapsam
- Telefon üzerinde 1–2B parametre sınıfı sıkıştırılmış açık-ağırlık model hedeflenir; GPT-6 eşdeğeri kalite vaat edilmez. RAM, depolama, pil, sıcaklık, hız, Türkçe kalite ve model uyumluluğu gerçek cihazda ölçülür. İlk 4-bit modelin ağırlıkları ~0.5–2 GB sınıfında olabilir; tokenizer, çalışma belleği, KV cache, ek modeller ve sistem yükü ayrıca hesaplanır.
- **Sıfırdan dev model eğitimi** proje hedefi değildir; ilk adım lisansı uygun açık-ağırlıklı modeli cihazda çalıştırmak, daha sonra JARVIS'e özel veri kümesi + değerlendirme + LoRA/QLoRA / uygun fine-tune ile JARVIS modeli üretmektir. İnce ayar dış hesaplama kaynağı gerektirebilir ancak dağıtılan modelin cevap üretmesi sunucu gerektirmez. Üçüncü taraf kaynak modelin lisansı ve atıfları korunur; yalnızca uygulama kodu/model ayarları bizim geliştirmemizdir.
- Başlangıç adayları: Qwen3-1.7B (Apache-2.0); hafif fallback Qwen3-0.6B veya Qwen3.5-0.8B; deneysel Qwen3.5-2B (Apache-2.0) ancak iOS inference motoru destek/performans testi başarılıysa. Lisans, tam revision, tokenizer, GGUF/MLX/Core AI dönüştürme zinciri ve SHA-256 manifest ile sabitlenmeli. Model lisansını release öncesi tekrar denetle.
- Runtime önerisi: mevcut iOS 17+ / Swift 6 hedefiyle uyumlu **llama.cpp (GGUF, Metal)** tabanlı on-device bridge; MLX Swift alternatif olarak profil edilir. Apple Core AI yalnızca ayrı iOS 27+/Xcode 27+ koşullu yol olabilir; iOS 17 projesinde zorunlu dependency yapılmaz. Cihaz desteklemiyorsa yalancı başarı olmadan model durumu açıklanır.
- İlk model edinimi kullanıcı onaylı bir indirme veya lisans izin veriyorsa dağıtım paketine dahil etme ile olur. Model ağırlıkları Git deposuna commit edilmez. Model indirildikten sonra temel sohbet için ağ erişimi gerekmemeli. Dış cihaz/servis entegrasyonları fiziksel ağ gerektirebilir; "tüm işlevler internetsiz" vaadi verilmez.

## Mimari
```
SwiftUI / CommandRouter
  -> TrustedIntentRouter (kural ve izinli eylem)
  -> AIProvider protocol
     -> LocalAIProvider (default; cihaz içi motor)
     -> HTTPRelayAIProvider (optional, kapalı; yalnızca açık opt-in)
  -> Encrypted MemoryStore / LearningEngine (cihaz içinde)
  -> Audio: offline speech-to-text -> local model -> offline text-to-speech
  -> Allowlisted ActionExecutor / PermissionManager / LocalAuthentication
```
- Model çıktısı hiçbir zaman doğrudan sistem eylemi gerçekleştirmez. Kullanıcıya doğrulama, izin kapsamı, risk seviyesi ve sonuç makbuzu gösterilir.
- Offline modda AI, ses ve hafıza için **hiçbir HTTP isteği, gizli telemetri, hesap giriş zorunluluğu veya arka planda bulut fallback yok**. Ağlı servisler ayrı izin kapılarıyla açıkça seçilebilir. Gerçekten offline model kurulu değilse eksikliği söyle.
- 90 gün konuşma geçmişi, statik doğrulanmış yanıtlarda üst sınır 30 gün cevap önbelleği, kullanıcı silene kadar kalıcı hafıza. Düşük güvenli / zaman duyarlı bilgiler kalıcı kesin bilgi olmaz. Retrieval/RAG, onaylı tercih, görev hatası ve düzeltme kayıtlarıyla öğrenme; cihaz üzerinde kendi model ağırlıklarını başına buyruk güncelleme yok. Sıfırdan öğrenme ile hafıza güncelleme kullanıcıya ayrıştırılarak anlatılır.
- Gizlilik: AES-GCM + Keychain, dosya koruması; kullanıcı silme/export/yenileme ve kaynak/provenance. Model cevaplarının doğruluk sınırları açıkça gösterilir. Offline yerel sohbet uygulama günlüklerine prompt yazmaz.
- Ses: Türkçe için offline Whisper.cpp çok dilli tiny/base modellerini ölç; iOS Speech on-device ancak mevcut dil/cihazda çevrimdışı olduğu doğrulanırsa fallback olarak seçilir. Sesli yanıt için gerçek offline TTS desteğini doğrula (sistem sesi önceden indirilmiş olabilir; gerekiyorsa ayrı yerel model). Sürekli arka plan wake-word iOS tarafından kısıtlanabilir; push-to-talk temel deneyim. Konuşmacı doğrulama hâlâ tamamlanmadı ve yüksek riskli yetkilendirmeye tek başına yetmez.
- "Developer Mode" cihaz içi kod açıklama, düzenleme ve basit üretim sağlayabilir; iPhone içinde Xcode/macOS kod imzalama/CI koşma kabiliyeti vaat edilmez. Harici GitHub / internet görevleri isteğe bağlı ayrı bağlantıdır.

## İlk Codex kilometre taşları
### M0 — Cihaz/gerçeklik profili (kod/test)
- Mevcut tüm modellerin/encryption/testlerin çalıştığını kontrol et; esas 6 GB RAM sınıfı iPhone cihazını hedefle fakat cihazdan alınan kullanılabilir bellek miktarını ölç.
- ModelRuntime, ModelManifest, LocalAIProvider, DownloadManager (izinli, checksum, iptal/devam, depolama kontrolü, silme) protokollerini hazırla. **Model kurulmadan AI yanıtı üretmeyi taklit etme.**
- Kısa bağlam hedefi belirle, bellek baskısı/thermal ile güvenli kapatma, ekran kilidi ve uygulama arka planında iptal/yük boşaltma.
- Simülatör mock testleri; gerçek on-device inference cihazda doğrulanmadan tamamlandı deme.

### M1 — Gerçek cihaz içi metin üretimi
- iOS'a llama.cpp bridge ya da teknik olarak karşılaştırılıp seçilen eşdeğer açık yerel inference motorunu entegre et. SHA-256 doğrulamalı GGUF/model, tokenizer, prompt şablonu.
- Internet kapalıyken Türkçe 10 örnek soru + belleğe dayalı 5 soru; uydurma veya canlı bilgi istemelerinde "güncel kaynağa erişimim yok" cevabı. Açık kaynak lisans bildirimi.
- Ölç: ilk yükleme süresi, token/sn, zirve bellek, kullanılan depolama, 5 dk sürekli kullanımda termal etki, pil tüketimi (mümkünse); telefona göre ikinci model boyutu belirle.

### M2 — Tam çevrimdışı ses ve hatırlama
- Offline Turkish STT / offline TTS. 90/30 gün kuralları, kalıcı hafıza ve öğrenme engine entegrasyonu.
- İlk indirme dışında ağ çağrısı = 0 birim/entegrasyon egress testleri; uçak modu gerçek cihaz kabulü.

### M3 — JARVIS'e özel uyarlama
- Kullanıcının *açıkça onayladığı*, hassas içerik içermeyen Türkçe örnekler, instruction/response ve düzeltme veri şeması. Kayıtların tamamını kişisel öğrenme verisi olarak otomatik model fine-tuning'e kopyalama.
- Ayrı offline/eğitim iş hattı: LoRA/QLoRA deneyleri, lisans ve dataset provenance, sabit holdout Türkçe benchmark, sürümleme, model kaynağı ve parametre/güvenlik raporu.
- Sürümü sonradan telefona yükle; gerileme olursa rollback; kişisel veri transferi için ayrı onay.

## Kabul testi / tanım
1. iPhone uçak modunda ve model kuruluyken Türkçe soruya gerçek cihaz içi çıkarımla yanıt üretir; model-yüklü değilse açıklayıcı hata.
2. Hafızaya kaydedilen tercih tekrar bulunur; aynı bilgi buluta çıkmaz; uygulama yeniden açılınca korunur; silme indeks ve onaylı ilişkili kayıtlara yayılır.
3. Model yanıtı komut çalıştırmaz; riskli eylem için scoped user consent + biyometri ayrı.
4. Desteklenen iPhone'da STT/TTS offline raporu; izin retleri ve iptal açıkça yönetilir.
5. Simülatör/unit, macOS CI ve gerçek cihaz testlerinin ayrımı korunur; TestFlight/cihaz teslimi için Apple imzası gerekebilir.
6. Bütün üçüncü taraf model/runtime lisansları ve manifest checksumları doğrulanır; gizli tokenlar kaynak kodunda veya mobil uygulamada bulunmaz.

## Kaynak değerlendirme
- https://huggingface.co/Qwen/Qwen3-1.7B
- https://huggingface.co/Qwen/Qwen3.5-2B
- https://github.com/ggml-org/llama.cpp
- https://github.com/ggml-org/whisper.cpp
- https://developer.apple.com/core-ai/
- https://developer.apple.com/documentation/foundationmodels/running-a-core-ai-model-in-a-foundation-models-session
