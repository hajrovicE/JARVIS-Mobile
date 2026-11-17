# İmza öncesi hazırlık

Bu aşama Apple hesabı, sertifika veya ücretli servis oluşturmaz. Tamamlanan kod, son test sayıları ve CI bağlantıları PR #20 üzerinden doğrulanır; fiziksel iPhone kabulü ayrıca gereklidir.

## Teslim

Actions → iOS Release preparation → `build-only` ve kullanılmamış build numarası seçilir. İş akışı imzasız iPhone Release **archive** oluşturur. Artifact içinde uygulama ZIP'i, `.xcarchive` ZIP'i (dSYMs dahil), `release-readiness.json` ve derleme logu bulunur. Kontrol gerçek archive/uygulama sürümünü, native llama dosyasını, gizlilik manifestini, izin açıklamalarını ve sembolleri inceler. Test GGUF dosyaları ve XCTest paketleri teslimata girmez. İmzasız archive veya uygulama iPhone'a doğrudan kurulamaz; imzalı IPA olarak sunulmaz.

İmza geldiğinde mevcut korumalı iş akışı aynı kaynakta signed archive üretir; imzasız dosyayı yüklenebilir gibi yeniden adlandırmak yeterli değildir. Hesap ve Secrets adımları [dağıtım belgesindedir](IPHONE_DISTRIBUTION.md).

## Ses ve model ayarları

Tamamlanan cümle yanında boş satırla biten paragraflar da üretim sürerken seslendirme kuyruğuna girer. Tek satır sonu, yarım sayı, kod veya düşünme bloğu bu tetikleyici değildir. Markdown vurgusu yalnızca ses metninden çıkarılır; görünen/kaydedilen model cevabı değiştirilmez.

Tekrar katsayısı varsayılan **1**: önceki örnekleme korunur. Kullanıcı daha büyük değer deneyebilir; doğru alıntı ve tekrar isteklerini de etkileyebilir. Pencere 0 ise kapalıdır; en fazla etkin bağlam uzunluğu kadar uygulanır. Her turda yeni sampler kullanılır; önceki konuşmanın tekrar durumu sonraki tura taşınmaz. Bu ayar doğruluk garantisi veya özel model eğitimi değildir.

## İmzadan sonra iPhone kabulü

1. Temiz kurulum, Türkçe onboarding; ses seçeneklerini açınca mikrofonun kendiliğinden başlamaması.
2. Safari üzerinden model dosyasını indirip Dosyalar'dan içe aktarma; iptal/bozuk dosyada eski modelin korunması.
3. Uçak modunda gerçek sohbet, ekranda akış, ikinci tur yükleme sayısı, ilk görünür metin ve token/sn ölçümü.
4. Türkçe Speech/mikrofon kabul, ret ve Ayarlar'dan iptal; destek yoksa yazılı giriş. Bir finalin yalnız bir kez gönderilmesi.
5. TTS, durdurma, kullanıcı tarafından başlatılan kesintisiz sohbet, kesinti/arka plan/yeniden başlatma; eski callback'in mikrofon açmaması.
6. Hafıza kaydet/düzelt/sil/export; uygulamayı kapatıp açma, yanlış kaydın sonraki bağlama dönmemesi.
7. Uzun sohbet, düşük bellek, termal durum, VoiceOver ve yazı boyutu. Sonuçları gerçek cihaz modeli/iOS/model/ayarlarla kaydetme; ham kişisel konuşma veya ses yüklememe.

Bunlar kabul adımlarıdır; tamamlanmış fiziksel test sonucu değildir. Konuşmacı biyometrisi, web araması ve telefon kontrolü etkin değildir. Yerel sohbet için dış AI hesabı/API anahtarı gerekmez.
