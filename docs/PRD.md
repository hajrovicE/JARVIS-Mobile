> Güncel sahip kararı AGENTS.md içindedir: cihaz içinde GGUF çıkarımı, kullanıcı silene kadar JSON geçmişi, ek biyometri/yetki süresi/SHA sabitlemesi yok. Aşağıdaki ilk Alpha tasarımı tarihsel bağlamdır; [güncel doğrulama](VALIDATION.md) mevcut davranışı ve gerçek test sınırlarını açıklar.

# İlk sürüm gereksinimleri
Türkçe, iPhone öncelikli, çevrimdışı kişisel asistan. Yerel komutlar: `hatırla ki …`, `ne hatırlıyorsun`, `unut <UUID>`, `geçmiş`.

Konuşmalar oluşturulmalarından tam 90×86400 saniye sonra, cevap önbelleği tam 30×86400 saniye sonra geçersiz olur. Zamana duyarlı sorular önbellekten yanıtlanmaz. Kişisel hafıza otomatik sona ermez; kullanıcı düzenler, siler veya JSON dışa aktarır.

Sesli giriş isteğe bağlı; Türkçe cihaz içi Speech desteği olmayan cihazlarda metin kullanılır. Sesli yanıt varsayılan kapalıdır. AI varsayılan kapalıdır; yalnızca açık kullanıcı onayıyla yapılandırılmış aracı servis/model sağlayıcısına metin ve ayrı seçilmiş bağlam gönderilebilir. Hoparlör kimlik doğrulaması, web arama ve sistem kontrolü yoktur; AI bağlantısı için kullanıcının sunucusu/erişim bilgisi gerekir.

Alpha0.3 ayrıntıları ve gerçek bağlantı sınırları docs/ALPHA_0_3.md içinde; konuşmacı doğrulaması tamamlandı sayılmaz.
