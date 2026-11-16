# PR #19 devam doğrulaması — 16 Kasım 2026

Kaynak başlangıcı: `be6f00f57c649c00f3fcb8f55b929d1c7b7fa97f`, dal `fix/comprehensive-local-model-validation-20261115`. `main` hâlâ `e0e710f714dd31b40f49354b6ca23fa89e86f45b`; başka özellik dalları izinsiz birleştirilmedi. [PR #19](https://github.com/hajrovicE/JARVIS-Mobile/pull/19) gerekli kontroller geçmeden birleştirilmez.

## Ek düzeltmeler

- Yanıt beklerken yeni yazılan veya konuşulan taslak, önceki yanıt tamamlanınca siliniyordu. `ChatDraft` gönderim sürümünü izler; yalnızca aynı, düzenlenmemiş taslağı temizler. Aynı metnin yeniden yazılması ve gecikmiş/tekrarlanan tamamlanmalar da yeni taslağı silemez. Beş çekirdek regresyon testi gerçek SwiftUI bağlamasında kullanılan bu bileşeni sınar.
- Yeni ses oturumu izin beklerken eski transkript duruyordu; bırakma/durdurma eski komutu tekrar girişe kopyalayabiliyordu. Oturum başlangıcında transkript temizlenir, yalnızca yeni ve boş olmayan değişiklikler aktarılır. iOS mikrofon/Speech izin akışı korunur.
- `cancel()` gecikmiş TTS olayını geçersiz kıldıktan sonra eski “seslendiriliyor” durumunu bırakıyordu. Sesli giriş/çıkış durdurulunca durum eşzamanlı güncellenir; yinelenen iptal durumunu bozmaz. Gerçek hosted controller testi eklendi; Türkçe TTS cihazda başlayamazsa açıkça XCTSkip yapar. Bu iOS testi henüz çalıştırılmadı.
- Bilinen quant türlerinde eksik son tensor, yapısal kontrolde tek byte yeterli sayıldığı için model değiştirmenin ön kontrolünü geçebiliyordu. Pinned ggml biçiminden 12 yaygın türün blok/satır/payload boyutu ve taşmaları kontrol edilir. Bilinmeyen yeni türler native motora bırakılır; mimari/model allowlist'i veya SHA sabitlemesi eklenmez. Dört regresyon testi eksik dosyanın kurulu modeli değiştiremediğini de sınar.
- Gerçek çıkarım testi `MODEL_QUALITY_FAIL` yazmasına rağmen sıfır çıkış kodu veriyordu. Artık fonksiyonel çıkarım kontrolleri ayrı gösterilir; yanlış Türkçe kalite cevabı **komutu exit 1 ile başarısız yapar**. Yanlış cevap veren modelle genel yeşil CI sonucu verilmez.

## Sonuçlar

| Kontrol | Gerçek sonuç |
| --- | --- |
| Swift 6.0.3 Linux | **114 test başarılı**, 0 hata; mevcut testler korundu |
| Swift iOS sözdizimi ve diff | Başarılı; Apple SDK typecheck/derleme yerine geçmez |
| Gerçek GGUF/CPU, Qwen3-1.7B Q4_K_M | Ağ kapalı Docker içinde gerçek import/değişim, bozuk dosya reddi, uzun sistem metni, ayarlar, yerel hafıza ve JSON yeniden açma geçti; **exit 0** |
| Türkçe kabul denemesi, 1.7B | **Başarılı**: Ankara; kişisel bağlamlı soru da Ankara. Genel doğruluk garantisi değildir |
| Türkçe kabul denemesi, 0.6B Q4_0/Q8_0 | **Başarısız**; yanlış cevaplar ve Q4 için exit 1 kaydı korundu |
| GitHub macOS/iOS CI | Yeniden istendi; ödeme/harcama limiti nedeniyle adımlar başlamadı |

[Swift test kaydı](validation-artifacts/2026-11-16/swift-tests.log), [başarılı 1.7B ağ kapalı gerçek çıkarım](validation-artifacts/2026-11-16/real-runtime-qwen17-network-none.log), [başarısız 0.6B kalite kapısı](validation-artifacts/2026-11-16/real-runtime-network-none.log). Güncel kaynakta 41 Python/Docker testi yeniden çalıştırıldı ve geçti: [sunucu 22](validation-artifacts/2026-11-16/python-server.log), [Release 9](validation-artifacts/2026-11-16/python-release.log), [model/routing 8](validation-artifacts/2026-11-16/python-model.log), [Docker/HTTPS 2](validation-artifacts/2026-11-16/deployment-smoke.log). Önceki kanıtlar [ilk rapordadır](VALIDATION_LOCAL_MODEL_2026_11_15.md).

## Yanlış cevabın kök nedeni

Aynı gerçek `Qwen3-0.6B-Q4_0` modeli ve ayarlar, bağımsız C++ kontrolünde resmi `llama_batch_get_one` decode döngüsüyle de sınandı. Tam üretim promptu **74 token** oldu ve Swift'teki gibi **İstanbul** üretti. Basit Türkçe sistem talimatıyla **Bursa**, sistem talimatı olmadan Türkçe soruda **İzmir** dedi. İngilizce kontrolde **Ankara** yanıtını verdi.

Aynı revision'ın 804.753.632 byte Q8_0 dosyası da aynı bağımsız C++ kontrolünde denendi: üç Türkçe soruda İstanbul, İngilizce soruda Ankara üretti. [Q8 karşılaştırma kaydı](validation-artifacts/2026-11-16/native-q8-comparison.log). Yalnızca nicemleme hassasiyetini artırmak bu hatayı gidermedi.

Bu karşılaştırma Swift batch/şablon aktarımını yanlış cevabın kaynağı olarak göstermiyor; küçük test modelinin Türkçe bilgi doğruluğunun yetersizliğini ortaya koyuyor. Ardından ürün belgesinde zaten başlangıç modeli olarak belirtilen Apache-2.0 Qwen3-1.7B-Q4_K_M denendi (revision `daeb8e2d528a760970442092f6bf1e55c3b659eb`, 1.282.439.264 byte). Bağımsız C++ kontrolünde üç Türkçe varyant ve İngilizce kontrolün tamamı Ankara cevabı verdi: [1.7B karşılaştırma kaydı](validation-artifacts/2026-11-16/native-qwen17-comparison.log). Üretim Swift motoruyla daha sonra ağ kapalı tam test de exit 0 ile geçti. Geçici model kopyaları 3 GB container tmpfs üzerinde tutulup silindi; ağırlıklar Git'e alınmadı. CI test ağırlığı bu modele güncellendi; uygulamanın sahibinin etkin model seçimi veya prompt/ayarları değiştirilmedi. Bu küçük kabul denemesi genel doğruluk veya çok adımlı muhakeme garantisi değildir. Sahibin sistem metni değiştirilmedi, harici AI API'si kullanılmadı, yanlış cevabı gizleyecek sabit yanıt eklenmedi.

[Native karşılaştırma kaydı](validation-artifacts/2026-11-16/native-comparison.log), [tekrar üretilebilir kontrol kaynağı](../scripts/model/native_comparison.cpp). Mevcut `verify_runtime.sh` scratch dizinindeki pinned llama.cpp header ve shared library ile kontrol kaynağı derlenebilir:

```sh
c++ -std=c++17 scripts/model/native_comparison.cpp \
  -I "$TASK_WORK/llama.cpp/include" -I "$TASK_WORK/llama.cpp/ggml/include" \
  -L "$TASK_WORK/llama-build/bin" -Wl,-rpath,"$TASK_WORK/llama-build/bin" \
  -lllama -o "$TASK_WORK/native-comparison"
"$TASK_WORK/native-comparison" "$TASK_WORK/qwen3-1.7b-q4_k_m.gguf"
```

## Kalan engeller

[Swift/iOS koşusu](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/43726767457) tekrar çalıştırıldı. GitHub “recent account payments have failed or your spending limit needs to be increased” hatasıyla işleri başlatmıyor. Hesap sahibi [GitHub Billing & plans](https://github.com/settings/billing) engelini kaldırmalıdır; kod veya test değiştirmek bu hesap engelini çözmez. Ücretli hizmet başlatılmadı, ödeme/harcama ayarları değiştirilmedi.

Xcode simulator/iPhone SDK, hosted iOS geçiş/izin/TTS ve UI testleri geçmedi. Fiziksel iPhone Metal, canlı Türkçe Speech/TTS ve izin diyalogları **AYRICA DOĞRULANMADI**. İmzalı uygulama/TestFlight yüklemesi yoktur. Gerçek konuşmacı doğrulaması, genel telefon kontrolü, web doğrulama ve imzalı beceri yükleme hâlâ tamamlanmış özellikler değildir.
