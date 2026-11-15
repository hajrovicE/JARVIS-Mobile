# Alpha 0.3 AI relay sunucusu
Bu sunucu gerçek OpenAI Responses API'sine HTTPS üzerinden bağlanır. Kod hazır olması canlı bağlantının kurulmuş olduğu anlamına gelmez; bu geliştirmede üretim sunucusu dağıtılmadı ve gerçek/ücretli model çağrısı yapılmadı. Eksik yapılandırma 503; bağlantı/sağlayıcı hatası 502 döndürür. Hazır cevap veya sahte model sonucu üretilmez.

## Çalıştırma ve güvenli yapılandırma
Python 3.10+; üçüncü taraf paket gerekmez. Sunucu host'unun güvenli Secret arayüzünden `OPENAI_API_KEY` ve en az 32 karakterli rastgele `APP_ACCESS_TOKEN` sağlayın; dosya tabanlı Secret tesliminde `OPENAI_API_KEY_FILE` ve `APP_ACCESS_TOKEN_FILE` kullanılır. Aynı credential için VALUE ve VALUE_FILE birlikte verilirse yapılandırma reddedilir. İsteğe bağlı `OPENAI_MODEL` gizli olmayan model kimliğidir. Provider anahtarını mobil uygulamaya veya GitHub kaynaklarına koymayın. `.env.example` yalnızca isimleri gösterir; uygulama bu dosyayı otomatik yüklemez. Secret değerlerini loga yazdırmayın.

`APP_ACCESS_TOKEN_EXPIRES_AT` Unix epoch saniyesi olarak açık son tarih belirler. Yalnızca yerel geliştirmede verilmezse mevcut süreç için sekiz saat sonra sona erer. Üretim profili `RELAY_REQUIRE_EXPLICIT_EXPIRY=true` kullanır; eksik veya geçersiz/sona ermiş açık deadline ile süreç başlamaz. Boş/geçersiz bir değer servisi kapalı tutar. Sunucuyu yeniden başlatmak varsayılan sekiz saatlik süreyi yeniler; açık bir epoch deadline önerilir. Varsayılan model `gpt-4.1-mini`; hesabın o modele erişimi ve kullanılabilir API bakiyesi gerekir.

```sh
python3 server/relay.py --port 8787
python3 -m unittest discover -s server -p 'test_*.py' -v
```

Sunucu yalnızca `127.0.0.1` üzerinde dinler. iPhone bağlantısı için HTTPS reverse proxy ve geçerli TLS sertifikası gerekir; mobil istemci düz HTTP'yi reddeder. Proxy'de giriş hız sınırı, gövde sınırı, bağlantı zaman aşımı, TLS ve log redaksiyonu yapılandırılmalıdır. Sunucu varsayılan olarak aynı anda 2 model isteği, kayan 60 saniyede 6 ve kayan 86400 saniyede 100 yetkili/geçerli model denemesi kabul eder. `RELAY_MAX_CONCURRENT` (1–4), `RELAY_REQUESTS_PER_MINUTE` (1–60), `RELAY_REQUESTS_PER_DAY` (1–10000) ile sınırlı aralıkta ayarlanır; geçersiz değer güvenli biçimde reddedilir. Başarısız sağlayıcı denemeleri de kotayı tüketir; eksik/yanlış token ve geçersiz JSON sağlayıcıya ulaşmaz. Sınırda 429 ve HTTP Retry-After:60 döner. IP/X-Forwarded-For değiştirmek global tek-kullanıcı kotasını değiştirmez. HTTP bağlantı thread sayısı 32, okuma zaman aşımı 10 saniyedir. Süre kotaları tek süreç belleğindedir; restart/replica ile sıfırlanır/çoğalır ve parasal fatura sınırı değildir. Tek relay replica kullanın; sağlayıcı hesabında ayrıca bütçe/kota kontrolleri kurun. Production operatörünün bütçe/rate limit, izleme, güncelleme ve güvenilir kimlik yönetimi sorumluluğu ayrıca vardır.

Alpha kimlik doğrulaması tek kullanıcı/özel host içindir: elle oluşturulan, süreli, iptal edilebilir bearer oturumu. Bu bearer OpenAI API anahtarı değildir; mobilde Keychain'e konur. Token değiştirerek sunucudaki eski oturum iptal edilir. Çok kullanıcılı hesap/oturum yenileme sistemi veya App Attest bu aşamada yoktur. Bu yapılandırmayı genel, anonim AI proxy'si olarak yayımlamayın.

## Sözleşme
`POST /v1/chat`, `Authorization: Bearer <oturum>`, `Content-Type: application/json`:

```json
{"prompt":"İki adımlı bir plan yap.","context":[{"id":"tercih-1","text":"Kullanıcının paylaşmayı onayladığı tercih"}]}
```

Prompt en fazla 8000 karakter; en fazla 20 bağlam kaydı, her kayıt metni en fazla 2000 karakter; HTTP gövdesi en fazla 128 KiB. Model, hedef URL, sistem talimatı ve araçlar istemci tarafından seçilemez. Bağlam kullanıcı verisi olarak gönderilir; talimat/izin olarak işlenmez. Metin araç yürütücüsüne aktarılmaz. `store:false` gönderilir; provider'ın sözleşmesel/veri işleme politikalarının yerini almaz.

Başarılı cevap `text`, `provider`, `model`, `generatedAt`, `sources`, `freshness`, `expiresAt` içerir. `generatedAt` UTC ISO8601 zamanıdır. Bu aşamada web arama/tarama yoktur; dolayısıyla bütün cevaplar `freshness:"unverified"`, `sources:[]`, `expiresAt:null` döndürür. Modelin yazdığı URL, doğrulanmış kaynak diye sunulmaz. Güncel bilgi veya dinamik fiyat/saat/finans gibi sorular doğrulanmış sayılmaz ve önbelleğe otomatik alınmaz. Türkçe ve çok adımlı sorular talimatla desteklenir; semantik kalitenin canlı model değerlendirmesi henüz yapılmadı.

## Test kapsamı
Standart kütüphane testleri gerçek ağ/model yerine sahte upstream kullanır: kimlik/expiry/yapılandırma, giriş limitleri, Türkçe sözleşme, sabit API hedefi, araç olmaması, store:false, redirect reddi, ağ/boş/eksik sonuç hataları ve gerçek localhost HTTP girişleri. Sentetik test cevabı yalnızca test fixture'ıdır; üretim yolu bununla cevaplamaz. Varsayılan `create_server` test factory'si sessiz kalır; üretim CLI'si SafeEventLogger ile yalnızca time/event/code/status/duration_ms ve sunucunun rastgele request_id alanlarını stderr'e JSON yazar. Prompt, yerel hafıza, bearer, URL/query, IP, ham exception/provider hata gövdesi loglanmaz. Kalıtılmış HTTP parser ve thread hata izleri de normalize edilir. Docker log rotasyonu sınırlıdır; Caddy request/error logları özel veri sızdırmamak için kapalıdır.


## HTTPS dağıtımı ve sağlık
[Çalıştırılabilir Compose/Caddy profili ve hesap/Secrets adımları](AI_RELAY_DEPLOYMENT.md). Bu görevde gerçek host, ücretli servis veya provider isteği oluşturulmaz.

- `GET /health/live`: yalnızca süreç canlılığı; 200 `{"alive":true}`.
- `GET /health` ve `/health/ready`: sadece yerel yapılandırma ve token tarihi kontrolü; hazırsa 200, değilse 503 `{"ready":false}`. OpenAI hesabını, bakiyeyi, model erişimini veya gerçek anahtarın doğruluğunu test etmez; hiçbir sağlayıcı çağrısı yapmaz.
- Üretimde eksik/geçersiz Secret veya açık deadline startup'ı hata kodu 2 ile durdurur. Çalışan oturum sonradan sona ererse canlılık 200, readiness 503 kalır; restart ile deadline yenilenmez.

Localhost geliştirmede `python3 server/relay.py --port 8787`; container'da özel Docker ağı için `--host 0.0.0.0 --port 8787` kullanılır. Port 8787'yi public açmayın. Anahtarı/oturumu güncellemek için Secret manager'da döndürüp relay sürecini recreate edin; otomatik hot reload yoktur.

Otomatik ek doğrulama: `python3 server/deployment_smoke.py`. Docker gerekir; gerçek giriş noktası dış ağ kapalı çalıştırılır. TLS testi localhost adına yerel CA sertifikası doğrular ve test-only upstream kullanır; public port açmaz, ACME veya gerçek model servisine bağlanamaz. Üretim domain sertifikası/canlı model sonucu kanıtı olarak sunulmaz.
