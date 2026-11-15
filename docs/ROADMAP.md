# Yol haritası
1. P0: yerel hafıza, tam TTL, şifreli kalıcılık, Türkçe komutlar ve izin akışı. Yerel metin akışı simulator üzerinde yeniden açma/silme testiyle doğrulandı; fiziksel iPhone kabulü gerekir.
2. macOS CI tamamlandı: Xcode simulator/iPhone SDK derlemeleri ve otomatik testler geçti (docs/VALIDATION.md). Kalan gerçek cihaz kabulü: yeniden başlatma, kilitli cihaz, izin reddi, Türkçe Speech kullanılabilirliği, VoiceOver ve dışa aktarma. Başarılı kontrol olmadan sürüm yayımlanmaz.
3. Sağlayıcı soyutlaması ve açık veri paylaşımı onayıyla AI entegrasyonu. API anahtarları yalnızca sunucuda. Web cevaplarında kaynak, alınma zamanı ve zamana duyarlılık sınıflaması zorunlu; sınıflandırılamayan cevap önbelleğe alınmaz.
4. Ayrı SpeakerSecurity modülü: docs/SPEAKER_SECURITY.md kabul koşulları.
5. Araç altyapısı: allowlist, kapsamlı yetki, risk sınıflaması, hassas eylem öncesi onay ve LocalAuthentication, doğrulanmış yürütme makbuzu. Bu yapı kurulmadan hiçbir dış eylem yok.

İkinci aşamada görev #1 için öğrenme şeması, ayrı LearningEngine protokolü, şifreli kalıcılık, onay/düzeltme/çelişki/silme ve arama temeli eklendi. Sonraki öğrenme işleri: güvenilir görev yürütücüsü, kaynak sağlayıcısı, tam revizyon arşivi, imzalı beceri kataloğu ve otomatik öneriler. Görev #1 açık kalır.


## Alpha 0.3 durumu
- AIProvider/HTTPS relay, paylaşım onayları, Türkçe/multi-step model çağrı sözleşmesi, konuşma devamlılığı ve kaynak/zaman/tazelik metadata'sı eklendi. Gerçek API kodu var; canlı sunucu/anahtar bağlantısı bu görevde yapılmadı.
- Öğrenme revizyonları, onaylı görev düzeltmeleri, credential filtresi ve tam ilişkili silme eklendi. İmzalı yeni beceri kurulumu ve otomatik öneri yürütme hâlâ yok.
- ActionExecutor/PermissionManager, yerel memory allowlist'i ve hassas işlemler için gerçek cihaz biyometrisi adaptörü eklendi. Telefon sistem kontrolü yoktur.
- Release build-only ve koşullu/protected signing/TestFlight workflow'u eklendi. Üyelik/Secrets olmadan imza/upload yapılmaz; gerçek dağıtım doğrulanmış sayılmaz.
- Sonraki kabul: canlı sahipli AI sunucusu, fiziksel cihaz Speech/TTS/FaceID/DataProtection, çok kullanıcılı auth/güvenilir hosting ve hesap sahibiyle imzalama/TestFlight. Kesin test sonuçları docs/VALIDATION.md içinde.
