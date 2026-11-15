# JARVIS — Serbest Sorgulama ve Kullanıcı Kontrollü Deneyim Öğrenmesi

Ürün hedefi: Kullanıcı, JARVIS'in ele aldığı konuları, düşünme biçimini, yanıt tarzını, doğru/yanlış değerlendirmelerini ve deneyimlerden çıkarılacak dersleri belirler. Yerel modelin konuşmalarında alışılmadık veya tartışmalı konulara sırf konu başlığı nedeniyle otomatik olumsuz yanıt vermesi hedeflenmez. Gerçeğe ilişkin belirsizlik, cihazın kapasitesi ve işlemlerin gerçekten yürütülüp yürütülmediği saklanmaz.

## Konuşma ve öğrenme özgürlüğü
- `PersonalAIPreferences.openInquiry` varsayılan açık. Yerel model prompt'u doğrudan, sorgulayıcı, açık fikirli ve kanıt düzeylerini ayıracak şekilde oluşturulur. Bu **öneri tonu** uygulama tarafından denetlenir; temel açık-ağırlık modelin kendi davranışı tamamen sıfırlanmış sayılmaz.
- `öğret: <konu> = <açıklama>` kullanıcı öğretisini doğrulanan ayrı şifreli hafızada tutar. Aynı konu yeniden öğretilirse eski kayıt revizyon olur.
- Kullanıcı `öğret: serbest_sorgulama = hayır` diyerek bu anlatım tavrını değiştirebilir. `öğret: yanıt_tarzı = analitik` benzeri açıklamalar yalnızca bilinen anahtar/değer eşleşmelerinde yerel çıkarım tercihlerine dönüşür; keyfi metin kod/yetki politikası değiştirmez.
- `değerlendir: <görev-kimliği> | doğru/yanlış/mahrem | ders` ile **önceden kaydedilmiş gerçek görev sonucunu** etiketler. Söz konusu görev kayıtlı değilse veya henüz sonuçlanmamışsa değerlendirme başarısız olur.
- iOS Hafıza sekmesinde tamamlanmış görev seçme, "Doğru / Yanlış / Mahrem" ve açıklama girme akışı bulunur.
- Mahrem etiketi `MemorySensitivity.sensitive` olarak saklanır; varsayılan bulut bağlamına alınmaz. Sırlar/erişim anahtarları gözlem verisi yapılmaz.
- İnceleme ve ders kaydı model ağırlığını otomatik eğitmez; RAG/kişisel hafıza ve daha sonra açıkça onaylı model ince ayarı için kullanılabilir.

## Teknik gerçekler
- Hiçbir dil modeli, kullanıcı istekleriyle iOS sandbox, Apple kimlik doğrulaması, üçüncü taraf mesaj/veri erişimi, Bluetooth eşleştirmesi veya başka kişi mahremiyeti kurallarını iptal edemez.
- Öğrenilen ilkeler eylem izni değildir. Model çıktısı otomatik telefon eylemine dönüşmez; kullanıcının kurduğu izin, kapsam ve biyometrik doğrulamalar korunur.
- Kaynak cevaplarda uydurma kanıtı doğrulanmış gibi gösterme yoktur. Genel sohbetin açık fikirli olması, dış veri paylaşımının kendiliğinden açılması anlamına gelmez.
- Bu PR yeni bir genel amaçlı model yaratmaz; kullanıcının yanıt profilini ve yerel doğrulanmış deneyimlerden öğrenme altyapısını genişletir.
- İlk cihaz üzerinde `llama.cpp` entegrasyonu PR #5, gözlem iş akışı PR #7, kullanıcı tarafından verilen ilkeler PR #8 üzerinden ilerler; burada PR #8 üzerine ek gelişme uygulanmıştır.

## Kabul testleri
- Hiçbir gerçek görev kaydı olmadan deneyim etiketi kabul edilmez.
- "Önerildi" durumundaki ama yürütülmemiş görev, başarı kanıtına dönüşmez.
- Üç etiket doğru biçimde saklanır; mahrem etiket ayrı duyarlılıkta saklanır ve bulut paylaşım bağlamına girmez.
- Aynı görev etiketinin kullanıcıdan gizli üstüne yazılmasına izin verilmez.
- Sözel ilke, işlem yetki anahtarı oluşturamaz.
- Kullanıcı kararları ve hataları, araç yetki kontrolünü veya iOS güvenliğini değiştirmez.
- Swift/macOS/iOS CI başarı raporu olmadan birleştirilmiş/üretimde denmez; gerçek iPhone testi ayrıca yapılır.
