# Learning Engine — ikinci aşama
Referans: [GitHub görevi #1](https://github.com/hajrovicE/JARVIS-Mobile/issues/1).

Bu aşama retrieval ve kullanıcı onaylı tercih öğrenmesinin temelidir; model ağırlıkları eğitilmez. Web, araç yürütme, beceri yükleme veya otomatik öneri üretme bağlı değildir. Görev #1 bütünüyle tamamlanmış sayılmaz.

## Veri ve kalıcılık
`LearnedMemory`: UUID, tür, konu anahtarı, metin, kaynak, createdAt, updatedAt, expiresAt, confidence, userConfirmed, sensitivity, provenance, revision ve supersededBy. `LearningProvenance` kaynak kimliği/URL'si, alınma zamanı ve açıklama içerir. `TaskExperience` eylem, yetki kapsamı, risk, sonuç, hata, geri alma, yedek referansı ve yürütme makbuzu içerir. Bu kayıtlar eylem yetkisi vermez; başarılı görev kaydı makbuz ister. Güvenilir yürütücü henüz bağlı değildir.

`LearningEngine` protokolü saf durum dönüşümleri tanımlar; `MemoryStore` sonucu mevcut şifreli dosyaya kaydeder. Şema v2, gerçek v0/v1 verisini korur ve boş öğrenme alanı ekler. Bilinmeyen sürüm veya bozuk v2 alanı hata verir. Kişisel hafızadaki mevcut doğrudan `hatırla ki` kayıtları korunur; öneriler ayrı koleksiyondadır. Export ve toplu silme iki koleksiyonu da kapsar. Arama indeksi yoktur; mevcut kayıtlar doğrudan filtrelenir, silinen veri yeniden aramada çıkmaz.

## Onay ve çelişki
Hafıza sekmesinde konu ve tercih girilip `Onaya sun` seçilir. Bütün öneriler güven puanından bağımsız olarak onay bekler. `Onayla` mevcut öneriyi onaylar; metin düzenlendiyse `Düzelt ve onayla` kullanılır. `öğrendiklerin` komutu yalnızca onaylı, geçerli, eski sürümle değiştirilmemiş kayıtları döndürür.

Konu anahtarları Türkçe küçük harfe dönüştürülür. Aynı anahtardaki çelişkili iddia normal onayla kabul edilmez; açık kullanıcı düzeltmesi önceki iddiaları devre dışı bırakır. Düzeltmenin silinmesi önceki iddiayı yeniden etkinleştirmez. Düzeltme revizyonu ve kaynak metadata'sı tutulur; tam geçmiş revizyon içerik arşivi henüz yoktur.

## Tazelik ve veri azaltma
Kaynaklı dış bilgi URL ve geçerlilik tarihi ister; süre kaynak alınma zamanından en fazla 30 gündür. Dinamik veri için daha kısa süreyi sağlayıcı seçmelidir; sağlayıcı yokken dış bilgi üretildiği iddia edilmez. Kalıcı tercihler/kurallar kendiliğinden sona ermez. Süreli öğrenme kayıtları okumada fiziksel koleksiyondan kaldırılır.

`secret` olarak işaretlenmiş öneriler reddedilir. Bu sınıflandırma bir parola/PII tespit sistemi değildir; otomatik hassas içerik çıkarımı yoktur. UI sır girilmemesini belirtir. Bütün içerik yereldir; herhangi bir AI servisine aktarılmaz. Üretim sağlayıcısı öncesinde hassas veri sınıflandırması ve bilgilendirilmiş paylaşım onayı ayrıca uygulanmalıdır.
