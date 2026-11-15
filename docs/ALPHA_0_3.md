# Alpha 0.3 — uygulanan kapsam

## AI akışı
`AIProvider` modülerdir; `HTTPRelayAIProvider` yapılandırılmış HTTPS `/v1/chat` sunucusuna bağlanır. Mobil uygulamada model sağlayıcı anahtarı yoktur. Aracı servis için süreli oturum bilgisi ayrı Keychain kaydındadır. Varsayılan sağlayıcı açıkça `notConfigured` döndürür. Üretim yanıtı taklidi yapan bir adaptör yoktur; test doubles yalnızca test hedefindedir.

`server/relay.py` gerçek OpenAI Responses API çağrısını uygular. Sağlayıcı anahtarı ve manuel verilen süreli erişim oturumu yalnızca sunucu ortamından gelir. Bu geliştirmede canlı model çağrısı veya sunucu dağıtımı yapılmadı. [Kurulum ve sınırlar](AI_RELAY_SERVER.md).

Uygulamada AI varsayılan kapalıdır. Soru metnini göndermek için açık onay; kişisel hafıza, onaylı/hassas olmayan öğrenme kayıtları ve geçmiş için ayrı seçim gerekir. Bağlantı ayarları değişince paylaşım seçimleri kapanır. Model yanıtı komut yönlendiricisine veya ActionExecutor'a verilmez; kullanıcıya AI yanıtı olarak gösterilir. Üretilmiş bir 'işlem yaptım' ifadesi yürütme makbuzu sayılmaz. Gerçek makbuzlar yalnızca izinli yerel yürütmeden gelir.

Sistem Türkçe ve çok adımlı sorular için talimatlı gerçek model çağrısı yapabilir. Geçmiş paylaşımı onaylanırsa son yerel/model konuşmaları sınırlı bağlam olarak eklenir; onaysız önceki cevaplar gönderilmez. Konuşma geçmişi paylaşılan istekte önbellek kullanılmaz. Kişisel/öğrenme paylaşımı kapatılırsa o kategorilerden türetilmiş eski model cevapları sonraki geçmiş paylaşımından da dışlanır. Bağlam seçimi sınırlıdır; bütün hafıza otomatik gönderilmez. CredentialFilter bilinen parola/token desenlerini engeller, kapsamlı PII sınıflandırması değildir. Kullanıcı hassas içerikleri paylaşmamalıdır. Yerel komutlar AI onayından, internetten ve sunucu ayarlarından bağımsız kalır.

## Hafıza, kaynak ve tazelik
Şema v3, önceki v0/v1/v2 verilerini korur. `StoredAIAnswer` soru, sağlayıcı/model, oluşturulma ve kaydedilme zamanı, kaynak metadata'sı, paylaşılmış bağlam kimlikleri ve önbellek uygunluk süresini saklar. Bunlar konuşma arşividir; en fazla90 gün tutulur. Eski konuşmalar90, mevcut `answers` önbelleği30 gün kurallarını korur. `cacheUntil`, arşivin kopyası değil en fazla30 günlük yeniden kullanma iznidir; süre dolunca tekrar sağlayıcıya başvurulur.

Canlı aracı servis web araması yapmaz; bütün model yanıtları `unverified`, kaynak listesi boş ve cacheUntil=nil döner. Modelin yazdığı URL'ler ziyaret edilmiş kaynak diye gösterilmez. Gelecekte güvenilir kaynak metadata'sı sağlayan bir adaptör için statik cevaplar, açık kaynak/expiry kontrolüyle en fazla30 gün tekrar kullanılabilir. Fiyat, hava, finans, saat ve benzeri dinamik konular için yeniden kullanım kapalıdır. Heuristik bir doğruluk kanıtı değildir; varsayılan doğrulanmamış cevap hiçbir soruda önbelleğe alınmaz.

Kişisel/öğrenme bağlamı değiştiğinde türetilmiş AI cevapları muhafazakâr biçimde temizlenir. İstek sürerken hafıza silinirse epoch kontrolü eski yanıtın geri yazılmasını engeller. İptal/paylaşım kapatma durumunda ağ ve görüntüleme/seslendirme sınırlarında iptal kontrolü yapılır. Sunucuya önceden gönderilmiş bir isteğin dış sağlayıcıdan geri alınabildiği iddia edilmez.

Öğrenme düzeltmeleri önceki sürüm/provenance/güven bilgilerini korur. Görev deneyimi düzeltmesi onaya düşen bir kuraldır; onay öncesi retrieval'a girmez. Silme, ilişkili eski iddiaları, revizyonları ve bağlı görev deneyimlerini kaldırır. Görev deneyimleri90 gün, kullanıcı onaylı tercihler/kurallar kullanıcı silene kadar tutulur. İmzalı beceri yükleme ve otomatik riskli öneri yürütme etkin değildir.

## Güvenli işlemler ve ses
ActionExecutor sabit yerel allowlist, tam yetki kapsamı, süreli/tek kullanımlı makbuz ve gerçek etki denetimi içerir. Hassas silme/dışa aktarma ve tüm veri silme açık onay + Face ID/Touch ID gerektirir. Biyometri yoksa işlem reddedilir; gizli bypass veya PIN'e sessiz geçiş yoktur. `unut <UUID>` artık doğrudan silmek yerine bu onay akışına girer. UI testinde kullanıcı iptali veriyi korur; başarılı silme ve hata durumları core/şifreleme testleriyle doğrulanır.

Türkçe cihaz içi Speech ve opt-in TTS korunur. Metin akışı ses kaynaklarını oluşturmaz. Başlatma Task'ı bırakma/arka planda iptal edilir. Ayrı SpeakerSecurity protokolü **kullanılamıyor** sonucu döndürür; gerçek konuşmacı kaydı/embedding/spoof savunması yoktur ve özellik tamamlandı gösterilmez.

## Dağıtım
[Telefon üzerinden hesap ve dağıtım adımları](IPHONE_DISTRIBUTION.md). `release.yml` varsayılan `build-only` ile imzasız Release üretir. Üyelik etkinlik değişkeni, korumalı ortam, manuel seçim ve Secrets hazır olmadan imza/upload yolu çalışmaz. Bu koşunun build-only çalıştırılması ne Apple üyeliği ne TestFlight dağıtımı sağlar.

[Doğrulama raporu](VALIDATION.md) kesin test sonuçlarını ve koşu bağlantılarını içerir. Fiziksel iPhone, canlı model, gerçek imza ve TestFlight kabulü birbirinden ayrı doğrulamalardır.
