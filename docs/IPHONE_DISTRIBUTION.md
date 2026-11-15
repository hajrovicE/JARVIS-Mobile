# iPhone dağıtımı — Alpha 0.3 hazırlığı

Bu depo Release derlemesi, imzalı IPA dışa aktarma ve isteğe bağlı TestFlight yükleme için yapılandırma içerir. İmzalama/yükleme yolu gerçek Apple hesabı ve sertifikalarla henüz doğrulanmadı. Bu geliştirme sırasında TestFlight'a uygulama yüklenmedi. Ücretli Apple Developer üyeliği etkin değilken imzalama veya yükleme denenmez.

## Şu anda yalnızca iPhone ile yapılabilecekler
GitHub'ın mobil web arayüzünden Actions → **iOS Release preparation** → Run workflow açılır. `distribution=build-only`, `build_number=3` seçilir. Varsayılan iş akışı GitHub macOS runner üzerinde Swift testlerini ve iPhone SDK **Release** derlemesini çalıştırır; imzasız `.app` ve derleme logu üretir. Bu dosya iPhone'a doğrudan kurulamaz; IPA/TestFlight dağıtımı değildir. Gerçek test sonucu ilgili Actions koşusundan kontrol edilmelidir.

Kullanıcının Mac sahibi olması CI derlemesi için gerekmez. Ancak ücretli üyelik, yasal hesap işlemleri ve güvenli imzalama kimliklerinin kurulması otomatik çözülemez. Ücretsiz Apple ID TestFlight dağıtımı sağlamaz. Bu depoda iOS imza veya yükleme kısıtlarını aşan bir yöntem yoktur.

## Hesap sahibinin manuel adımları
1. Apple ID'de iki faktörlü doğrulamayı açın. Apple Developer uygulaması veya developer.apple.com üzerinden bölgenizde desteklenen kayıt akışını tamamlayıp ücretli Apple Developer Program üyeliğinin etkinleşmesini bekleyin. Bireysel/kurumsal kimlik doğrulaması, sözleşmeler, ödeme ve gerekiyorsa kuruluş bilgileri hesap sahibine aittir.
2. Certificates, Identifiers & Profiles bölümünde sahip olduğunuz açık App ID'yi kaydedin. Kaynakta `com.jarvis.mobile` kullanılır; bu tanımlayıcının hesabınızda kaydedilebilirliği henüz doğrulanmadı. Başka tanımlayıcı gerekirse `ios/project.yml`, release policy'deki BUNDLE_ID, profil ve App Store Connect kaydı birlikte güncellenmelidir.
3. Depoda opak 1024×1024 varsayılan Alpha AppIcon ve gerekli API erişim gerekçelerini içeren PrivacyInfo.xcprivacy bulunur. Gerçek upload öncesinde uygulama metadata'sını ve beta test açıklamalarını tamamlayın; varsayılan ikonun ürününüz için uygunluğunu gözden geçirin. Bu dosyaların bulunması App Store doğrulamasının veya gizlilik beyanlarının Apple tarafından kabul edildiği anlamına gelmez. App Store Connect'te aynı Bundle ID ile iOS uygulama kaydı oluşturun; gerekli sözleşmeleri kabul edin. Sürüm, gizlilik bilgileri/politika URL'si, destek iletişimi, veri paylaşımı ve kriptografi/ihracat sorularını gerçek uygulama davranışına göre yanıtlayın. Standart şifreleme muafiyetini bu depo sizin adınıza beyan etmez.
4. Apple Distribution sertifikası ve ona ait **özel anahtarı içeren**, güçlü parolalı `.p12` sağlayın. Aynı sertifika ve tam Bundle ID için App Store distribution provisioning profile oluşturun. CSR/özel anahtar/P12 oluşturma ve dışa aktarma yalnızca iPhone arayüzünde pratik olmayabilir; gerektiğinde kendi denetiminizde güvenilir bir Mac/cloud Mac veya yetkili bir yöneticiyle kurun. Bu kimlikler bu görevde üretilmedi. Özel anahtarı veya P12'yi sohbet, issue, Git commit ya da uygulama içine koymayın.
5. App Store Connect'te yükleme yetkili en az ayrıcalıklı API anahtarını oluşturun; `.p8` dosyasını güvenle alın. API Key ID ve Issuer ID'yi saklayın. Anahtar oluşturma yetkisi hesap rolünüze bağlıdır; eksik yetkide hesap sahibi/yönetici gerekir.
6. GitHub Settings → Environments içinde **testflight** ortamını oluşturun. Gerekli reviewer belirleyin ve yalnızca `main` dağıtımına izin verin. Kendi hesabınızın GitHub planı/private repository için koruma özelliklerinin kullanılabildiğini kontrol edin; reviewer özelliği yoksa eşdeğer hesap/repo politikası kurulmadan üyelik bayrağını etkinleştirmeyin. Ortam koruması dosyadan otomatik oluşturulmaz.
7. Aşağıdaki Secrets'ı `testflight` ortamına ekleyin. GitHub repository variable `APPLE_DEVELOPER_MEMBERSHIP_ACTIVE` değerini ancak **gerçek üyelik etkin**, ortam koruması ve kimlikler hazırken tam olarak `true` yapın. Şimdilik boş/false bırakın.

## Secrets

| Secret | İçerik |
| --- | --- |
| `APPLE_P12_BASE64` | Parolalı Distribution P12'nin base64 biçimi |
| `APPLE_P12_PASSWORD` | P12 parolası |
| `APPLE_PROFILE_BASE64` | App Store distribution `.mobileprovision` base64 biçimi |
| `APPLE_TEAM_ID` | Apple Team ID |
| `ASC_API_KEY_P8_BASE64` | App Store Connect API özel anahtarının base64 biçimi |
| `ASC_API_KEY_ID` | API Key ID |
| `ASC_API_ISSUER_ID` | API Issuer UUID |

P8/Key ID/Issuer yalnızca `upload-testflight` için zorunludur; `sign-ipa` yalnızca P12, parola, profil ve takım kimliği ister. Base64 şifreleme değildir; bu değerler yalnızca GitHub Secrets olarak saklanır. Private key, sertifika veya profil uygulama binary'sine API anahtarı olarak gömülmez. Mobil AI sağlayıcısının sunucu API anahtarı bunlardan tamamen ayrıdır.

## Hazır olduğunda kontrollü dağıtım
- `build-only` varsayılandır: hesap üyeliği/Secrets gerekmez, imza veya upload yoktur.
- `sign-ipa`: yalnızca main + etkin üyelik + ortam onayı + geçerli imzalama Secrets sonrası Release archive ve manuel IPA export. Upload yapılmaz.
- `upload-testflight`: yukarıdakilere ek API Secrets ve kullanıcının açık seçimi gerekir. `altool` başarılı dönerse yalnızca Apple'ın yükleme isteğini kabul ettiği raporlanır. Apple işlemeyi bitirip App Store Connect'te build görünmeden tester erişimi/kurulum gerçekleştiği söylenmez.

Başarılı IPA export sonrası signed artifact IPA'yı ve varsa crash sembollerini (dSYMs) içerir. Upload başarısız olsa bile oluşan IPA saklanabilir; bu artifact'ın varlığı TestFlight upload başarısı anlamına gelmez.

Her gerçek upload için kullanılmamış `build_number` seçin (1–9999); önceki yüklemeye göre artırın. Aynı build numarasıyla tekrar yükleme Apple tarafından reddedilebilir. İş akışı güvenlik önkontrolü, üyelik yokken veya `main` dışında imza/yükleme isteğini Secrets'a dokunmadan reddeder. Gerekli Secrets eksikse imza oluşturulmaz.

Upload sonrası App Store Connect → TestFlight'ta işleme/kriptografi durumunu ve gerekiyorsa hata e-postasını kontrol edin. İç tester'lar uygulamaya erişimi olan uygun App Store Connect kullanıcıları olmalıdır. Dış tester dağıtımı beta incelemesi ve Apple'ın gerekli gördüğü test açıklaması/iletişim bilgileri gerektirebilir. iPhone'a TestFlight uygulamasını kurup geçerli davetle giriş yapın. Bu adımlar otomatik tamamlanmış değildir.

## İmzalama güvenliği ve sınırlamalar
- Sertifika, P8, profil çözümü ve geçici keychain `RUNNER_TEMP` altında, sıkı dosya izinleriyle tutulur. Runner'ın standart Xcode profil arama klasörlerine yalnızca doğrulanmış UUID adıyla geçici profil kopyalanır; her iki konum da `trap` ve `always()` temizliğiyle kaldırılır. Yerel çalışma ortamında home dizinine hiçbir dosya yazılmaz.
- Mevcut keychain arama listesi korunup geri yüklenir. Sertifika/profil/özel anahtarlar artifact olarak yüklenmez; imzalama logları hassas kimlik bilgisi içerebileceği için özel geçici dizinde kalır ve silinir.
- Profilin son kullanma tarihi, Team ID, tam application identifier, App Store türü ve içindeki sertifikanın içe aktarılan geçerli kimlikle eşleşmesi denetlenir. Simulator entitlements dosyası fiziksel cihaz archive işlemine uygulanmaz.
- Bu hazırlık Apple üyeliği, gerçek imzalama, upload veya App Review başarısı kanıtı değildir. İmzalı yol hesap sahibi gerekli adımları tamamladıktan sonra ayrıca doğrulanmalıdır.

Privacy manifest'te UserDefaults için `CA92.1` (uygulamanın kendi tercihleri), FileTimestamp için `C617.1` (uygulamanın kendi container dosyaları) gerekçeleri ve tracking=false belirtilir. Manifest, App Store Connect gizlilik etiketlerini kendiliğinden doldurmaz. AI sunucusu/model sağlayıcısına açık onayla gönderilen metin/hafıza ve sağlayıcının saklama politikası, hesap sahibinin gizlilik beyanında ayrıca değerlendirilmelidir.
