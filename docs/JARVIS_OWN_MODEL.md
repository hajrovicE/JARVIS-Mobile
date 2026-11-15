# JARVIS'in kendi cihaz içi yapay zekâsı — yerel çekirdek

## Ürün kararı
JARVIS, iPhone'da **harici inference/model sağlayıcısına bağlanmadan** yanıt üretir. Mobil uygulama uzak API anahtarı, bulut hesabı veya otomatik bulut fallback kullanmaz. Eski sunucu kodu depoda tarihsel/ayrı modül olarak durabilir; **mobil arayüzün çalışma yoluna bağlı değildir**.

İlk çalışır temel için Apache-2.0 lisanslı Qwen3-1.7B GGUF (Q4_K_M, 1,28 GB) ve MIT lisanslı `llama.swift` / `llama.cpp` Metal/CPU motoru kullanılır. Bu kaynak ağırlıklar başkasının lisanslı çalışmasıdır; yerel sistemin davranışlarını ve eğitimle ortaya çıkacak türev JARVIS modelini kullanıcı belirler. **Henüz sıfırdan eğitilmiş bir temel model veya JARVIS'e özel eğitilmiş ağırlık üretildiği iddia edilmez.**

Başlangıç modeli:
- URL: https://huggingface.co/ggml-org/Qwen3-1.7B-GGUF/blob/daeb8e2/Qwen3-1.7B-Q4_K_M.gguf
- SHA-256: `d2387ca2dbfee2ffabce7120d3770dadca0b293052bc2f0e138fdc940d9bc7b5`
- Etiket: `daeb8e2` · Lisans: Apache-2.0
- Cihaz içinde yalnızca kullanıcının seçtiği GGUF kurulur. Model ağ üzerinden uygulama tarafından indirilmez.

## Özel JARVIS modeli yükleme
Eğitilmiş ve **Qwen3 tokenizer/chat-template uyumlu GGUF** bir dosya seçilirse dosyanın SHA-256 özeti alınır ve uygulama içinde yerel manifestte saklanır. Modelin tamamı cihazda okunur, yerel çıkarım başlatılır. Özel modelin lisansından ve kaynağından kullanıcı sorumludur; uygulama onu resmî Qwen modeli olarak etiketlemez. Her yeni sürüm kimliği digest'e bağlıdır.

## Öğrenme ile ağırlık eğitimi farkı
- `MemoryStore` / `LearningEngine`: kullanıcının öğrettiği bilgileri cihaz içinde anında kaydeder, fakat ağırlıkları **değiştirmez**.
- `scripts/model/prepare_dataset.py`: yalnızca kullanıcının hazırladığı instruction/response örneklerini yerel `train.jsonl` ve `eval.jsonl` dosyalarına ayırır. Hafızayı kendiliğinden çekmez veya göndermez.
- `scripts/model/train_lora.py`: lokal başlangıç modelini ve açıkça hazırlanmış verileri kullanarak, uygun harici GPU üzerinde JARVIS adaptörü/merge ağırlıkları oluşturabilir. Çalıştırılmadı; bu kodun varlığı eğitimin tamamlandığı anlamına gelmez.
- Birleştirilmiş checkpoint, llama.cpp GGUF dönüştürme / quantization zinciri ile Qwen3-uyumlu GGUF haline getirildikten sonra iPhone'a kullanıcı tarafından yüklenir. Sürüm, lisans ve modelin davranışları gerçek cihazda test edilir.

## Örnek eğitim biçimi
```jsonl
{"instruction":"Türkçe olarak kendini tanıt.","response":"Ben JARVIS, cihazındaki kişisel asistanım."}
{"instruction":"Bilmediğin güncel veriyi nasıl anlatırsın?","response":"Güncel bir kaynağa erişimim olmadığında bunu belirtirim."}
```

```bash
python3 scripts/model/prepare_dataset.py --input owner-examples.jsonl --output local-dataset
# CUDA GPU + yerel Qwen3 checkpoint + transformers / peft / datasets / torch
python3 scripts/model/train_lora.py --base /local/Qwen3-1.7B --train local-dataset/train.jsonl --output jarvis-model
```

## Yürütme kuralı
JARVIS modelinin yanıtı kendi başına telefon komutu değildir. Yalnızca o anda sahibin uygulamada doğrudan verdiği komut `ActionExecutor` tarafından işlenebilir. Uzak AI veya telemetry'ye gizli geçiş yapılmaz.

## Henüz doğrulanmamış olanlar
Tam iPhone gerçek cihaz GGUF inference hızı/RAM/ısınma, iOS derlemesi ve TestFlight dağıtımı; eğitim/LoRA ve modelin Türkçe çıktı kalitesi. Model yüklü değilse yapay başarı uydurulmaz.
