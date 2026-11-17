# PR #20 doğrulaması — 17 Kasım 2026

Dal: `feature/fast-natural-offline-conversation-20261116`. Başlangıç: `70b8f7ec2aba73b80ed5b687e16bc4a5c500d2d3`; main referansı `e0e710f714dd31b40f49354b6ca23fa89e86f45b`. #19'un `20dc342cc5fb6f65c0427f18556f3d8b0b7cf7ec` düzeltmeleri bu dalda birleştirildi. Runtime/UI/Speech çakışmaları resident model, akış ve güvenli ses turu korunarak çözüldü. Ana dala birleştirme yapılmadı; gerçek cihaz kabulü simulator testinden ayrıdır.

## Başarılı

| Kontrol | Sonuç |
| --- | --- |
| Linux Swift 6.0.3 Core | **173 test, 0 hata**; ayrıca 4 worker ile paralel koşu başarılı |
| macOS Core (180f14d Release koşusu) | **175 test, 0 hata**, yeni hafıza regresyonları dahil |
| iOS hosted testler (09ef15a) | **186 test, 0 hata, 0 atlama**; gerçek GGUF zorunlu |
| iOS UI (09ef15a) | **3 test, 0 hata** |
| Simulator uygulama derlemesi (09ef15a) | **BUILD SUCCEEDED**, gerçek kaynak derlemeli CPU native slice |
| iPhone SDK Debug / Release (09ef15a) | **BUILD SUCCEEDED**, imzasız |
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

GitHub Ubuntu CPU koşusu `09ef15a` ayrıca [gerçek native kontrolü geçti](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44017193034/job/133817831668). [Özet ham kayıt](validation-artifacts/pr20-2026-11-17/github-real-native-excerpt.log): aynı promptta cold/warm ilk token **2,827 / 1,164 sn**, yükleme **1,666 / 0,000039 sn**, decode **14,94 / 14,97 token/sn**, toplam **3,697 / 2,033 sn**, load count **1 / 1**, RSS yaklaşık **2,02 GiB**. İlk cümle **2,872 sn**, üretimin bitmesi **3,812 sn**. Bu ayrı runner ölçümü önceki Docker ölçümünün yerine yazılmaz; iPhone/Metal sonucu değildir.

## Başarısız gözlemler ve düzeltmeler

İlk Core koşusunda Swift 6 XCTest Sendable uyumsuzluğu, eski test argument sırası ve tarihsel soru eşleştirmesi düzeltildi. Yeni bağlam sözleşmesinde normal sorulara tüm ilgisiz hafızayı gönderme beklentisi yerine, açık owner isteğinde bütün kayıtların eksiksiz seçildiği test edildi. Gizlilik kategorisinin görev-deneyimi → yanıt → takip yanıtı boyunca kaybolması düzeltildi ve regresyon eklendi. Son Core koşusu yeşildir. Eski takip yanıtlarının kaynak zinciri de kontrol edilir: silinen kaynak veya yeni bir düzeltme eski iddiayı geri getiremez. Sonraki macOS koşusunda Python 3.15 urllib istemcisi, erken 411 reddi sırasında ayrı chunk gövdesi yazarken BrokenPipe üretti. Başarısız koşu [44019629466](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44019629466) olarak kalır. Test ham HTTP isteğini tek gönderimde kuracak şekilde düzeltildi; hem yalnız chunked hem çelişkili chunked/Content-Length için gerçek 411 ve sağlayıcıya ulaşmama korunur. Ağ kapalı Python 3.15 Docker koşusunda relay 22 test geçti. Bu test istemcisi yarışını düzeltir; sunucu reddi gevşetilmez. Kişisel düzenleme tarihi isteğe bağlı `updatedAt` alanıyla kalır; eski JSON/AES kayıtlarında alanın bulunmaması geçerlidir. Kimlik, oluşturulma tarihi ve sahibin arşivi korunur; yeni metin sonraki ilgili bağlama girer.

Model kalitesinde açık kalan gerçek örnek: üç kısa cümle istendiğinde model tek, doğal olmayan cümle üretti; bu denemenin erken-TTS beklentisi başarısız oldu. [Kayıt](validation-artifacts/pr20-2026-11-17/model-instruction-failure.log). Son iki cümleli akış kabul denemesinde model metni tekrar da üretti; çıktı başarılı performans kaydında satır sonları/boşluklar kaybolmadan JSON kaçışlarıyla korunmuştur. Uygulama çift final transkripti veya final yanıtın ikinci kez kuyruğa eklenmesini engeller, fakat modelin kendi ürettiği her anlamsal tekrarı düzelttiği iddia edilmez. Başkent ve kişisel hafıza örneklerinin doğru olması genel doğruluk/çok adımlı muhakeme garantisi değildir. Önceki 0.6B Q4/Q8 yanlış cevapları #19 kayıtlarında durur; model eğitilmedi.

## Apple CI, atlanan ve ayrı cihaz gerektiren kontroller

- `09ef15a` için macOS/iOS koşusu **tamamlandı ve başarılı**. Hosted **186** ve UI **3** test çalıştı; test atlanmadı. [Ham özet kayıt](validation-artifacts/pr20-2026-11-17/github-ios-baseline-excerpt.log). Yeni hafıza regresyonları Linux üzerinde 173, macOS Release koşusunda 175 testle doğrulandı; bu sonraki kaynak için son CI durumu PR #20 checks bölümünden izlenir.
- Fiziksel iPhone Metal, canlı Türkçe STT/TTS/ilk duyulur ses, gerçek izin diyalogları, termal baskı, bellek uyarısı/sonlandırma, uzun konuşma, kilit/arka plan ve VoiceOver: **AYRICA DOĞRULANMADI**.
- Apple signing ve TestFlight: çalıştırılmadı; `build-only` koşusunda `sign-and-distribute` **skipped**. Ücretli servis veya hesap açılmadı.

`runner_id=0, steps=[]` önceki koşularda hesap engeliydi: eski macOS/Linux işleri açıkça failed payment/spending limit annotation'ı verdi. 17 Kasım yeni koşuları **başladı**. Ödeme/harcama ayarı değiştirilmedi. İlk macOS Core koşusu Foundation URL metadata önbelleğinden kaynaklanan GGUF boyut hatasını buldu. Parser açık file descriptor üzerinde fstat kullanacak şekilde düzeltildi; provider yerel bozuk dosyayı HTTPS ayarı hatası gibi raporlamaz. Ardından Xcode, pinned upstream XCFramework'de Simulator slice olmadığını gösterdi. Mevcut iPhone Metal framework korunarak aynı pinned llama.cpp commit'inden gerçek Simulator CPU framework derleme adımı eklendi; yeni Simulator ve imzasız iPhone derlemeleri geçti. Test sonrası simulator teslim kopyasından yalnızca gömülü XCTest paketi çıkarılır, simulator uygulaması ad-hoc yeniden imzalanıp doğrulanır. Böylece 1,28 GB test GGUF dosyası son kullanıcı uygulama paketine taşınmaz; orijinal test hostu ve xcresult korunur.

- [macOS/iOS + gerçek Linux GGUF — 09ef15a](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44017193034)
- [İmzasız Release — 09ef15a, başarılı](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44017187439)
- [Linux Core — 09ef15a, başarılı](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44017192985)
- [Relay — 09ef15a, başarılı](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44017192981)

## Diğer açık PR'lar

| PR | İnceleme sonucu |
| --- | --- |
| #19 | Bu dala alındı; runtime/UI/Speech üç çakışması çözüldü. |
| #5 | GitHub main'e karşı conflict gösteriyor; LocalAIProvider, AssistantService, runtime, UI ve project.yml örtüşüyor. Otomatik alınmadı. |
| #8 / #9 | Main/stacked base ile conflict; öğrenme, MemoryStore, CommandRouter, LocalAIProvider örtüşüyor. Eski güvenlik/retention kararları geri getirilmedi. |
| #12 | Conflict; owner policy, service, hafıza, UI/Speech örtüşüyor. Güncel AGENTS/owner kararı korundu. |
| #21 | Main'e karşı mergeable görünse de bu PR ile runtime, UI, model manager, testler ve CI aynı dosyalara dokunuyor. Sessiz token düşürme, eski model dosyasını otomatik silme ve sideload workflow'u bu göreve taşınmadı. |

Bu inceleme diğer PR'ların testlerinin geçtiği anlamına gelmez. Gerekli testler geçmeden main'e birleştirme, gerçek cihaz hazır veya TestFlight'a yüklendi raporu verilmez.
