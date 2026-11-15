# First Codex task — execute now
Implement a real iPhone-first JARVIS Mobile application, building on the provided repository. First read `AGENTS.md` and all docs.

**First iteration priorities (do in order):**
1. Run `swift test`; fix failures. Audit `JarvisCore` retention tests, add edge cases for exactly 90/30 days and permanent deletion.
2. Replace in-memory `MemoryStore` with a persistent, encrypted-at-rest, offline-first store on iOS, with migration and data-protection keys in Keychain. Expose testable storage interface and migration/export/delete functionality. Never store sensitive secrets in plain UserDefaults.
3. Compile the SwiftUI target using Xcode; fix target settings/permissions/Swift version errors and prove simulator build. Mac/Xcode required; if unavailable, report untested instead of claiming success.
4. Add complete Turkish onboarding, explicit microphone/Speech permission flow, and an honest capability status screen (speaker identity verification NOT active). Implement a hold-to-talk UI with Speech authorization/fallback to typing, TTS opt-in.
5. Implement trusted command router: `hatırla ki`, `ne hatırlıyorsun`, `unut`, `geçmiş`, plus safe fallback. Ensure only actually performed actions are confirmed. Show citations/freshness for externally retrieved answers when later enabled.
6. Add unit/integration tests, CI workflow for macOS runner, and a security checklist; include screenshots if simulator accessible.

**Definition of Done for this iteration**: a testable native iOS app that records a memory, survives app restart with encrypted storage, retrieves and deletes it, purges expired conversations/cache, transcribes speech on supported device with permission, and runs tests. Not yet a full JARVIS; give a precise report of unbuilt features.

Then follow `docs/ROADMAP.md` without waiting for more product brainstorming; choose maintainable defaults when details are unspecified. Never add secret bypass or unsupported system-level phone control.
