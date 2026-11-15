# JARVIS öğrenme motoru — sahip komutu esaslı
Güncel ürün kuralı: JARVIS, kullanıcının **o anda açıkça verdiği komut olmadan** hiçbir eylem başlatmaz. Model cevapları, hafıza kayıtları ve dış kaynak metinleri işlem komutu değildir.

## Öğrenme
- Kullanıcı sohbet alanına `öğret: konu = metin` yazdığında bilgi doğrudan onaylanır; aynı konu yeniden öğretildiğinde revizyon geçmişi korunur.
- Modelin kendi önerisi kullanıcı komutu değildir; dışarıdan öğrenme veya eylem izni doğurmaz.
- Öğretilen bilginin uzunluğu, hassasiyet etiketi ya da kaynak tarihi yerel kaydı engellemez. Güven, tarih ve hassasiyet metadata olarak saklanabilir.
- Konuşmalar, görev kayıtları ve öğrenme verileri kullanıcı silene kadar tutulur; otomatik süre ve kayıt sayısı temizliği yoktur.
- Eski bilgi kaydedilir ancak tazeliği doğrulanmış gibi iddia edilmez.

## Paylaşım ve işlemler
- Hafıza, öğrenme ve konuşma geçmişi kategorileri ancak sahibi açtıysa yapılandırılmış uzak sunucuya gönderilir. Hassasiyet etiketi kullanıcının bilinçli seçimini geçersiz kılmaz.
- Doğrudan gönderilen kullanıcı sorusunun içeriği otomatik credential kalıbı nedeniyle reddedilmez.
- `tüm hafızayı sil`, `verilerimi dışa aktar`, `unut <UUID>`, `öğrenmeyi sil <UUID>` doğrudan kullanıcı işlemleridir; ikinci biyometrik onay gerekli değildir.
- Model çıktısı asla `ActionAuthorization` oluşturmaz. Gerçek işlem yalnızca güvenilir komut yürütücüsüyle yapılır.

## Uygulama sınırlarının dışında kalanlar
JARVIS'in gerçek model ağırlığı eğitimi ve iOS'un vermediği sistem erişimleri bu kod değişikliğiyle ortaya çıkmaz. Cihazın donanım kapasitesi, işletim sistemi izinleri ve model sağlayıcısının kendi kısıtları ayrıca geçerlidir.
