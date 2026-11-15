# Konuşmacı güvenliği — Alpha 0.3

`SpeechController` yalnızca Türkçe konuşmayı metne çevirir ve kullanıcının TTS tercihi açıksa cevapları seslendirir. Bu işlemler konuşmacının kimliğini kanıtlamaz.

## Eklenen yazılım sınırı
`JarvisCore/SpeakerSecurity.swift` bağımsız `SpeakerSecurity` protokolünü içerir: availability, açık rıza metadata'sıyla enroll, süreli challenge ile verify ve revokeEnrollment. Sonuç tipi bir ses eşleşmesidir; ActionExecutor/PermissionManager için onay veya cihaz biyometrisi yetkisi üretmez. Face ID/Touch ID kontrolü ayrı kalır.

Alpha 0.3'te tek hazır adaptör `UnavailableSpeakerSecurity`:
- availability her zaman açıklamalı unavailable döndürür.
- enroll ve verify `notImplemented` hatası verir; gerçek kayıt veya eşleşme iddia etmez.
- revokeEnrollment `notEnrolled` döndürür; var olmayan bir kaydın silindiğini iddia etmez.
- Ham ses örneklerini veya embedding'leri saklamaz, AI servisine göndermez.

Arayüz özelliği **ETKİN DEĞİL** olarak göstermeye devam etmelidir. Bu modül gerçek biyometrik doğrulamanın tamamlandığı anlamına gelmez.

## Sesli iletişimde güçlendirmeler
Speech/mikrofon izinleri sıralıdır; ret/kısıt/desteksiz cihaz durumunda yazılı giriş kullanılır. Tanıma yalnızca cihazda yapılır. Capture gate, bırakılmış veya iptal edilmiş bir hareketin geç izin cevabıyla mikrofon açmasını engeller; SwiftUI başlatma Task'ını bırakma/arka plan sırasında iptal etmelidir. Metin kullanımı Speech tanıyıcısı, ses motoru veya TTS nesnesini oluşturmaz.

Sesli cevap varsayılan kapalıdır; opt-in uygulama katmanındadır. Türkçe ses yoksa yazılı cevap korunur. Delegate tamamlanma/iptal bildirimleri doğru seslendirme kimliğiyle eşleştirilir; başka bir kayda geçilmişse eski bildirim ses oturumunu kapatamaz. Normal tamamlanmada audio session bırakılır; arka plan ve kesinti hem kaydı hem TTS'yi iptal eder. Uzun metinlerde en fazla ilk 4000 karakter seslendirilir ve durum mesajı bunu açıklar; tam metin ekranda kalır.

## Gerçek biyometri için açık kabul koşulları
Açık rıza ve silme akışı; rastgele meydan okuma cümleleriyle çok oturumlu kayıt; cihazda şifreli embedding; eşik kalibrasyonu; replay/sentetik ses/canlılık saldırılarına karşı değerlendirme; hız sınırı ve deneme kilidi; erişilebilir alternatif gerekir. Hassas işlemlerde ayrıca açık işlem onayı ve cihaz biyometrisi zorunludur. Biyometri kullanılamıyorsa sessiz bypass yoktur.

Türkçe, farklı aksan ve gürültü koşullarında FAR/FRR raporu; tekrar/sentetik ses saldırı testi; kayıt iptali/tüm veri silme; kilit/yeniden başlatma; hata ve erişilebilirlik testleri; onaylı eşikler ve bağımsız güvenlik incelemesi tamamlanmadan gerçek adaptör etkinleştirilemez. Canlı ses ve donanım biyometrisi simulator testiyle doğrulanmış sayılmaz.
