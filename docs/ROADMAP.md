# Yol haritası
1. P0: yerel hafıza, tam TTL, şifreli kalıcılık, Türkçe komutlar ve izin akışı. Kaynak kodu bu iterasyonda eklendi; iPhone doğrulaması gerekir.
2. macOS CI ve gerçek cihaz kabulü: yeniden başlatma, kilitli cihaz, izin reddi, Türkçe Speech kullanılabilirliği, VoiceOver ve dışa aktarma. Başarılı kontrol olmadan sürüm yayımlanmaz.
3. Sağlayıcı soyutlaması ve açık veri paylaşımı onayıyla AI entegrasyonu. API anahtarları yalnızca sunucuda. Web cevaplarında kaynak, alınma zamanı ve zamana duyarlılık sınıflaması zorunlu; sınıflandırılamayan cevap önbelleğe alınmaz.
4. Ayrı SpeakerSecurity modülü: docs/SPEAKER_SECURITY.md kabul koşulları.
5. Araç altyapısı: allowlist, kapsamlı yetki, risk sınıflaması, hassas eylem öncesi onay ve LocalAuthentication, doğrulanmış yürütme makbuzu. Bu yapı kurulmadan hiçbir dış eylem yok.
