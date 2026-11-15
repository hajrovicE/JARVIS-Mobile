# Alpha 0.3 AIProvider
`AIProvider` kullanıcı sorusunu ve yalnızca paylaşılması onaylanan bağlam kayıtlarını alır; `AIResponse` metin, sağlayıcı/model, oluşturulma zamanı, kaynak metadata'sı ve tazelik durumu döndürür. `AIRequest` ham ses veya otomatik tam hafıza dökümü taşımaz. Uygulama tarafındaki AssistantService bağlam seçimi, paylaşım onayı ve MemoryStore entegrasyonundan sorumludur.

`UnavailableAIProvider` varsayılan kapalı durumdur; Türkçe açık `notConfigured` hatası üretir. Üretim yolu örnek/sentetik cevap döndürmez. `HTTPRelayAIProvider` seçilen HTTPS relay adresine gerçek HTTP POST isteği yapar. Mobil uygulamada OpenAI API anahtarı bulunmaz. Erişim bilgisi sağlayıcı API anahtarı değil, sunucu operatörünün verdiği süreli/iptal edilebilir relay oturumudur; yalnızca Keychain'de saklanmalıdır. Referans sunucu ve manuel kurulum: [AI_RELAY_SERVER.md](AI_RELAY_SERVER.md).

## Sınırlar
- URL yalnızca HTTPS; kullanıcı adı/şifre, query veya fragment içermez. Tam `/v1/chat` adresi seçilir.
- HTTP yönlendirmeleri reddedilir; seçilen uç nokta dışındaki cevap kabul edilmez. Cookie, HTTP disk önbelleği ve ortam kimlik bilgileri kullanılmaz.
- Soru ve bağlam kayıtlarında yapay karakter/sayı üst sınırı yoktur; HTTP isteği için 4 MiB, sağlayıcı yanıtı için 8 MiB taşıma sınırı kalır. Sağlayıcının ve modelin kendi bağlam sınırları geçerlidir.
- Boş/bozuk/taşan JSON, 401/403/429/5xx, ağ kesintisi ve iptal ayrı hata verir. Sağlayıcı gövdesi, yetki başlığı, sırlar ve yerel içerik hata mesajına/loga yazılmaz.
- `verifiedStatic` ancak kaynak metadata'sı ve en fazla 30 günlük açık süreyle kabul edilir. Bu alanın güveni operatörün gerçek kaynak doğrulamasına bağlıdır; rastgele model prose'u kanıt değildir. Referans relay bu statüyü hiç üretmez.

## Model, kaynak ve eylem ayrımı
Referans sunucu OpenAI Responses API'sine `store:false`, Türkçe çok adımlı cevap talimatı ve seçilmiş bağlam gönderir. Tarama/araçlar kapalıdır. Bu nedenle cevapların hepsi `unverified`, kaynak listesi boş ve `expiresAt` boş olur. Modelin metin içinde yazdığı bir URL doğrulanmış citation'a dönüştürülmez. Güncel fiyat, saat, hava veya finans bilgisi doğrulanmış kabul edilmez. Yerel geçmiş/hafıza komutları ağdan bağımsız çalışır.

Model cevabı veri olarak görüntülenir; izin, onay, biyometri veya ActionExecutor makbuzu değildir. `AIResponse.text` hiçbir zaman araç çağrısı/komut olarak çalıştırılmaz. Talimat katmanı modelin eylem yaptığını iddia etmesini engellemeye çalışır; semantik garanti değildir. Gerçek eylem sonucu yalnızca güvenilir yerel yürütücünün makbuzundan gelir.

## Kanıt ve kalan kurulum
Swift otomatik testleri ağ yerine açıkça test amaçlı transport kullanır: Türkçe soru/bağlam sözleşmesi, header güvenliği, yönlendirme kontrolü, HTTP/ağ hataları, bozuk/boş cevap, boyut sınırları ve kaynaksız tazelik iddiasının reddi. Python relay testleri gerçek localhost HTTP servisi ile sahte upstream kullanır; ücretli model çağrısı yapmaz.

Bu geliştirmede canlı sunucu kurulmadı, sağlayıcı hesabı/anahtarı kullanılmadı ve gerçek modelden yanıt alındığı iddia edilmez. Operatörün HTTPS relay'i kurup sunucu Secret arayüzünden provider anahtarı/oturum sağlaması ve kullanıcının veri paylaşımını açması gerekir. Çok adımlı Türkçe semantik kalitenin gerçek model değerlendirmesi ayrıca yapılmalıdır.

## Kapasite ayarları
- Relay istek kotaları varsayılan kapalıdır: `RELAY_REQUESTS_PER_MINUTE=0` ve `RELAY_REQUESTS_PER_DAY=0`; maliyet yönetimi isteyen operatör pozitif limit belirleyebilir. Sağlayıcının ücret ve kullanım limitleri değişmez.
- `max_output_tokens=1200` kaldırıldı; model sağlayıcısının doğal çıktı sınırı geçerlidir.
- Kullanıcının paylaşmaya onay verdiği bağlam artık sabit 10/6/4 kayıtla kesilmez. Çok büyük bağlam isteği sağlayıcının penceresini aşarsa hata dönebilir.
- Bağımsız eylem engeli korunur: doğrudan kullanıcı komutları ek onay veya Face ID istemeden yürütülür; model çıktısı komut olamaz. Relay kimlik doğrulaması, şifreleme ve kullanıcı tarafından yönetilen paylaşım ayarları korunur.
