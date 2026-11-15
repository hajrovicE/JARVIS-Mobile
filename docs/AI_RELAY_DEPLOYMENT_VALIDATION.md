# AI relay dağıtım hazırlığı — doğrulama

Kaynak commit: `5741691089a8a3dce43bc5b4f44f2d9f193d24e0`.

[Sunucu CI](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/43699495393) başarılı. [Test logları](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/43699495393/artifacts/14156031537) 14 gün saklanır.

## Doğrulananlar
- Orijinal 8 `test_relay.py` testi değiştirilmeden korundu. Toplam 20 Python testi geçti: dosya tabanlı Secrets, eksik/çakışan/geçersiz yapılandırma, açık expiry, tek kullanıcı bearer, kayan 60/86400 saniye kota sınırları, thread atomikliği, başarısız sağlayıcı denemesi kotası ve eşzamanlılık kontrolü.
- Duplicate Authorization/Content-Length/Content-Type/Host, Transfer-Encoding ve geçersiz Content-Length reddi; X-Forwarded-For ile kota atlatılamaması doğrulandı.
- Liveness/readiness sağlayıcı çağrısı yapmaz. Yapılandırma/expiry başarısızlığında readiness 503; liveness yalnızca süreç canlılığıdır. Anahtarın OpenAI hesabında gerçekten çalıştığını kanıtlamaz.
- Üretim JSON logger'ı yalnızca time/event/code/status/duration_ms ve sunucunun ürettiği request_id alanlarını yazar. Prompt, hafıza, token/key, IP, URI/query, traceback ve ham provider exception değerlerinin bulunmadığı test edildi.
- İki Docker entegrasyon testi geçti: gerçek entrypoint'in UID 10001/salt okunur/Secrets dosya mount'u; imajda provider/client credential environment değerinin bulunmaması; ağ kapalı health/401; gerçek Caddyfile üzerinden yerel CA doğrulamalı HTTPS, 401/sentetik200/429 ve log sınırları.
- Caddyfile Docker içinde network:none ile doğrulandı. TLS testi internal Docker ağındadır; hiçbir host portu yayımlanmaz. Sertifika zinciri ve localhost hostname'i doğrulanır; TLS doğrulaması kapatılmaz. Upstream yalnızca test fixture'ıdır, provider'a erişim yoktur. Test kaynakları sonunda kaldırılır.
- Compose profili yalnızca proxy 80/443 portlarını yayınlar. Relay 8787 özel ağdadır; key/token Docker image, build argument veya Compose environment değerinde bulunmaz. Secret file path'leri runtime'a verilir.

Sunucu CI testleri: **20/20 + 2/2 başarılı, 0 atlanan, 0 hata**. Üretim relay kodu yeniden bir framework'e taşınmadı; mevcut HTTP sözleşmesi ve orijinal testler korundu.

## Mevcut uygulama regresyonu
[Swift/macOS/iOS iş akışı](https://github.com/hajrovicE/JARVIS-Mobile/actions/runs/43699495404) aynı kaynak commit'i için **başarılı** tamamlandı:
- macOS Swift 6: 59 başarılı, 0 hata.
- Simulator ve iPhone SDK Debug derlemeleri: BUILD SUCCEEDED.
- iOS hosted: 60 başarılı, 1 önceki donanım testi atlandı, 0 hata.
- UI: 1 başarılı (65.754 saniye),0 hata; toplam iOS 61 başarılı/1 atlanan; TEST SUCCEEDED.
- Mevcut release policy testleri: 9 başarılı.

Atlanan test önceki `testIOSFileProtectionSurvivesReplacement`; gerçek fiziksel iPhone gerektirir, bu görevde değiştirilmedi. Native Swift/Speech/MemoryStore kaynakları ve orijinal server/test_relay.py değiştirilmedi. Son belgeleme commit'i yalnızca docs dosyalarını değiştirir; doğrulanan kaynak yukarıdaki SHA'dır.

## Canlı bağlantı için gerekenler
1. Sahibi olduğunuz Docker/Compose çalıştırabilen Linux sunucu veya hosting hesabı ve yönetim erişimi; doğru A/AAAA kaydı verebildiğiniz alan adı/subdomain, 80/443 erişimi ve ACME yenileme e-postası.
2. OpenAI API projesi, seçilen model erişimi ve kota/bakiye; sağlayıcı API anahtarını yalnızca server Secret manager'a kaydedin. ChatGPT uygulaması aboneliği API erişim anahtarı yerine geçmez.
3. Ayrı rastgele en az 32 karakterlik kullanıcı relay token'ı, açık Unix expiry ve Secret dosyalarının host yolları/UID izinleri. iPhone'a yalnızca relay token'ı verilir; OpenAI anahtarı verilmez. Gerçek değerleri chat/issue/Git içine koymayın.
4. Gerçek domain/Secrets ile [dağıtım belgesindeki](AI_RELAY_DEPLOYMENT.md) manuel operatör adımları, HTTPS health ve kontrollü son bağlantı kabulü.

Bu görevde ücretli servis veya cloud hesabı oluşturulmadı, public dağıtım yapılmadı, ACME'den public sertifika alınmadı ve gerçek OpenAI/model çağrısı yapılmadı. Üretim domain'i ve gerçek hesap/Secrets hâlâ operatör tarafından sağlanmalıdır. Kotalar tek process/tek replica içindir ve restart'ta sıfırlanır; kalıcı bir fatura sınırı değildir. Sağlayıcı hesabındaki bütçe/uyarı/kota yönetimi ayrıca gerekir.
