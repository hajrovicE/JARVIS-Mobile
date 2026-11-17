# İmza öncesi güncel ek doğrulama — 17 Kasım 2026

[Son hazırlık ve kanıtlar](PRE_SIGN_VALIDATION.md): `810a6c1` kaynağında Linux 178, macOS 180, iOS 197 ve UI 4 test başarılı. İmzasız archive 0.3.0 (8), dSYMs ve hazırlık JSON’u doğrulandı; Apple signing ve fiziksel cihaz kabulü yapılmadı.

# Güncel PR #20 doğrulaması — 17 Kasım 2026

[Akış, resident GGUF, Türkçe ses ve gerçek test/performans sonuçları](PR20_VALIDATION.md). `9aea7cc` kaynağında Linux 173, macOS 175, iOS hosted 190 ve UI 3 test; Simulator ve imzasız iPhone Debug/Release derlemeleri başarılıdır. Release paketi 0.3.0 (6) olarak açılıp doğrulandı. Açık model kalite hataları, imzalama ve fiziksel iPhone kabulü ayrıca raporlanır.

# Önceki devam doğrulaması — 16 Kasım 2026

[PR #19 ek düzeltmeler ve gerçek sonuçlar](VALIDATION_FOLLOWUP_2026_11_16.md): 114 Swift ve 41 Python/Docker testi başarılı; gerçek Qwen3-1.7B çıkarımı ağ kapalı testten geçti. 0.6B modelin Türkçe kalite hataları korunuyor ve kalite hatasında komut artık başarısız döner. iOS derlemesi hesap engeli nedeniyle doğrulanmadı.

# Güncel yerel model denetimi

En son `main` referansı `e0e710f714dd31b40f49354b6ca23fa89e86f45b` için [15 Kasım 2026 kapsamlı denetim raporu](VALIDATION_LOCAL_MODEL_2026_11_15.md) esas alınır. Aşağıdaki sonuçlar eski Alpha 0.3 kaynağına aittir; güncel iOS/Metal derlemesinin geçtiği anlamına gelmez.

# Alpha 0.3 doğrulama — 15 Kasım 2026

Doğrulanan kaynak: `8afab2a78d2ea0306616f8bae2ab13257fe2d96b`.

- [macOS ve iOS CI — başarılı](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/43696051313)
- [iPhone Release build-only — başarılı](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/43696133368)
- [Önceki Alpha 0.2 doğrulaması](VALIDATION_ALPHA_0_2.md)

## Gerçek sonuçlar

| Kontrol | Sonuç |
| --- | --- |
| Linux Swift 6.0.3 | 53 test başarılı, 0 hata |
| macOS Swift 6 / Xcode 16.4 | 59 test başarılı, 0 hata |
| Python relay | 8 test başarılı, 0 hata |
| Python release policy | 9 test başarılı, 0 hata |
| iOS simulator ve iPhone SDK Debug | BUILD SUCCEEDED |
| iOS hosted birim/entegrasyon | 60 başarılı, 1 donanım testi atlandı, 0 hata |
| iOS UI smoke | 1 başarılı, 0 hata; 74.166 saniye |
| iOS toplam | 61 başarılı, 1 atlanan, 0 hata; TEST SUCCEEDED |
| iPhone SDK Release (imzasız) | BUILD SUCCEEDED |
| Apple signing / TestFlight upload | Çalıştırılmadı; sign-and-distribute işi skipped |
| Kaynak ve shell kontrolü | git diff --check ve bash -n başarılı |

Son belgeleme commit'i yalnızca docs değiştirir; uygulama/test/workflow kaynağı yukarıdaki tam SHA'dır. Testler tekrar başarılı görünmesi için değiştirilmiş veya gerçek modelle konuşulmuş gibi sunulmamıştır. HTTP/model ve biyometri doubles açıkça test hedeflerinde bulunur.

**Atlanan tek test:** `testIOSFileProtectionSurvivesReplacement`. Simulator, host dosya sisteminde `NSFileProtectionKey` döndürmez. Fiziksel iOS'ta `.complete` kontrolü zorunlu kalır. Keychain erişim sınıfı, AES-GCM ve yeniden açma/silme testleri atlanmadı.

## Doğrulanan davranışlar

- Önceki 90 günlük konuşma, 30 günlük cevap önbelleği ve kalıcı hafıza sınırları korundu. v0/v1/v2 verileri v3'e geçebilir; şifreli kişisel ve öğrenme hafızası yeniden açılır ve silinir.
- AI onayı yokken ağ çağrısı yapılmaz; yerel hafıza komutları çevrimdışı çalışır. Sağlayıcı yoksa açık hata döner, sahte yanıt arşivlenmez. HTTPS/auth/HTTP hata/redirect/boş veya bozuk yanıt testleri geçti.
- Açık geçmiş onayıyla önceki model yanıtları sınırlı bağlama girer. Onaylanmamış veya hassas öğrenme, sır desenleri ve paylaşımı kapatılmış kategorilerden türetilmiş geçmiş yanıtlar gönderilmez. Filtre kapsamlı PII tespiti değildir.
- Model metni bir eylemi çalıştırmaz veya öğrenme kaydını onaylamaz. Kaynak/model/zaman/tazelik metadata'sı kaydedilir. Doğrulanmamış ve dinamik cevaplar yeniden kullanılmaz; güvenilir statik metadata için tam 30 gün sınırı test edildi.
- Hafıza silme/düzeltme sırasında bekleyen AI yanıtı eski contextEpoch ile geri yazılamaz. İptal, cache dönüşü ve görüntüleme/TTS sınırlarında kontrol edilir.
- Öğrenme düzeltmeleri revizyon/provenance/güven arşivi tutar. Görev düzeltmesi onay öncesi kullanılmaz; onay sonrası retrieval'a girer. Silme bağlı eski iddiaları, revizyonları ve deneyimleri kaldırır. Deneyim geçmişi 90 gün, onaylı tercihler/kurallar kalıcıdır.
- Yetki kapsamı/payload eşleşmesi, tek kullanım, expiry/replay, model-origin ret, biyometri yokluğu/ret, background iptali, başarısız etki ve başarısız audit ayrımı core testlerinde doğrulandı.
- UI smoke: Türkçe onboarding → komutla kayıt → sonlandırma/yeniden açma → okuma → hassas silme onayını iptal → yeniden açmada kaydın korunması → konuşmacı doğrulamasının etkin değil gösterilmesi. Başarılı fiziksel Face ID taklidi veya üretim bypass'ı kullanılmadı. Gerçek başarılı silme ayrıca encrypted store/core testlerindedir.

## İndirilebilir kanıtlar

- [Simulator ve Debug cihaz uygulamaları + log/xcresult/screenshot ekleri](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/43696051313/artifacts/14154486443)
- [İmzasız iPhone Release uygulaması + Release logu](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/43696133368/artifacts/14154621047)

Artifact'lar 14 gün saklanır. xcresult Xcode ile açılır; screenshot'lar yalnızca sentetik test verisi içerir. İmzasız `.app` iPhone'a doğrudan kurulamaz; bu paketler IPA/TestFlight dağıtımı değildir.

## Tamamlanan kod ve açık işler

**Uygulandı:** AIProvider/HTTPS istemci ve gerçek OpenAI Responses API relay kodu; ayrı ve varsayılan kapalı veri paylaşımı; zaman/kaynak/tazelik metadata'sı; çok turlu onaylı bağlam; öğrenme revizyonları ve görev düzeltmeleri; güvenli ActionExecutor/PermissionManager; lazy cihaz içi Speech/opt-in TTS; ayrı fail-closed SpeakerSecurity; AppIcon/privacy manifest; Release build-only ve korumalı signing/upload hazırlığı.

**Henüz doğrulanmadı veya geliştirilmedi:** Canlı LLM yanıtı, üretim sunucusu, çok kullanıcılı auth, web arama/doğrulanmış güncel kaynak sağlayıcısı, gerçek konuşmacı embedding/enrollment/spoof savunması, fiziksel Speech/TTS/FaceID/DataProtection, gerçek Apple sertifikasıyla imzalama ve TestFlight. Issue #1'in imzalı beceri kataloğu ve otomatik öneri katmanları açık kalır. Model ağırlıkları yeniden eğitilmez.

**Kullanıcı/hesap sahibi adımları:**
1. [AI relay kurulumu](AI_RELAY_SERVER.md): sahibi olduğunuz HTTPS sunucusunda sağlayıcı anahtarını secret olarak tanımlayın, süreli relay erişimi verin; uygulamada açık onay ve tercihen hassas olmayan küçük bir test sorusuyla canlı bağlantıyı doğrulayın. Sağlayıcı API anahtarını mobil uygulamaya veya sohbete koymayın. Bu görevde canlı anahtar/endpoint sağlanmadı, dış model çağrısı yapılmadı.
2. [iPhone dağıtım kurulumu](IPHONE_DISTRIBUTION.md): ücretli Apple Developer üyeliği, App ID/App Store Connect kaydı, hesap sözleşmeleri, privacy metadata, korumalı GitHub environment ve sertifika/profil/API Secrets. Üyelik etkinleşmeden bayrağı açmayın. Yalnızca iPhone ile CI derlenebilir; özel anahtar/P12 hazırlığı için güvenilir Mac/cloud Mac/yetkili yönetici gerekebilir.
3. İmzalı erişim hazır olunca fiziksel cihazda Türkçe mikrofon/izin ret-kısıt/arka plan, opt-in TTS, gerçek Face ID/Touch ID, kilitli cihaz koruması ve erişilebilirlik testlerini tamamlayın. Konuşmacı tanımayı tamamlandı saymayın.

**TestFlight'a yükleme yapılmadı.** Üyelik/Secrets olmadan gerçek dağıtım denenmedi. Yeni kaynak commit'leri: [8194fe8](https://github.com/hajrovicE/JARVIS-Mobile/commit/8194fe828e8a73f24ab5a0ab44e2abe4b6569151), [8afab2a](https://github.com/hajrovicE/JARVIS-Mobile/commit/8afab2a78d2ea0306616f8bae2ab13257fe2d96b).


Sonraki sunucuya odaklı dağıtım hazırlığı ve aynı native testlerin yeni regresyon sonucu: [AI relay deployment doğrulaması](AI_RELAY_DEPLOYMENT_VALIDATION.md). Bu ek çalışma public sunucu veya gerçek model çağrısı başlatmaz.
