# JARVIS Activity Learning — Kullanıcı Kontrolü ve iOS Sınırları

## 1. Ne mümkün?
- iPhone üzerindeki JARVIS uygulaması, **kullanıcı açıkça açarsa** yalnızca kendi arayüzünün kaydettiği dar kapsamlı etkinlikleri öğrenme için kullanabilir.
- Event şeması yalnızca enum türü ve zaman damgası tutar; yazılan soru, aranan kelime, kişi/kişi listesi, şifre, uygulama içi ekran görüntüsü, klavye hareketi, konum ya da başka uygulamaların kaynak kodu kaydedilmez.
- Kayıtlar ayrı AES-GCM/Keychain depoya gider; 30 gün ve 1000 kayıt üst sınırı. Kapatma yeni kaydı keser, silme kaydı ve açık durumu beraber sıfırlar. 'Tüm verileri sil' ayrıca bu depoyu da temizler.
- Tekrarlayan etkileşimlerden doğan çıkarımlar otomatik gerçek değildir: kullanıcı 'Hafıza önerisi oluştur' dediğinde bile ayrı 'Onayla' adımı olmadan kalıcı tercih olmaz. Hiçbir çıkarım cihaz/hesap erişim izni yaratamaz.
- Kullanıcı kendi kod deposunu GitHub'da bağlarsa açıkça verilen repo yetkileriyle commit, CI sonucu ve PR düzeltmeleri ayrı bir **kod deneyimi** kaynağı olabilir. Yerel app bunu henüz uygulamıyor; izinsiz başka uygulama kodlarını okuyamaz.

## 2. Ne mümkün değil?
- Normal iOS uygulaması tüm diğer uygulamaların her dokunuşunu, mesajını, tuş kaydını, hesabını, özel kodunu, canlı ekranını ya da Bluetooth veri trafiğini izleyemez.
- Kullanıcı bir kere izin verdi diye iOS sandbox, diğer uygulama izinleri, parola/Face ID veya Bluetooth eşleştirmesi atlanamaz.
- Kendi içinde **sürekli gizli ekran/klavye kaydedici** yapılmaz. Genel sistem izleme, cihaz gözetimi veya şifreleri öğrenme kullanıcı isteğiyle bile iOS uygulama API'leri üzerinden sunulmaz.

## 3. Kapsamı gelecekte genişletme
- **App Intents / Shortcuts:** Kullanıcının bilerek oluşturduğu kestirmeler bir eylem sonrasında JARVIS'e kategori/sonuç sinyali verebilir. İzin, içerik kapsamı ve tetikleme seçimini kullanıcı yapar.
- **FamilyControls + DeviceActivity / Screen Time:** Uygun Apple entitlement, App Store dağıtım izni ve kişisel onayla *kısıtlı kullanım / süre / kategori* bilgisi alınabilir. Bu, her dokunuşun / uygulama içeriğinin okunması değildir. Apple hesabı, entitlement ve cihaz testi olmadan aktif olarak gösterilmez.
- **Cihaz mikrofonu ve ses tanıma:** Kullanıcı başlatmalı, görünür ve durdurulabilir olmalı. Arka planda devamlı dinleme iOS kısıtlarını aşamaz.
- **Cihaz içi yerel model:** Bu günlük yerel öğrenme kaydıdır; model ağırlığı telefonda kendi kendine eğitilmez. JARVIS tercihleri retrieval aracılığıyla kullanır, yeni temel model üretimi ayrı değerlendirme/eğitim işidir.

Kaynaklar:
- https://developer.apple.com/documentation/appintents
- https://developer.apple.com/documentation/deviceactivity
- https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement
- https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.developer.family-controls.app-and-website-usage

## 4. Kabul denetimi
1. Uygulama ilk kurulduğunda gözlem kapalı.
2. Opt-in kapalıyken olay sıfır; açıkken yalnızca allowlist.
3. Başka uygulamalardan ham eylem/tuş/ekran/kod erişimi yok.
4. Veriler 30 günde silinir; kullanıcı silme ve kapatma çalışır; 'Tüm verileri sil' tekrar açılışta boş günlüğe döner.
5. AI modelinin yazdığı metin izni açmaz ve gözlem verisini ham cloud isteğine eklemez.
6. Gerçek cihaz şifreli kalıcılığı iOS Keychain ile test edilmeden tamamlandı denmez.
