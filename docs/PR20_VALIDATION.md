# PR #20 doğrulaması — 17 Kasım 2026

Dal: `feature/fast-natural-offline-conversation-20261116`. Başlangıç: `70b8f7ec2aba73b80ed5b687e16bc4a5c500d2d3`; main referansı `e0e710f714dd31b40f49354b6ca23fa89e86f45b`. #19'un `20dc342cc5fb6f65c0427f18556f3d8b0b7cf7ec` düzeltmeleri bu dalda birleştirildi. Runtime/UI/Speech çakışmaları resident model, akış ve güvenli ses turu korunarak çözüldü. Doğrulanan uygulama/test/workflow kaynağı `9aea7cc06c24463dd70207865fb22efbeb49de35`. Sonraki rapor commit’i yalnızca belgeler ve test kayıtları içerir. Ana dala birleştirme yapılmadı; açık model kalite hataları ve gerçek cihaz kabulü simulator testinden ayrıdır.

## Başarılı

| Kontrol | Sonuç |
| --- | --- |
| Linux Swift 6.0.3 Core | **173 test, 0 hata**; ayrıca 4 worker ile paralel koşu başarılı |
| macOS Core (9aea7cc) | **175 test, 0 hata**, yeni hafıza regresyonları dahil |
| iOS hosted testler (9aea7cc) | **190 test, 0 hata, 0 atlama**; gerçek GGUF zorunlu |
| iOS UI (9aea7cc) | **3 test, 0 hata, 0 atlama** |
| Simulator uygulama derlemesi (9aea7cc) | **BUILD SUCCEEDED**, gerçek kaynak derlemeli CPU native slice |
| iPhone SDK Debug / Release (9aea7cc) | **BUILD SUCCEEDED**, imzasız |
| Python relay | **22 test, 0 hata**; sağlayıcı çağrısı sentetik |
| Python release | **11 test, 0 hata**; gerçek Apple Secrets yok |
| Python model/routing | **8 test, 0 hata** |
| Docker/gerçek yerel HTTPS | **2 test, 0 hata**; private Secrets mount, auth, 429, health, günlük kontrolü |
| Gerçek native Swift + GGUF | **Exit 0**, uygulamadaki aynı çalışma motoru, ağ kapalı Docker |
| Sözdizimi/YAML/shell/whitespace | Kontrol edildi; Xcode derlemesi yerine geçmez |

Kanıtlar: [Core](validation-artifacts/pr20-2026-11-17/core-swift6.log), [paralel Core](validation-artifacts/pr20-2026-11-17/core-swift6-parallel.log), [relay](validation-artifacts/pr20-2026-11-17/python-server.log), [release](validation-artifacts/pr20-2026-11-17/python-release.log), [model](validation-artifacts/pr20-2026-11-17/python-model.log), [Docker](validation-artifacts/pr20-2026-11-17/deployment-smoke.log), [gerçek çıkarım ve performans](validation-artifacts/pr20-2026-11-17/real-native-performance.log). [GitHub Linux Core özeti](validation-artifacts/pr20-2026-11-17/github-linux-core-excerpt.log) ayrıca son kaynakta 173 testi doğrular. İlk bağlantılar yerel geliştirme ortamının kayıtlarıdır; GitHub macOS koşusu değildir. Model/ses protocol fixture'ları yalnızca birim testlerindedir. Gerçek model testi sabit cevap veya ağ AI'sı kullanmaz.

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

GitHub Ubuntu CPU koşusu `9aea7cc` ayrıca [gerçek native kontrolü geçti](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44022073158/job/133833642325). [Son ham kayıt](validation-artifacts/pr20-2026-11-17/github-real-native-final-excerpt.log): aynı promptta cold/warm ilk token **4,521 / 1,448 sn**, yükleme **3,069 / 0,000039 sn**, decode **25,45 / 25,46 token/sn**, toplam **5,032 / 1,959 sn**, load count **1 / 1**, RSS yaklaşık **2,02 GiB**. İlk cümle **4,314 sn**, üretimin bitmesi **4,866 sn**. Runner CPU/paylaşım farkları gecikme ve decode hızını değiştirir; bu veriler arası hız farkı kod optimizasyonuna bağlanmaz. Bu ayrı runner ölçümü önceki Docker ölçümünün yerine yazılmaz; iPhone/Metal sonucu değildir.

## Başarısız gözlemler ve düzeltmeler

İlk Core koşusunda Swift 6 XCTest Sendable uyumsuzluğu, eski test argument sırası ve tarihsel soru eşleştirmesi düzeltildi. Yeni bağlam sözleşmesinde normal sorulara tüm ilgisiz hafızayı gönderme beklentisi yerine, açık owner isteğinde bütün kayıtların eksiksiz seçildiği test edildi. Gizlilik kategorisinin görev-deneyimi → yanıt → takip yanıtı boyunca kaybolması düzeltildi ve regresyon eklendi. Son Core koşusu yeşildir. Eski takip yanıtlarının kaynak zinciri de kontrol edilir: silinen kaynak veya yeni bir düzeltme eski iddiayı geri getiremez. Sonraki macOS koşusunda Python 3.15 urllib istemcisi, erken 411 reddi sırasında ayrı chunk gövdesi yazarken BrokenPipe üretti. Başarısız koşu [44019629466](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44019629466) olarak kalır. Test ham HTTP isteğini tek gönderimde kuracak şekilde düzeltildi; hem yalnız chunked hem çelişkili chunked/Content-Length için gerçek 411 ve sağlayıcıya ulaşmama korunur. Ağ kapalı Python 3.15 Docker koşusunda relay 22 test geçti. Bu test istemcisi yarışını düzeltir; sunucu reddi gevşetilmez. Kişisel düzenleme tarihi isteğe bağlı `updatedAt` alanıyla kalır; eski JSON/AES kayıtlarında alanın bulunmaması geçerlidir. Kimlik, oluşturulma tarihi ve sahibin arşivi korunur; yeni metin sonraki ilgili bağlama girer.

Model kalitesinde açık kalan gerçek örnek: üç kısa cümle istendiğinde model tek, doğal olmayan cümle üretti; bu denemenin erken-TTS beklentisi başarısız oldu. [Kayıt](validation-artifacts/pr20-2026-11-17/model-instruction-failure.log). Son iki cümleli akış kabul denemesinde model metni tekrar da üretti; çıktı başarılı performans kaydında satır sonları/boşluklar kaybolmadan JSON kaçışlarıyla korunmuştur. Uygulama çift final transkripti veya final yanıtın ikinci kez kuyruğa eklenmesini engeller, fakat modelin kendi ürettiği her anlamsal tekrarı düzelttiği iddia edilmez. Başkent ve kişisel hafıza örneklerinin doğru olması genel doğruluk/çok adımlı muhakeme garantisi değildir. Önceki 0.6B Q4/Q8 yanlış cevapları #19 kayıtlarında durur; model eğitilmedi.

Ek gerçek çok adımlı Türkçe kalite denemesi: “Önce 17 çarpı 23 … Sonra 20 eksi 7 … ayrı bir cümlede” sorusunda **391** ve **13** doğrudur; model iki cümle yerine noktalamasız Markdown blokları verdi. Güvenilir cümle üretim bitmeden oluşmadığı için erken-TTS kabulü **exit 1** ile başarısızdır. Uygulama runtime dosyası harness kopyasıyla `cmp` eşleştirilmiştir; ses bölücü kaynağı aynı kalmıştır. [Ham çıktı ve değerlendirme](validation-artifacts/pr20-2026-11-17/multistep-math-quality-failure.json). Bu dar aritmetik örneği genel doğruluk garantisi değildir; başarısız biçim/erken-TTS sonucu başarıya çevrilmedi.

## Apple CI, atlanan ve ayrı cihaz gerektiren kontroller

- Son `9aea7cc` Apple koşusu: **tamamlandı; 175 macOS Core, 190 iOS hosted ve 3 UI, 0 hata / 0 atlama**. [Son ham Apple özeti](validation-artifacts/pr20-2026-11-17/github-ios-final-excerpt.log). Önceki `09ef15a` hosted 186/UI 3 koşusu da başarılıydı; [önceki kayıt](validation-artifacts/pr20-2026-11-17/github-ios-baseline-excerpt.log) korunur.
- Fiziksel iPhone Metal, canlı Türkçe STT/TTS/ilk duyulur ses, gerçek izin diyalogları, termal baskı, bellek uyarısı/sonlandırma, uzun konuşma, kilit/arka plan ve VoiceOver: **AYRICA DOĞRULANMADI**.
- Apple signing ve TestFlight: çalıştırılmadı; `build-only` koşusunda `sign-and-distribute` **skipped**. Ücretli servis veya hesap açılmadı.

`runner_id=0, steps=[]` önceki koşularda hesap engeliydi: eski macOS/Linux işleri açıkça failed payment/spending limit annotation'ı verdi. 17 Kasım yeni koşuları **başladı**. Ödeme/harcama ayarı değiştirilmedi. İlk macOS Core koşusu Foundation URL metadata önbelleğinden kaynaklanan GGUF boyut hatasını buldu. Parser açık file descriptor üzerinde fstat kullanacak şekilde düzeltildi; provider yerel bozuk dosyayı HTTPS ayarı hatası gibi raporlamaz. Ardından Xcode, pinned upstream XCFramework'de Simulator slice olmadığını gösterdi. Mevcut iPhone Metal framework korunarak aynı pinned llama.cpp commit'inden gerçek Simulator CPU framework derleme adımı eklendi; yeni Simulator ve imzasız iPhone derlemeleri geçti. Test sonrası simulator teslim kopyasından yalnızca gömülü XCTest paketi çıkarılır, simulator uygulaması ad-hoc yeniden imzalanıp doğrulanır. Böylece 1,28 GB test GGUF dosyası son kullanıcı uygulama paketine taşınmaz; orijinal test hostu ve xcresult korunur.

- [Son macOS/iOS + gerçek Linux GGUF — 9aea7cc](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44022073158)
- [Son imzasız Release — 9aea7cc, başarılı](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44022078570)
- [İndirilebilir simulator/SDK uygulamaları, log ve xcresult](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44022073158/artifacts/14302333063) — 13.317.705 byte; test GGUF dosyası teslim uygulamalarında yok. [Paket incelemesi](validation-artifacts/pr20-2026-11-17/ios-payload-metadata.json).
- [İndirilebilir imzasız Release 0.3.0 (6)](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44022078570/artifacts/14300964134). Artifact’lar 14 gün saklanır.
- [Son Linux Core — 9aea7cc, başarılı](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44022073182)
- [Son relay — 9aea7cc, başarılı](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44022073295)

Gerçek paket incelemesi ikinci bir Release sorununu yakaladı: `c3803e5` koşusunda build girdisi **5** iken Info.plist **1 / 1.0** taşıyordu. `9aea7cc`, sürüm alanlarını Xcode ayarlarına bağlar. Yeni Release **build 6 / marketing 0.3.0** olarak indirilen gerçek paketten doğrulandı; binary plist, native llama kitaplığı, iPhone SDK platformu ve test/GGUF fixture bulunmaması kontrol edildi. [Metadata kanıtı](validation-artifacts/pr20-2026-11-17/release-payload-metadata.json). `policy.py check-app` hem build-only hem archive sonrası yanlış numarayı reddeder. İki yeni regresyonla Release suite **11 test**tir; Python 3.15 ağ kapalı koşusu da geçer. Signing işi yeni yerel native bağımlılığı hazırlayacak şekilde tamamlandı; gerçek imzalı archive/export henüz denenmedi.

## Diğer açık PR'lar

| PR | İnceleme sonucu |
| --- | --- |
| #19 | Bu dala alındı; runtime/UI/Speech üç çakışması çözüldü. |
| #5 | GitHub main'e karşı conflict gösteriyor; LocalAIProvider, AssistantService, runtime, UI ve project.yml örtüşüyor. Otomatik alınmadı. |
| #8 / #9 | Main/stacked base ile conflict; öğrenme, MemoryStore, CommandRouter, LocalAIProvider örtüşüyor. Eski güvenlik/retention kararları geri getirilmedi. |
| #12 | Conflict; owner policy, service, hafıza, UI/Speech örtüşüyor. Güncel AGENTS/owner kararı korundu. |
| #21 | Main'e karşı mergeable görünse de bu PR ile runtime, UI, model manager, testler ve CI aynı dosyalara dokunuyor. Sessiz token düşürme, eski model dosyasını otomatik silme ve sideload workflow'u bu göreve taşınmadı. |

Bu inceleme diğer PR'ların testlerinin geçtiği anlamına gelmez. Gerekli testler geçmeden main'e birleştirme, gerçek cihaz hazır veya TestFlight'a yüklendi raporu verilmez.
