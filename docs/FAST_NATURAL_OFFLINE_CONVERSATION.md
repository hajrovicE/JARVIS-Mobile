# JARVIS Native — Fast, Natural, Offline Conversation (M4)

## Implemented in this branch
1. **Warm GGUF model**: `GGUFInferenceRuntime` retains the loaded llama.cpp model weights between turns. Each prompt gets a new inference context, preserving turn isolation; backgrounding explicitly unloads weights. Loading another GGUF file at a different path/modified timestamp invalidates the resident model.
2. **Adaptive response budget**: fast conversational mode (default enabled) uses 256 output tokens for ordinary questions and up to 768 for detailed technical prompts; prompt contexts target 3072/4096 tokens respectively, never exceeding user-selected limits. Detailed mode keeps owner settings. These are maximum token budgets, not latency guarantees.
3. **Relevance-first local retrieval**: local context contains at most seven unique items and 3600 characters, weighting relevant confirmed learning/personal notes and the most recent dialogue. Remote consent logic is unchanged. Stored memory is not deleted; less-relevant records simply do not fill every inference window.
4. **Turn-taking**: after foreground offline Turkish speech recognition finalizes, optional auto-send runs a user-submitted model query. The hands-free toggle (off by default) uses a 1.35-second pause to close a speech turn, sends the final text once, speaks JARVIS's reply and reopens the microphone only **after natural TTS completion** in foreground. Manual push-to-talk is retained. Audio cannot be continuously recorded in the background; no cloud transcription.
5. **Natural Turkish voice**: prefer a higher-quality installed Turkish system voice, fallback to default Turkish, slightly adjustable pacing. User can cancel speech and interrupt by starting the microphone.
6. **Instrumentation**: app displays actual last inference elapsed time in seconds; no prompt/voice content is logged. There is no claim of sub-second performance until measurements exist.

## Why these are performance improvements
- Previously every message invoked `llama_model_load_from_file` and `llama_model_free`; a ~1GB+ model could be reloaded for every turn. Residency avoids repeated weight parsing/loading while the app is active, at the expense of RAM usage.
- Previously a complete local conversation/historical learning store could be appended to each prompt. Local retrieval now caps prompt context size to reduce prefill latency and dilution, while prioritizing question-relevant details.
- Previously even a short greeting could generate up to 2048 tokens at context 8192. Fast mode limits casual response lengths without unnecessarily restricting detailed analysis.
- Previously a speaker had to stop speech then explicitly press Send after transcription; final-only auto-send and optional hands-free completion remove two UI interactions.

## Actual device acceptance — NOT YET VERIFIED
- Hardware: iPhone 6GB RAM class, Apple Developer signed test build required. Tests with a real downloaded GGUF model on an actual iPhone are still pending.
- Collect for 10 Turkish casual questions and 10 longer technical questions: **cold first token, warm first token, total reply, tokens/sec, peak resident RAM, temperature/thermal state, model error rate, Turkish factual correctness, offline STT word errors, first audible TTS delay**.
- Compare baseline `main` vs this PR with the same GGUF, question set and owner settings; targets are improvement directions, *not invented measurements*.
- Stress cases: repeated brief answers, 5+ minute conversation, switching model files, background/foreground, cancel speech mid-utterance, silence with no words, interruptions, locked screen, app low-memory termination.
- Verify Wi-Fi/cellular disabled: model inference, recognition and TTS actually remain offline on supported device. iOS Speech's on-device language support must be confirmed on that phone.
- Confirm that verbal automatic turn-taking only restarts microphone when user explicitly chose hands-free mode and the app is in foreground. Disabled state and speech cancellations must not restart recording.
- Separate macOS Swift 6, iOS simulator, unsigned iPhone SDK CI checks from physical device validation.

## Known caveats
- The initial turn still incurs GGUF model load cost; caching improves subsequent turns, not necessarily cold startup.
- The generation currently returns the full answer before TTS begins; **token streaming and sentence-level low-latency TTS** remain future work and require cancellation/ordering/UI tests before enabling.
- A 1–2B local model may still hallucinate or produce unnatural speech text; bounded context and response instructions cannot guarantee factual truth.
- Larger context/output limits and retaining model weights can increase RAM/thermal pressure. The OS can terminate memory-hungry apps; user can toggle fast mode and releases weights on background.
- Core tests are designed to validate deterministic behavior; no actual speedup/accuracy improvement is certified until reproducible hardware benchmarks pass.
