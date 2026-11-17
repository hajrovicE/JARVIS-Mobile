# PR #20 doğrulaması — 17 Kasım 2026

Dal: `feature/fast-natural-offline-conversation-20261116`. Başlangıç: `70b8f7ec2aba73b80ed5b687e16bc4a5c500d2d3`; main referansı `e0e710f714dd31b40f49354b6ca23fa89e86f45b`. #19'un `20dc342cc5fb6f65c0427f18556f3d8b0b7cf7ec` düzeltmeleri bu dalda birleştirildi. Runtime/UI/Speech çakışmaları resident model, akış ve güvenli ses turu korunarak çözüldü. Ana dala birleştirme yapılmaz: gerekli Apple testleri henüz geçmedi.

## Başarılı

| Kontrol | Sonuç |
| --- | --- |
| Linux Swift 6.0.3 Core | **167 test, 0 hata**; ayrıca 4 worker ile paralel koşu başarılı |
| Python relay | **22 test, 0 hata**; sağlayıcı çağrısı sentetik |
| Python release | **9 test, 0 hata**; gerçek Apple Secrets yok |
| Python model/routing | **8 test, 0 hata** |
| Docker/gerçek yerel HTTPS | **2 test, 0 hata**; private Secrets mount, auth, 429, health, günlük kontrolü |
| Gerçek native Swift + GGUF | **Exit 0**, uygulamadaki aynı çalışma motoru, ağ kapalı Docker |
| Sözdizimi/YAML/shell/whitespace | Kontrol edildi; Xcode derlemesi yerine geçmez |

Kanıtlar: [Core](validation-artifacts/pr20-2026-11-17/core-swift6.log), [paralel Core](validation-artifacts/pr20-2026-11-17/core-swift6-parallel.log), [relay](validation-artifacts/pr20-2026-11-17/python-server.log), [release](validation-artifacts/pr20-2026-11-17/python-release.log), [model](validation-artifacts/pr20-2026-11-17/python-model.log), [Docker](validation-artifacts/pr20-2026-11-17/deployment-smoke.log), [gerçek çıkarım ve performans](validation-artifacts/pr20-2026-11-17/real-native-performance.log). Bunlar yerel geliştirme ortamının kayıtlarıdır; GitHub macOS koşusu değildir. Model/ses protocol fixture'ları yalnızca birim testlerindedir. Gerçek model testi sabit cevap veya ağ AI'sı kullanmaz.

Gerçek test: Apache-2.0 Qwen3-1.7B Q4_K_M, 1.282.439.264 byte, revision `daeb8e2d528a760970442092f6bf1e55c3b659eb`; pinned llama.cpp b10549 (`b2e5e9b28b2484fbf94b543432ece638996a8b97`). Swift kaynak kopyası `cmp` ile uygulama dosyasıyla eşleştirildi. Docker `--network none --read-only`, geçici importlar için 3 GiB tmpfs kullanıldı. Ağırlıklar Git'e alınmadı. Gerçek doğrulananlar:

- Soğuk/sıcak model; ikinci turda load count hâlâ 1, turlar arasında KV verisi taşınmıyor.
- 14 gerçek callback; ilk callback son cevaptan önce geldi, Türkçe/Unicode çıktı final metinle eşleşti.
- İlk delta sonrası Task.cancel, çakışan üretim reddi, aktif turun ayar snapshot'ı, callback sırasında unload ve güvenli yeniden yükleme.
- 1220-token owner prompt, çoklu prefill, tam owner sistem metni, örnekleme/thread/token/context ayarları.
- Gerçek GGUF import/değişim, bozuk dosyada koruma, boyut/mtime korunmuş atomik değişimde eski ağırlığı kullanmama.
- AssistantService + kişisel bağlam + JSON yeniden açma; gerçek cevap Ankara.
- İki cümleli deneyde ilk güvenilir cümle üretim bitmeden ses kuyruğuna hazır oldu. Bu **ses başlangıcı ölçümü değildir**; Linux'ta AVSpeechSynthesizer çalıştırılmadı.

## Ölçülen CPU performansı

Aynı kısa prompt, greedy, 2 CPU thread, context 1024, en fazla 48 yeni token; tek paylaşımlı Linux x86_64 ortamı koşusu. iPhone/Metal karşılaştırması veya mutlak gecikme garantisi değildir.

| Ölçüm | Soğuk | Sıcak |
| --- | ---: | ---: |
| Model yükleme | 3,365 sn | 0,000293 sn |
| İlk model tokenı | 7,148 sn | 3,497 sn |
| Toplam | 9,067 sn | 5,989 sn |
| Decode hızı | 6,78 token/sn | 5,22 token/sn |
| Süreç RSS | yaklaşık 2,01 GiB | yaklaşık 2,01 GiB |
| Model yükleme sayısı | 1 | 1 |

Sıcak token akışı 3,497 sn'de başladı ve yaklaşık 2,344 sn boyunca devam etti. Ayrı hızlı-mod cümle deneyinde ilk cümle **6,435 sn**, modelin tamamlanması **8,636 sn**. Termal başlangıç/son `null`: Linux burada Apple termal durumunu sağlamıyor. Termal performans ölçülmüş sayılmaz. Decode hızı sıcak koşuda artmadı; görülen iyileşme yeniden model yüklemeyi kaldırmaktır. Sonuçlar çalıştırmalar arasında değişebilir.

## Başarısız gözlemler ve düzeltmeler

İlk Core koşusunda Swift 6 XCTest Sendable uyumsuzluğu, eski test argument sırası ve tarihsel soru eşleştirmesi düzeltildi. Yeni bağlam sözleşmesinde normal sorulara tüm ilgisiz hafızayı gönderme beklentisi yerine, açık owner isteğinde bütün kayıtların eksiksiz seçildiği test edildi. Gizlilik kategorisinin görev-deneyimi → yanıt → takip yanıtı boyunca kaybolması düzeltildi ve regresyon eklendi. Son Core koşusu yeşildir.

Model kalitesinde açık kalan gerçek örnek: üç kısa cümle istendiğinde model tek, doğal olmayan cümle üretti; bu denemenin erken-TTS beklentisi başarısız oldu. [Kayıt](validation-artifacts/pr20-2026-11-17/model-instruction-failure.log). Son iki cümleli akış kabul denemesinde model metni tekrar da üretti; ham çıktı başarılı performans kaydında korunmuştur. Uygulama çift final transkripti veya final yanıtın ikinci kez kuyruğa eklenmesini engeller, fakat modelin kendi ürettiği her anlamsal tekrarı düzelttiği iddia edilmez. Başkent ve kişisel hafıza örneklerinin doğru olması genel doğruluk/çok adımlı muhakeme garantisi değildir. Önceki 0.6B Q4/Q8 yanlış cevapları #19 kayıtlarında durur; model eğitilmedi.

## Çalıştırılamayan / ayrı cihaz gerektiren

- macOS Swift 6, iOS Simulator build/hosted unit, UI ve unsigned iPhone SDK derlemesi: GitHub runner başlamadığı için **çalıştırılamadı**.
- Hosted testlerde gerçek GGUF zorunludur; fixture yoksa CI hata verir. Apple AES/Keychain geçişi, gerçek controller TTS, native streaming ve UI testleri hazırdır; Linux'ta çalışmış sayılmaz.
- Fiziksel iPhone Metal, canlı Türkçe STT/TTS/ilk duyulur ses, gerçek izin diyalogları, termal baskı, bellek uyarısı/sonlandırma, uzun konuşma, kilit/arka plan ve VoiceOver: **AYRICA DOĞRULANMADI**.
- Apple signing ve TestFlight: çalıştırılmadı. Ücretli servis veya hesap açılmadı.

`runner_id=0, steps=[]` tek başına derleyici hatası değildir. [Eski macOS işi](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/43810721031) ve [Linux işi](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/43810721038) GitHub annotation'ında açıkça “recent account payments have failed or your spending limit needs to be increased” diyor. Hesap sahibi **Billing & plans** engelini kaldırmalı, ardından bu PR'ın tam SHA'sında macOS/iOS/Linux ve build-only Release işlerini yeniden çalıştırmalıdır. Ödeme/harcama ayarı değiştirilmedi. İmzalı cihaz kabulü ayrıca uygun Apple hesabı/sertifika ve cihaz gerektirir.

## Diğer açık PR'lar

| PR | İnceleme sonucu |
| --- | --- |
| #19 | Bu dala alındı; runtime/UI/Speech üç çakışması çözüldü. |
| #5 | GitHub main'e karşı conflict gösteriyor; LocalAIProvider, AssistantService, runtime, UI ve project.yml örtüşüyor. Otomatik alınmadı. |
| #8 / #9 | Main/stacked base ile conflict; öğrenme, MemoryStore, CommandRouter, LocalAIProvider örtüşüyor. Eski güvenlik/retention kararları geri getirilmedi. |
| #12 | Conflict; owner policy, service, hafıza, UI/Speech örtüşüyor. Güncel AGENTS/owner kararı korundu. |
| #21 | Main'e karşı mergeable görünse de bu PR ile runtime, UI, model manager, testler ve CI aynı dosyalara dokunuyor. Sessiz token düşürme, eski model dosyasını otomatik silme ve sideload workflow'u bu göreve taşınmadı. |

Bu inceleme diğer PR'ların testlerinin geçtiği anlamına gelmez. Gerekli testler geçmeden main'e birleştirme, gerçek cihaz hazır veya TestFlight'a yüklendi raporu verilmez.
