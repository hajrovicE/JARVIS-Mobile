# Learning Engine — Alpha 0.3
Referans: [GitHub görevi #1](https://github.com/hajrovicE/JARVIS-Mobile/issues/1).

Bu katman kullanıcı onaylı tercih/kural öğrenmesi ve retrieval uygular; model ağırlıkları eğitilmez. Model cevabı veya görev çıktısı kendi başına kişisel gerçeğe dönüşmez. Görev #1'in imzalı beceri kataloğu, otomatik öneri üretimi ve bağımsız konuşmacı doğrulaması gibi kalan alanları tamamlanmış sayılmaz.

## Mevcut veriyi koruyan şema
`LearnedMemory`: UUID, tür, konu anahtarı, metin, kaynak, createdAt, updatedAt, expiresAt, confidence, userConfirmed, sensitivity, provenance, revision, supersededBy ve isteğe bağlı `revisions`. Provenance kaynak kimliği/URL'si, alınma zamanı ve açıklama içerir.

Her açık düzeltme önceki revizyonun metin, kaynak, zaman, geçerlilik, güven, onay, hassasiyet ve provenance alanlarını düz bir `LearningRevision` dizisinde saklar. Arşiv özyinelemeli değildir; her düzeltmede bütün arşiv tekrar kopyalanmaz. Eski Alpha 0.2 kayıtlarında bu alan bulunmadığında `nil` çözülür; ilk düzeltme arşivi başlatır. Arşiv kullanıcının yerel inceleme ve export'u içindir, varsayılan AI bağlamına eklenmez.

`TaskExperience` eylem, kapsam, risk, sonuç, hata, geri alma, yedek referansı, yürütme makbuzu ve isteğe bağlı `correctionMemoryID` içerir. Başarılı görev kaydı bir makbuz ister; audit satırı tek başına işlem yetkisi veya makbuzun kriptografik doğrulaması değildir. Güvenli yürütücü izin ve gerçek sonucu ayrıca denetler.

`LearningEngine` saf durum dönüşümleri üretir; `MemoryStore` sonucu şifreli dosyaya kaydetmeden başarı bildirmez. Eski doğrudan `hatırla ki` kişisel hafızası korunur. Export ve toplu silme hem kişisel hem öğrenme koleksiyonlarını kapsar. Arama indeksi yoktur; aktif kayıtlar doğrudan filtrelenir.

## Onay, çelişki ve düzeltme
Bütün öneriler güven puanından bağımsız olarak onay bekler. Kullanıcı `Onayla` ile mevcut kalıcı metni kabul eder; metni değiştirmişse `Düzelt ve onayla` kullanır. `MemoryStore` beklenen metni kontrol eder ve eski bir önerinin başka görünen metin adına onaylanmasını engeller.

Konu anahtarları Türkçe küçük harfe dönüştürülür. Aynı anahtardaki farklı aktif iddialar normal onayla kabul edilmez; açık kullanıcı düzeltmesi önceki iddiaları devre dışı bırakır. Bu, konu anahtarına dayalı çelişki denetimidir; her doğal dil çelişkisini çözen bir semantik doğrulayıcı olduğu iddia edilmez. Sonraki retrieval, onaylı ve geçerli son kullanıcı düzeltmesini seçer. Düzeltme silindiğinde eski bilgi yeniden etkinleşmez.

`proposeTaskCorrection(experienceID:key:text:in:now:)` bir görev deneyimiyle bağlantılı, onay bekleyen `.rule` önerisi oluşturur. Bu kullanıcı geri bildirimidir; araç veya model çıktısının otomatik onayı değildir. Onaydan sonra aynı konu sorgusundaki sonraki görevlere bağlam olarak seçilebilir. Doğrulanan görev deneyimleri ve başarısızlıklar ayrı audit kayıtları olarak kalır.

## Silme ve saklama
Bir kayıt silindiğinde revizyon arşivi de gider. O kaydın yerine geçtiği eski iddialar ters `supersededBy` zincirinde kaldırılır; eski sürümler yeniden aramaya dönmez. Kayıtla bağlantılı görev düzeltme audit satırları da kaldırılır; silinen öğrenmenin kopyası görev sonucunda bırakılmaz. Bağımsız ve yeni bir doğru düzeltme, eski reddedilmiş bir iddia tek başına silindi diye kaldırılmaz.

Konuşmalar tam 90 gün, uygun cevap önbelleği en fazla 30 gün saklanır. Görev deneyimi geçmişi tam 90 günde temizlenir; bu geçmişten kullanıcının ayrıca onayladığı kişisel tercih/kural kendiliğinden sona ermez. Kaynaklı dış bilgi URL ve geçerlilik tarihi ister; süre kaynak alınma zamanından en fazla 30 gündür. Dinamik veriye daha kısa süreyi sağlayıcı vermelidir. Süreli kayıtların revizyonları da kayıt kaldırılınca gider. Kalıcı tercihler/kurallar kullanıcı silene kadar kalır.

## Hassas veri ve AI bağlamı
`secret` işaretli öneriler ve bilinen credential desenleri reddedilir. `CredentialFilter`, API key, Bearer/JWT, özel anahtar, açık parola/OTP ataması ve bazı imzalı URL kalıplarını yakalar; eşleşen içeriği loglamaz. Aynı kontrol yeni düzeltme ve görev audit alanlarında da uygulanır. Bu filtre genel PII tespiti veya içeriğin güvenli olduğunun kanıtı değildir; sınıflandırılamayan hassas bilgiler kullanıcıya aittir ve açık paylaşım onayı gerekir.

`shareableContext(query:in:now:)` yalnızca onaylı, geçerli, aktif, `ordinary` ve credential içermeyen kayıtları seçer; geçmiş revizyon metinlerini döndürmez. `sensitive` kayıtlar yerelde sorgulanabilir fakat varsayılan dış AI bağlamına girmez. Bu metodun sonucu paylaşım izni değildir: çağıran uygulama, sunucuyu ve paylaşılacak içeriği açıklayıp bilgilendirilmiş opt-in almadan veri göndermemelidir.
