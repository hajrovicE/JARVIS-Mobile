# Yol haritası
1. P0: yerel hafıza, tam TTL, şifreli kalıcılık, Türkçe komutlar ve izin akışı. Yerel metin akışı simulator üzerinde yeniden açma/silme testiyle doğrulandı; fiziksel iPhone kabulü gerekir.
2. macOS CI tamamlandı: Xcode simulator/iPhone SDK derlemeleri ve otomatik testler geçti (docs/VALIDATION.md). Kalan gerçek cihaz kabulü: yeniden başlatma, kilitli cihaz, izin reddi, Türkçe Speech kullanılabilirliği, VoiceOver ve dışa aktarma. Başarılı kontrol olmadan sürüm yayımlanmaz.
3. Sağlayıcı soyutlaması ve açık veri paylaşımı onayıyla AI entegrasyonu. API anahtarları yalnızca sunucuda. Web cevaplarında kaynak, alınma zamanı ve zamana duyarlılık sınıflaması zorunlu; sınıflandırılamayan cevap önbelleğe alınmaz.
4. Ayrı SpeakerSecurity modülü: docs/SPEAKER_SECURITY.md kabul koşulları.
5. Araç altyapısı: allowlist, kapsamlı yetki, risk sınıflaması, hassas eylem öncesi onay ve LocalAuthentication, doğrulanmış yürütme makbuzu. Bu yapı kurulmadan hiçbir dış eylem yok.

İkinci aşamada görev #1 için öğrenme şeması, ayrı LearningEngine protokolü, şifreli kalıcılık, onay/düzeltme/çelişki/silme ve arama temeli eklendi. Sonraki öğrenme işleri: güvenilir görev yürütücüsü, kaynak sağlayıcısı, tam revizyon arşivi, imzalı beceri kataloğu ve otomatik öneriler. Görev #1 açık kalır.
