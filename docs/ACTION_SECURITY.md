# ActionExecutor ve PermissionManager — Alpha 0.3

İzin verilen yerel eylemler sabittir: `memory.remember`, `memory.delete`, `memory.deleteAll`, `learning.delete`, `memory.export`. Her birinin tam bir capability kümesi ve uygulama tarafından seçilen risk seviyesi vardır. Keyfi araç adı, shell, URL veya model metni çalıştırılmaz. `.modelProposal` kaynaklı çağrılar reddedilir. Uygulama içindeki `.userInterface` kaynağı yalnızca güvenilir UI olay işleyicisinden üretilir; serileştirilmiş model verisi buna dönüştürülmez.

`PermissionManager.prepare(request)` 60 saniyelik, istek kimliği ve değişmez payload'a bağlı onay sorusu oluşturur. Kullanıcının açık onay düğmesi `approve(challenge)` çağırır. Üretilen `ActionAuthorization` opak, yalnızca bellekte, en fazla 30 saniyelik ve tek kullanımlıktır; Codable değildir ve açık yapıcı sunmaz. Tam istek/payload/capability eşleşmesi gerekir. Başarısız eşleşme de token'ı tüketir; yeniden oynatma reddedilir. Ret veya arka plan geçişi outstanding izinleri geçersizleştirir; biyometri ekranı beklenirken arka plana geçilmesi sonradan yeni yetki oluşturamaz.

Hassas tek kişisel/öğrenme kaydı silme, JSON dışa aktarma ve yüksek riskli tüm veri silme, AGENTS.md politikasına göre açık onaya ek olarak `LocalAuthentication.deviceOwnerAuthenticationWithBiometrics` kullanır. Face ID/Touch ID kayıtlı değilse, erişim kısıtlıysa, kullanıcı iptal ederse veya doğrulama başarısızsa işlem yapılmaz. Konuşma tanıma veya ileride eklenecek konuşmacı benzerliği bu koşulu karşılayamaz. Biyometri için PIN/passcode'a sessiz geçiş yoktur. Simulator/donanım biyometrisi ve kullanıcı etkileşimi gerçek cihazda ayrıca kabul edilmelidir.

`ActionExecutor` önce yetkiyi tüketir, sonra gerçek MemoryStore işlemini bekler; yalnızca başarılı yazma/silmeden sonra başarı makbuzu üretir. Etki başarısızsa sonuç ve denetim kaydı `failed` olur; ham hata içeriği yerine sabit hata kodu tutulur. Denetim alanları eylem kimliği, capability adları, risk, durum ve makbuz UUID'sidir; hafıza metni/payload kopyası kaydedilmez. Etki başarılı fakat denetim yazımı başarısızsa bu ayrı `auditWriteFailed` sonucu olarak gösterilir; işlem otomatik tekrar edilmez veya geri alınmış gibi raporlanmaz.

Başarılı `deleteAllMemory` sonrası şifreli depoya yeni denetim kaydı yazılmaz: silinmiş öğrenme/veri alanlarını yeniden yaratmamak için sonuç makbuzu yalnızca bellekte döner. Diğer eylemlerin denetimi mevcut şifreli görev deneyimi koleksiyonundadır ve export/delete akışına dahildir.

Bu modül bir iOS izin yükseltme yolu değildir. Modelin bir aracı önermesi eylem yetkisi sağlamaz. İmza doğrulamalı yeni beceri yükleme, telefon sistem kontrolü ve uzak eylem yürütme Alpha 0.3 kapsamında etkin değildir.

Dışa aktarma eylemi, biyometrik yetki tüketilmeden MemoryStore.export çağırmaz. Onaylı plaintext JSON yalnızca ActionExecutionResult.exportedData içinde döner; makbuza/denetim kaydına kopyalanmaz. Paylaşım arayüzü kapandığında uygulama bu geçici veriyi temizler.
