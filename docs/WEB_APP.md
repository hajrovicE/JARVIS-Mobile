# JARVIS web uygulaması (bilgisayarsız iPhone kurulumu)

iPhone'a App Store, TestFlight veya bilgisayar olmadan kurulabilen sürüm. Safari'de açılır ve **Ana Ekrana Ekle** ile uygulama gibi çalışır.

## Kurulum (yalnızca iPhone)
1. Safari'de JARVIS web adresini açın (GitHub Actions → *JARVIS web app (GitHub Pages)* koşusunun özetinde ve depo ana sayfasında görünür).
2. Paylaş düğmesi → **Ana Ekrana Ekle**. Ana ekrandaki JARVIS simgesiyle açın: Safari ana ekrana eklenmiş uygulamaların verilerini, normal sekmelerin aksine, kullanılmadığında silmez.
3. **AI** sekmesi → **İndir: Hızlı · Qwen3 0.6B** (Wi‑Fi önerilir). Model bir kez indirilir ve telefonda saklanır.
   Uygulama içi indirme çalışmazsa: Safari'de [Qwen3-1.7B-Q4_K_M.gguf](https://github.com/hajrovicE/JARVIS-Mobile/releases/download/model-qwen3-1.7b/Qwen3-1.7B-Q4_K_M.gguf) (~1,28 GB, Apache-2.0) bağlantısıyla dosyayı İndirilenler'e kaydedin, sonra **AI → Telefondaki GGUF dosyasını seç** ile seçin. Dosya `.github/workflows/model-release.yml` ile Hugging Face'teki sabit revizyondan indirilip SHA-256 ile doğrulanarak yayımlanır.
4. **Sohbet** sekmesinden yazın. Sesli giriş için klavyedeki mikrofon tuşunu kullanın.

## Nasıl çalışır
- Çıkarım, llama.cpp'nin WebAssembly derlemesi olan [wllama](https://github.com/ngxson/wllama) (`3.13.0`, MIT) ile **telefonun tarayıcısında** yapılır. Site statiktir; soru, hafıza veya geçmiş hiçbir sunucuya gönderilmez. İnternet yalnızca site ve model dosyası ilk kez indirilirken kullanılır.
- Safari JSPI/Memory64 desteklemediği için wllama'nın uyumluluk derlemesi (`@wllama/wllama-compat`) kullanılır; bu dosyalar siteyle birlikte sunulur, CDN'e bağlanılmaz.
- Model dosyası (GGUF) IndexedDB'de, hafıza/geçmiş/ayarlar `localStorage`'da şifrelenmeden saklanır. Sahibi silene kadar silinmez. "Tüm verileri sil" hafıza ve geçmişi siler; model ayrı düğmeyle silinir.
- Komutlar iOS uygulamasıyla aynıdır (`hatırla ki …`, `ne hatırlıyorsun`, `unut <kimlik>`, `düzenle <kimlik> = …`, `öğret: konu = bilgi`, `bundan sonra …`, `geçmiş`, `öğrendiklerin`, `verilerimi dışa aktar`, `tüm hafızayı sil`). Komutu yalnızca sahibin yazdığı metin tetikler; model çıktısı asla komut olarak çalıştırılmaz.
- Davranış kuralları yalnızca sahibin yazdığı metindir; boşsa modele sistem talimatı gönderilmez. Hafıza, kullanıcı mesajının içinde "kaydedilmiş veri" olarak iletilir. Geçmiş bağlam penceresine sığmazsa en eski kısım modele gönderilmez (silinmez).

## Web araştırması ve öğrenme
- `araştır: <konu>` (veya `internette ara <konu>`): Wikipedia'da arar (önce Türkçe, sonuç yoksa İngilizce), ilk 3 sonucun giriş metnini alır, bağlantı ve alınma zamanıyla gösterir. Model yüklüyse bu kaynakları "internetten alınan veri" olarak alıp cevap üretir; cevap, kaynak listesiyle geçmişe kaydedilir. Model yoksa kaynağın kendi metni gösterilir.
- `öğren: <konu>`: ilk sonucun özetini (en fazla 1200 karakter) kaynağı ve tarihiyle **Öğrendikleri** listesine kaydeder; sonraki sorularda hafıza bağlamı olarak kullanılır. Aynı konu yeniden öğrenilirse web kopyası güncellenir. Hafıza sekmesinden silinebilir.
- Yetki: bu komutları yalnızca sahibin yazdığı metin başlatır. Model çıktısı arama başlatamaz; model kendi başına internete çıkmaz.
- Gizlilik: Wikipedia'ya yalnızca arama metni gider (çerez ve referrer gönderilmez). Hafıza, geçmiş ve davranış kuralları gönderilmez.
- Sınır: tarayıcı güvenlik kuralları (CORS) yüzünden sunucusuz bir sayfa rastgele web sitelerini okuyamaz; bu yüzden kaynak Wikipedia ile sınırlıdır. "Öğrenme" model ağırlıklarını değiştirmez; bilgi hafızaya kaydedilir.

## Sınırlar (dürüst liste)
- Yerel iOS uygulamasından **belirgin şekilde yavaştır**: Safari'de uyumluluk modu ve tek iş parçacığı kullanılır. 0.6B modelde kısa cevaplar saniyeler-onlarca saniye sürebilir. "GPU (WebGPU)" ayarı iOS 26 Safari'de hızlandırabilir; deneyseldir, yüklenemezse CPU'ya döner.
- 0.6B modelin Türkçe yetkinliği sınırlıdır. 1.7B daha iyidir ama ~1,3 GB indirir ve eski iPhone'larda belleğe sığmayabilir (sayfa yeniden açılır).
- Safari'de ana ekrana eklenmeden kullanılırsa, site uzun süre açılmadığında veriler tarayıcı tarafından silinebilir.
- Konuşmacı tanıma, web arama ve telefon kontrolü yoktur.

## Doğrulama
- `cd web && npm ci && npm test`: çekirdek komut/hafıza/istem testleri.
- Linux'ta Chromium ile uçtan uca denendi (rastgele ağırlıklı küçük bir test GGUF'u ile): model indirme ve yedek dosyaya geçiş, IndexedDB'ye kayıt, akışlı yanıt, yeniden açılışta hafıza/geçmiş/modelin korunması, GGUF olmayan dosyanın reddi, tüm verileri silme. Aynı test Safari'yi taklit eden uyumluluk modunda (JSPI ve Memory64 kapalı) da geçti.
- **Gerçek iPhone Safari'de ve gerçek Qwen3 modelleriyle denenmedi**; hız, bellek ve Hugging Face indirmesi ilk gerçek kullanımda görülecek.
