# JARVIS kullanıcı komutuyla eylem yürütme

**Birincil kural:** JARVIS, güvenilir kullanıcı arayüzünden doğrudan bir komut gelmedikçe telefon, dosya, hesap veya dış dünya üzerinde işlem başlatamaz. Bir model önerisi, model cevabı, alıntı ya da hafıza içeriği doğrudan komut sayılmaz.

Kullanıcı, uygulama üzerindeki bir işlem butonuna bastığında veya desteklenen bir yerel komutu gönderdiğinde `PermissionManager.authorizeOwnerCommand(request)` tek kullanımlık, isteğin kimliğine ve payload'una bağlı yetki üretir. Ek onay penceresi ve biyometri bulunmaz. İşlem, `ActionExecutor` üzerinden gerçekten gerçekleştirilirse makbuz üretilir.

`ActionAuthorization` serileştirilemez, yeniden kullanılamaz ve arka plana geçişte geçersizleşir. `.modelProposal` kaynaklı eylemler reddedilir; istemciye açık model metni araç yetkisi değildir.

Bu sürümde uygulanmış yerel işlemler kişisel hafıza, öğrenme kaydı, dışa aktarma ve toplu silmeyle sınırlıdır. Desteklenmeyen telefon araçları için yeni uygulama kodu ve iOS izinleri gereklidir; uygulama bunları zaten yapıyormuş gibi davranmaz.

Veri şifreleme, Keychain, ağ kimlik doğrulaması ve gerçek/başarılı işlem raporlama korunur. Bunlar gerçek kullanıcı komutunu modelin kendi metninden ayırmak için gereklidir. Önceki `prepare/approve` API'si geriye dönük test uyumluluğunda bulunur; iOS kullanıcı akışında çağrılmaz.
