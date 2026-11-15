# Alpha 0.3 AI relay sunucusu
Bu sunucu gerçek OpenAI Responses API'sine HTTPS üzerinden bağlanır. Kod hazır olması canlı bağlantının kurulmuş olduğu anlamına gelmez; bu geliştirmede üretim sunucusu dağıtılmadı ve gerçek/ücretli model çağrısı yapılmadı. Eksik yapılandırma 503; bağlantı/sağlayıcı hatası 502 döndürür. Hazır cevap veya sahte model sonucu üretilmez.

## Çalıştırma ve güvenli yapılandırma
Python 3.10+; üçüncü taraf paket gerekmez. Sunucu host'unun güvenli Secret arayüzünden `OPENAI_API_KEY`, en az 32 karakterli rastgele `APP_ACCESS_TOKEN` ve isteğe bağlı `OPENAI_MODEL` sağlayın. Provider anahtarını mobil uygulamaya veya GitHub kaynaklarına koymayın. `.env.example` yalnızca isimleri gösterir; uygulama bu dosyayı otomatik yüklemez. Secret değerlerini loga yazdırmayın.

`APP_ACCESS_TOKEN_EXPIRES_AT` Unix epoch saniyesi olarak açık son tarih belirler. Verilmezse mevcut süreç için sekiz saat sonra sona erer. Boş/geçersiz bir değer servisi kapalı tutar. Sunucuyu yeniden başlatmak varsayılan sekiz saatlik süreyi yeniler; açık bir epoch deadline önerilir. Varsayılan model `gpt-4.1-mini`; hesabın o modele erişimi ve kullanılabilir API bakiyesi gerekir.

```sh
python3 server/relay.py --port 8787
python3 -m unittest discover -s server -p 'test_*.py' -v
```

Sunucu yalnızca `127.0.0.1` üzerinde dinler. iPhone bağlantısı için HTTPS reverse proxy ve geçerli TLS sertifikası gerekir; mobil istemci düz HTTP'yi reddeder. Proxy'de giriş hız sınırı, gövde sınırı, bağlantı zaman aşımı, TLS ve log redaksiyonu yapılandırılmalıdır. Sunucu aynı anda en fazla dört model isteği çalıştırır; doluysa 429 verir. Production operatörünün bütçe/rate limit, izleme, güncelleme ve güvenilir kimlik yönetimi sorumluluğu ayrıca vardır.

Alpha kimlik doğrulaması tek kullanıcı/özel host içindir: elle oluşturulan, süreli, iptal edilebilir bearer oturumu. Bu bearer OpenAI API anahtarı değildir; mobilde Keychain'e konur. Token değiştirerek sunucudaki eski oturum iptal edilir. Çok kullanıcılı hesap/oturum yenileme sistemi veya App Attest bu aşamada yoktur. Bu yapılandırmayı genel, anonim AI proxy'si olarak yayımlamayın.

## Sözleşme
`POST /v1/chat`, `Authorization: Bearer <oturum>`, `Content-Type: application/json`:

```json
{"prompt":"İki adımlı bir plan yap.","context":[{"id":"tercih-1","text":"Kullanıcının paylaşmayı onayladığı tercih"}]}
```

Prompt en fazla 8000 karakter; en fazla 20 bağlam kaydı, her kayıt metni en fazla 2000 karakter; HTTP gövdesi en fazla 128 KiB. Model, hedef URL, sistem talimatı ve araçlar istemci tarafından seçilemez. Bağlam kullanıcı verisi olarak gönderilir; talimat/izin olarak işlenmez. Metin araç yürütücüsüne aktarılmaz. `store:false` gönderilir; provider'ın sözleşmesel/veri işleme politikalarının yerini almaz.

Başarılı cevap `text`, `provider`, `model`, `generatedAt`, `sources`, `freshness`, `expiresAt` içerir. `generatedAt` UTC ISO8601 zamanıdır. Bu aşamada web arama/tarama yoktur; dolayısıyla bütün cevaplar `freshness:"unverified"`, `sources:[]`, `expiresAt:null` döndürür. Modelin yazdığı URL, doğrulanmış kaynak diye sunulmaz. Güncel bilgi veya dinamik fiyat/saat/finans gibi sorular doğrulanmış sayılmaz ve önbelleğe otomatik alınmaz. Türkçe ve çok adımlı sorular talimatla desteklenir; semantik kalitenin canlı model değerlendirmesi henüz yapılmadı.

## Test kapsamı
Standart kütüphane testleri gerçek ağ/model yerine sahte upstream kullanır: kimlik/expiry/yapılandırma, giriş limitleri, Türkçe sözleşme, sabit API hedefi, araç olmaması, store:false, redirect reddi, ağ/boş/eksik sonuç hataları ve gerçek localhost HTTP girişleri. Sentetik test cevabı yalnızca test fixture'ıdır; üretim yolu bununla cevaplamaz. HTTP erişim logları kapalı; prompt, yerel hafıza, bearer veya provider hata gövdesi loglanmaz.
