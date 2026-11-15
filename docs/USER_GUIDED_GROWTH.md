# JARVIS — Kullanıcının Öğrettiği İlkeler ve Sürekli Gelişim

Ürün kararı: JARVIS kullanıcının kendi yardımcısıdır. Cevap üslubu, öncelikleri ve günlük çalışma prensiplerini kullanıcı belirleyebilir. JARVIS yeni yaklaşım ve fikirler önerir, hatalardan ders çıkarır ve doğrulanmış geri bildirimden öğrenir. Bu yetenekler **telefonda çalışan gerçek dil modelinden ayrı bir hafıza/öğrenme katmanıdır**: model ağırlıklarının otomatik güncellenmesi veya sınırsız sistem erişimi iddia edilmez.

## Kullanıcı tarafından ayarlanabilen davranışlar
- Doğrudan / analitik / kısa yanıt üslubu
- Varsayımları sorgulama, eleştirel düşünce ve alışılmadık çözüm önerme
- Konuşma sırasında öğrenilen tercihler, hedefler, iş akışları ve düzeltilen hatalar
- "Öğret: konu = ilke" ile bilginin doğrudan kaydı, aynı konunun tekrar öğretilmesiyle eski bilginin **revizyon arşivine** alınması
- "Öğrenme raporu" ile onaylanan ve bekleyen bilgilerin, gerçekleşen ve başarısız görevlerin özetlenmesi
- Görev makbuzlarındaki tekrarlanan gerçek başarısızlıklardan **geliştirme önerileri** üretilmesi; öneriler eylem veya otomatik kod değişikliği değildir

Kullanıcı tarafından açıkça yazılan `öğret: yanıt_tarzı = Cevapların kısa, direkt ve eleştirel olsun` ifadesi doğrudan kullanıcı öğretme işlemi olarak işlenir. Bunun dışındaki model kaynaklı tahminler ayrı onay olmadan kalıcı öğrenme kaydı olmaz. Öğrenilen değerleri Hafıza sekmesinde görebilir/düzenleyebilir/silebilir.

## Değişmeyen teknik sınırlar
İlkeler, bağımsız yerel modelin **iletişim tercihlerini** yönetir, yetki kaynağı değildir. Yapay zekâ çıktıları, bilgi notları ve kullanıcı tercihleri:
- iOS'un uygulama sandbox'ını, başka uygulamaların verilerini, Apple kimlik doğrulamasını, Bluetooth eşleştirmesini, Face ID'yi veya güvenli cihaz erişimini devre dışı bırakamaz;
- gizli dinleme, şifre toplama, sınırsız etkinlik takibi veya hesabı ele geçirme izni oluşturmaz;
- dış ağ bağlantısını kullanıcı açıkça açmadan kişisel veriyi göndermez;
- doğrulanmadan "telefonu kontrol ettim / testi geçtim" gibi sonuçlar üretemez;
- kodda sır saklama, şifreli depolama, 90/30 günlük saklama ve kullanıcının silme hakkını kaldırmaz.

Bu sınırlar kullanıcı tercihlerinin bir "etik sansür filtresi" olmasından değil, izin ve veri güvenliği modelinden kaynaklanır. Modelin kaynağının kendi lisansı, iOS sistem API'leri ve varsa haricî sağlayıcı politikaları ayrıca geçerlidir; JARVIS bunları bir prompt ile aşamaz.

## Büyüme döngüsü

1. **Gözlem:** JARVIS'te kullanıcı açık izniyle sınırlı eylem türleri, gerçek başarı/başarısızlık makbuzları ve açıkça yazılmış düzeltmeler incelenir. Başka uygulamaların özel verileri izlenmez.
2. **Öneri:** Aynı güvenilir işlem iki kez başarısız olursa güvenilirlik incelemesi önerilir. Model uydurduğu başarılar veya serbest metin aracılığıyla yeni yetki kazanamaz.
3. **Onay:** Kullanıcı tarafından doğrudan öğretilen sıradan tercihler kaydedilir; modelin kendisinin önerdiği bilgiler kullanıcı onayı bekler.
4. **Uygulama:** Onaylı ve geçerli hafıza, yerel modele yalnızca veri bağlamı olarak eklenebilir. Eylem için ayrıca allowlist/yetki değerlendirmesi uygulanır.
5. **Değerlendirme:** Tekrarlayan hata sayısı, doğrulanmış sonuca göre gerileme, yeni sürümün Türkçe test setine etkisi kaydedilir. Gerilemede sürüm geri alınır.
6. **Model güncellemesi (ileri faz):** İzinli ve lisanslı değerlendirme seti/LoRA eğitimi ayrı işlem hattıdır; cihaz içinde kendiliğinden model ağırlığı yeniden eğitildiği iddia edilmez. Model ağırlıkları cihazdan çıkacak kişisel örneklerle eğitilecekse ayrıca kullanıcı onayı şarttır.

## Mevcut kodun kapsamı
- `UserGuidedLearning.swift`: açık kullanıcı öğretileri ve düzeltmeleri mevcut şifreli LearningState aracılığıyla sürümlenir.
- `ImprovementReview.swift`: gerçek ve izin verilen görev türlerinde tekrarlanan hataları inceler; salt okunur öneri üretir.
- `CommandRouter.swift`: yeni iki Türkçe komutu işler, öğretinin ham metnini konuşma geçmişine yeniden kopyalamaz.
- `PersonalAIPreferences`: yanıt sunumunu yapılandıracak tiptir; modelin gerçek çıkarımına/arayüzde profil seçimine tam entegrasyon sonraki dilimdir.

## Test / ürün sınırları
Swift 6 ve iOS CI sonuçları PR üzerinden ayrıca doğrulanacak; gerçek cihazda model çalışması, öz eğitim, sürekli iOS arka plan çalışma, sınırları aşma ve kullanıcıya görünmeyen izleme bu dilimde uygulanmış sayılmayacak.
