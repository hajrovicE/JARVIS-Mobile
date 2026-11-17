# İmza öncesi ek doğrulama — 17 Kasım 2026

Uygulama/test/workflow kaynağı: `810a6c10825bb566bb9ed9b4a0acae680ac38bcf`, PR #20. Sonraki rapor commit’i yalnızca belge/log içerir. Önceki [PR20 doğrulaması](PR20_VALIDATION.md) tarihsel kaynakta geçerliliğini korur.

| Kontrol | Gerçek sonuç |
| --- | --- |
| Linux Swift 6.0.3 | 178 test başarılı |
| macOS Core | 180 test başarılı |
| iOS hosted/native | 197 test başarılı, 0 hata / 0 atlama |
| iOS UI | 4 test başarılı, 0 hata / 0 atlama |
| Python relay / Release / model | 22 / 14 / 8 başarılı |
| Native gerçek GGUF | GitHub full proof başarılı; sentetik cevap yok |
| İmzasız archive | ARCHIVE SUCCEEDED, 0.3.0 (8), native llama, privacy manifest ve dSYMs doğrulandı |
| Gerçek archive sembolleri | İndirilen uygulama/dSYM LC_UUID eşleşti |
| Apple signing / TestFlight | Çalıştırılmadı; dağıtım işi skipped |

- [macOS/iOS ve gerçek GGUF](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44048851016)
- [Linux](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44048430018)
- [Relay](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44049075772)
- [İmzasız Release archive](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44048601466)
- [Uygulama, archive/dSYMs ve hazırlık JSON artifact'ı](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44048601466/artifacts/14312532963) — yaklaşık 31 MB, 14 gün saklanır. İmzalı IPA değildir.

## Değişiklik ve kanıt

Beş yeni Core regresyonu; boş satırla tamamlanmış paragrafların erken ses kuyruğuna aktarılması, tek satır/negatif sayı korunması, CRLF, Markdown vurgusu ve kod/düşünme gizliliğini sınar. Önceki noktalamasız iki-adımlı hesapta başarısız olan erken-TTS beklentisi aynı gerçek model/aynı soru ile **başarılı** oldu: ilk paragraf 17,926 sn, üretim 21,894 sn. Bu ses kuyruğuna hazır metin ölçümüdür, ilk duyulur ses değildir. Model metni hâlâ blok biçimindedir; iki cümle talimatına uyum düzelmiş sayılmaz.

Tekrar katsayısı ve penceresi sahibin ayarıdır; varsayılan 1 nötrdür. Her turun sampler durumu ayrıdır, owner prompt değiştirilmez. C sampler'ın gerçek logit değişimi ve gerçek GGUF ile per-turn ayarlar iOS testine eklenmiştir. Yeni UI testi bu ayarların relaunch sonrası korunmasını kontrol eder. **1,12 katsayıyla yapılan gerçek denemede aynı anlamsal tekrar devam etti**; ayarın sorunu tamamen çözdüğü iddia edilmez.

[Ham kayıtlar](validation-artifacts/pre-sign-2026-11-17/): yerel Core, gerçek hesap/erken ses, tekrar denemesi, GitHub native/Release log özetleri ve bağımsız archive incelemesi. Unit archive fixtures'ı açıkça sentetiktir; gerçek archive ayrıca macOS'ta oluşturulmuş ve indirilip incelenmiştir.

İlk iOS koşusunda **197 birim/native test geçti**, yeni UI testi alt kenardaki alan klavye odağı almadığı için başarısız oldu. [Başarısız koşu](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/44043143521) ve [ham hata](validation-artifacts/pre-sign-2026-11-17/initial-ui-focus-failure.log) korunur. Test alanı ortalayıp gerçek değer girişini ve relaunch sonrası aynı değeri doğrulayacak şekilde düzeltildi; doğrulama gevşetilmedi.

İkinci koşuda değer girişi geçti, ancak sayısal klavye sekme çubuğunu kapattı. [İkinci hata kaydı](validation-artifacts/pre-sign-2026-11-17/numeric-keyboard-navigation-failure.log). Model ayarlarına gerçek **Tamam** klavye düğmesi eklendi; UI testi bu düğmeyi kullanır. Son koşuda gerçek düğme, değer girişi ve relaunch kontrolü geçti: [ham iOS/UI özeti](validation-artifacts/pre-sign-2026-11-17/github-ios-final.log).

GitHub son commit için otomatik PR koşusu üretmedi; Swift/iOS ve relay mevcut feature ref üzerinde elle çalıştırıldı. GitHub `dirty` metadata’sına karşı yerel `git merge-base` main’in ata olduğunu, `git merge-tree --write-tree` ise çakışmasız birleştiğini doğruladı. Main’e yazılmadı.

## Kalanlar

Apple signing/provisioning ve App Store Connect hesap/Secrets adımları: [dağıtım](IPHONE_DISTRIBUTION.md). [Beta metni taslağı](BETA_RELEASE_NOTES_TR.md) yayımlanmamıştır. Fiziksel iPhone Metal, Türkçe canlı STT/TTS, izin diyalogları, termal/bellek davranışı, uzun konuşma ve erişilebilirlik **AYRICA DOĞRULANMADI**. [Cihaz kabul adımları](PRE_SIGN_READINESS.md). Küçük modelin genel doğruluk/tekrar sorunları açık kalır; yeni eğitim veya web/speaker biyometrisi uygulanmadı. Ana dala birleştirme yapılmadı.
