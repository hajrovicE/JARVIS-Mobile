# Ayrı konuşmacı güvenlik modülü — plan
Mevcut SpeechController yalnızca konuşmayı metne çevirir; kimlik kanıtı değildir. Ses benzerliği tek başına hassas bir işlemi yetkilendiremez.

SpeakerSecurity ayrı hedef/modül olacak. Arayüz taslağı: enroll(consent, samples), verify(challenge, audio), revokeEnrollment(). Sonuçlar verified / rejected / unavailable / lockedOut; belirsizlik fail-closed. Ham ses ve embedding JarvisCore sohbet hafızasına yazılmayacak.

Açık rıza ve silme akışı; rastgele meydan okuma cümleleriyle çok oturumlu kayıt; cihazda şifreli embedding; eşik kalibrasyonu; replay, sentetik ses ve canlılık saldırılarına karşı değerlendirme; hız sınırı, deneme kilidi; erişilebilir alternatif ve cihaz biyometrisi gerekir. Hassas işlemlerde ayrıca açık işlem onayı ve Face ID/Touch ID zorunludur. Biyometri kullanılamıyorsa güvenli fallback ürün kararı ve güvenlik incelemesiyle belirlenir; sessiz bypass yoktur.

Kabul: Türkçe ve farklı aksan/gürültü veri setlerinde FAR/FRR raporu, tekrar ve sentetik ses saldırı testi, kayıt iptali ve tüm veri silme, kilit/yeniden başlatma, hata ve erişilebilirlik testleri. Onaylı hedef eşikler ve bağımsız güvenlik incelemesi tamamlanana kadar UI'da etkin gösterilemez.
