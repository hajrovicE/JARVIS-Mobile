# AI relay — HTTPS dağıtım hazırlığı

Bu yapılandırma mevcut `server/relay.py` uygulamasını tek kullanıcıya ait bir sunucuda HTTPS arkasında çalıştırmak içindir. Bu görevde cloud hesabı veya ücretli servis oluşturulmadı, public sunucu başlatılmadı, TLS sertifikası alınmadı ve gerçek model çağrısı yapılmadı. Dosyalar ve yerel, dış ağa kapalı yapılandırma kontrolleri canlı bağlantı kanıtı değildir.

## Topoloji ve koruma

`server/deploy/compose.yaml`, Caddy reverse proxy ve Python relay container'ını tanımlar. Yalnızca Caddy'nin TCP 80/443 portları host'a açılır. Relay 8787 için host port eşlemesi yoktur. Relay özel Docker bridge ağında dinler; bu ağ `internal:true` değildir çünkü relay'in sabit OpenAI API adresine dış HTTPS erişimi gerekir. Başka kullanıcı/container'ların bu ağa katılmasına izin verilmemeli; Docker yönetim erişimi sunucu sahibine ait olmalıdır.

Caddy DNS adı için otomatik ACME TLS yönetir, HTTP'yi HTTPS'e yönlendirir, TLS 1.2/1.3, HSTS, 16 KB header ve 131072 byte body sınırı ve süre sınırları uygular. Admin API kapalıdır. Caddy erişim ve varsayılan hata logları, istek URL/header/body sızıntısını önlemek için kapalıdır. HTTP hata durumları relay'in yalnızca izin verilen alanları içeren JSON operasyon loglarından izlenir. TLS/sertifika sorunları dış HTTPS sağlık/sertifika izleme ile saptanmalıdır; varsayılan proxy debug logunu kalıcı açmayın.

Relay UID/GID 10001 ile, salt okunur dosya sistemi, tüm Linux capability'leri kaldırılmış, `no-new-privileges`, sınırlı tmpfs/pid/bellek/CPU ile çalışır. Caddy yalnızca düşük port bağlamak için NET_BIND_SERVICE alır; sertifika yenilemeleri için `/data` ve `/config` volume'ları kalıcıdır. Container logları boyut/adet sınırıyla döndürülür. Resimler test edilen resmi multi-platform manifest digest'lerine sabittir; güvenlik güncellemeleri için digest'ler operatör tarafından kontrollü yenilenmelidir.

## Hesap ve ağ gereksinimleri

Canlı bağlantı için şunlar operatöre aittir:

- Docker Engine + Compose çalıştırabileceğiniz, sahibi olduğunuz Linux host veya hosting hesabı; otomatik bir ücretli plan açılmaz.
- Kontrol ettiğiniz DNS alan adı/subdomain ve sunucunun public IP'sine yönelen doğru A/AAAA kayıtları. Hatalı AAAA kaydı sertifika erişimini bozabilir.
- Girişte TCP 80/443; çıkışta DNS ve ACME/OpenAI için HTTPS erişimi. 8787 internete açılmaz.
- Sertifika yenileme iletişim e-postası ve kalıcı Caddy certificate volume yedekleme/izin politikası.
- OpenAI API hesabı/project'i, seçilen modele erişim ve kullanılabilir kota/bakiye. ChatGPT uygulaması aboneliği bu API kimliği yerine geçmez.
- Sunucu Secret yöneticisine tanımlanmış sağlayıcı API anahtarı ve yalnızca bu kullanıcıya verilmiş rastgele, süreli relay oturumu. Sağlayıcı anahtarı iPhone'a verilmez; relay oturumu uygulamanın Keychain kaydına girer.

Bu belge herhangi bir hesap, domain veya anahtarın mevcut olduğunu varsaymaz. Değerleri sohbet, issue, Git commit'i, build argümanı, image, log veya artifact içine koymayın.

## Ortam değişkenleri

`server/deploy/deployment.env.example` yalnızca **gizli olmayan değerleri ve Secret dosya yollarını** gösterir. Gerçek yapılandırmayı depo dışındaki örneğin `/etc/jarvis/deployment.env` konumunda saklayın. Relay `.env` dosyasını kendiliğinden yüklemez; Compose'a açık `--env-file` verilir.

| Değişken | Gereklilik / kullanım |
| --- | --- |
| `RELAY_HOSTNAME` | Zorunlu; kontrol ettiğiniz gerçek DNS adı, scheme/path/port olmadan |
| `ACME_EMAIL` | Zorunlu; sertifika yenileme iletişimi |
| `APP_ACCESS_TOKEN_EXPIRES_AT` | Zorunlu; gelecekteki açık Unix epoch son tarih. Yeniden başlatmada yenilenmez |
| `OPENAI_API_KEY_SECRET_FILE` | Zorunlu; depo dışındaki sağlayıcı Secret dosyasının mutlak host yolu |
| `APP_ACCESS_TOKEN_SECRET_FILE` | Zorunlu; depo dışındaki relay oturumu Secret dosyasının mutlak host yolu |
| `OPENAI_MODEL` | Varsayılan `gpt-4.1-mini`; hesabın modele erişimi gerekir |
| `RELAY_REQUESTS_PER_MINUTE` | Varsayılan 6; tek kullanıcı için süreç genelindeki kayan 60 saniye sınırı |
| `RELAY_REQUESTS_PER_DAY` | Varsayılan 100; süreç genelindeki kayan 86400 saniye sınırı |
| `RELAY_MAX_CONCURRENT` | Varsayılan 2; aynı anda çalışabilecek model isteği sayısı |

Compose relay içinde `OPENAI_API_KEY_FILE=/run/secrets/openai_api_key`, `APP_ACCESS_TOKEN_FILE=/run/secrets/app_access_token` ve `RELAY_REQUIRE_EXPLICIT_EXPIRY=true` ayarlar. Bu modda eksik/geçersiz/sona ermiş yapılandırma ile süreç hata koduyla kapanır; varsayılan sekiz saatlik geliştirme fallback'i kullanılmaz. Başladıktan sonra oturum sona ererse readiness 503, canlılık 200 kalır; bu durum işlem yeniden başlatılarak yeni oturuma dönüşmez.

### Secret teslimi ve sahiplik

Yalnızca server Secret manager'ın güvenli arayüzünü veya host'ta denetiminizdeki korumalı Secret dosya mekanizmasını kullanın. API anahtarı ve bearer **değerleri** Compose environment/build args içinde yer almaz. Dosyalar container'a salt okunur Docker Secrets mount'uyla verilir. Yerel Docker Compose file-backed Secrets, host dosyasını bind mount eder; kendiliğinden at-rest şifreleme sunmaz. Host secret manager/encrypted filesystem ve dosya izinleri operatörün sorumluluğundadır.

Standart rootful Docker için dosyalar container UID/GID 10001 tarafından okunabilir olmalıdır. Compose secrets `uid/gid/mode` alanlarına güvenmeyin; file-backed mount'larda bunlar sahipliği değiştirmez. Secret manager dışa aktarma adımından sonra yalnızca yetkili yönetici:

```sh
sudo chown 10001:10001 /etc/jarvis/secrets/openai_api_key /etc/jarvis/secrets/app_access_token
sudo chmod 0400 /etc/jarvis/secrets/openai_api_key /etc/jarvis/secrets/app_access_token
```

Bu komutlar değerleri yazdırmaz. Rootless Docker/user namespace kullanılıyorsa host UID eşlemesi ayrıca doğrulanmalıdır; dosyaları world-readable yaparak çözmeyin. API anahtarı ile relay oturumunu ayrı Secret olarak tutun. Rastgele relay token'ı Secret manager ile üretin; süresini açık epoch olarak belirleyin ve güvenli kanalla yalnızca sahibine verin. Döndürme için Secret'ı ve deadline'ı güncelleyip **relay container'ını recreate edin**; eski sürecin belleğindeki anahtar değişmiş sayılmaz. Eski oturum kabul edilmemeli ve yeni oturum `/v1/chat` için kullanılmalıdır.

## Limitler ve sağlık kontrolü

Kimlik sabit süreli karşılaştırılır; yanlış/eksik/sona ermiş oturum model çağrısı yapamaz. Dakika/gün kotası kayan 60/86400 saniyelik pencerelerle uygulanır. Limit tek kullanıcıya globaldir; IP, X-Forwarded-For veya değiştirilebilir istemci header'ı ile atlatılamaz. Eşzamanlılık ve istek kota retleri 429 döndürür. Bu limitler işlem belleğindedir ve yeniden başlatmada sıfırlanır; bunlar kalıcı bir bütçe/maliyet tavanı değildir. Birden fazla replica toplam limiti artırır. Bu yapılandırma **bir relay replica** içindir; ölçeklemeyin. OpenAI project bütçe/uyarı/kota kontrolleri ayrıca kurulmalıdır; parasal garanti verildiği iddia edilmez.

`/health/live` yalnızca sürecin cevap verdiğini ölçer; Docker healthcheck bunu kullanır. `/health` ve `/health/ready` yapılandırma/oturum hazır oluşunu ölçer. Hiçbiri gerçek model çağırmaz veya anahtar geçerliliğini bakiye/model hesabı üzerinden doğrulamaz. Canlılık 200 tek başına hazır model bağlantısı anlamına gelmez. Sağlık cevabında anahtar, oturum, dosya yolu veya sağlayıcı hata gövdesi bulunmamalıdır.

Relay operasyon logları durum/hata kodu, süre ve sunucunun ürettiği ilişkilendirme kimliği gibi izinli alanlarla sınırlıdır; prompt, hafıza, bearer, IP, URL/query ve ham exception gövdesi yazılmaz. Servisin gerçek hazır oluşu, token expiry, 401/429/502/503 artışı ve sertifika süresi izlenmelidir. Sağlayıcı hatası sahte başarıyla gizlenmez.

## Dağıtım öncesi kontrol — servis başlatmaz

```sh
# Only the public template, not Secrets. Caddy has no DAC_OVERRIDE capability.
chmod 0644 server/deploy/Caddyfile
docker compose --env-file /etc/jarvis/deployment.env -f server/deploy/compose.yaml config --quiet
docker compose --env-file /etc/jarvis/deployment.env -f server/deploy/compose.yaml build relay
```

Caddy sözdizimi kontrolü, doğrulanmış image ile `--network none` içinde `caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile` kullanılarak yapılabilir. Bu adım public servis başlatmaz veya sertifika verildiğini kanıtlamaz. Secret dosyalarının read-only/UID izinlerini ve `configured` hazır oluşunu gerçek dağıtım öncesi test edin; çıktı olarak Secret değerlerini basmayın.

**Yalnızca operatör açıkça canlı dağıtıma karar verdiğinde**, hesap/DNS/Secret hazırlığı ve maliyet kontrolünden sonra:

```sh
docker compose --env-file /etc/jarvis/deployment.env -f server/deploy/compose.yaml up -d --build
```

Bu son komut bu geliştirmede çalıştırılmadı. Gerçek domain üzerinden sertifika zinciri, HTTPS health, yanlış/sona ermiş token reddi ve doğru endpoint sözleşmesi kontrollü kabul testleriyle doğrulanmalıdır. Modeli çağıran son kontrol, hesap sahibinin ayrıca onayladığı küçük/sentetik bir soruyla yapılmalıdır; bu görevde yapılmadı. iPhone'da sunucu adresi `https://<gerçek-domain>/v1/chat` ve yalnızca relay oturumu ayarlanır; açık veri paylaşımı seçilmeden hafıza gönderilmez.

## Bu geliştirmedeki yerel doğrulama

Resmi Python 3.12.16 ve Caddy 2.11.9 image'ları edinildi; Docker image, model servisi başlatılmadan ve build network'ü kapalı olarak derlendi. Compose sözdizimi sentetik Secret dosya yollarıyla `config --quiet` kullanılarak doğrulandı. Caddy yapılandırması `--network none` ile geçerli bulundu. Bu sonuçlar gerçek HTTPS domain'i, ACME issuance, gerçek Secrets, OpenAI hesabı veya public dağıtım testi değildir.


Ek otomatik test komutu: `python3 server/deployment_smoke.py`. Gerçek entrypoint, dosya tabanlı sentetik Secrets ve dış ağ kapalı liveness/readiness kontrolünden geçer. Ardından aynı Caddyfile'ın okunabilir geçici kopyası, yalnızca internal Docker ağında `localhost` için yerel CA ile sınanır. Test istemcisi CA zincirini ve localhost hostname'ini doğrular; TLS doğrulaması kapatılmaz. Hiçbir host portu yayımlanmaz; model upstream'i açık test fixture'ıdır. Doğru/yanlış bearer,429 ve hassas içeriğin loglarda bulunmaması kontrol edilir. Bu test public domain/ACME veya gerçek model hesabı doğrulaması değildir.
