# Alpha 0.3 — beta dağıtım taslağı

Bu metin yayımlanmamış bir hazırlık taslağıdır. İmzalı kurulum ve fiziksel cihaz kabulünden önce nihai sürüm notu olarak kullanılmaz.

## Kısa açıklama
JARVIS, sahibinin seçtiği GGUF modeliyle cihaz içinde sohbet, kişisel hafıza ve isteğe bağlı Türkçe sesli iletişim sunan deneysel bir asistandır.

## Bu aşamanın kapsamı
- Cihazda model çalıştırma, token akışı ve konuşmalar arasında ağırlıkların yeniden kullanımı.
- Kişisel hafıza ve öğrenme kayıtlarını görme, düzeltme, silme ve JSON dışa aktarma. Kayıtlar kullanıcı silene kadar tutulur.
- Kullanıcı tarafından başlatılan sesli giriş ve opt-in sesli yanıt. Türkçe cihaz içi Speech desteği ve iOS izinleri gerekir; yazılı giriş alternatifi vardır.
- Sahibin sistem talimatı ve üretim ayarları; doğrudan kullanıcı komutu dışında eylem yürütmeme.

## Bilinen sınırlar
Küçük yerel model yanlış bilgi, biçim hatası veya tekrar üretebilir. Tekrar katsayısı genel doğruluk garantisi değildir. Web arama, telefon sistem kontrolü ve konuşmacı biyometrisi etkin değildir. Başlangıç Qwen3-1.7B Q4_K_M dosyası yaklaşık 1,28 GB'dır; çalışma belleği ayrıca gerekir. Bu ağırlıklar henüz JARVIS'e özel eğitilmiş değildir.

## Veri akışı
Mobil sohbet soruları ve hafıza otomatik olarak bir AI sunucusuna gönderilmez. Model bağlantısı için API anahtarı gerekmez. Ses tanıma cihaz içi destek gerektirir; uzak tanımaya sessiz geçiş yapılmaz. Kişisel kayıtlar uygulama katmanında ayrıca şifrelenmeyen JSON'dur. Kullanıcının dışa aktardığı JSON kişisel veri içerebilir. Harici model indirme bağlantısının açılması ayrı bir kullanıcı işlemidir. Eski relay modülü mobil sohbet yoluna bağlı değildir.

## Hesap sahibinin tamamlayacağı alanlar
App Store Connect'teki destek iletişimi, gizlilik politikası URL'si, hesap/Bundle ID kaydı, tester bilgileri ve ihracat sorularının yanıtı hesap sahibine aittir; burada uydurma bilgi verilmez. Gerçek dağıtımdan önce bu taslak, uygulamanın son davranışı ve Apple'ın geçerli kurallarıyla gözden geçirilir.

Test planı: [imza öncesi hazırlık](PRE_SIGN_READINESS.md). Hesap/Secrets kurulumu: [iPhone dağıtımı](IPHONE_DISTRIBUTION.md). Gerçek test sonuçları PR #20 ve doğrulama raporlarında tutulur.
