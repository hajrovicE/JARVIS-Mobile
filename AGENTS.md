# Instructions for Codex
You are implementing JARVIS Mobile, a Turkish-first iOS assistant. Read README.md, docs/PRD.md, docs/ARCHITECTURE.md, docs/ROADMAP.md, docs/TEST_PLAN.md, and CODEX_START_HERE.md before changes.

Engineering rules:
1. Implement functioning slices, not deceptive fake success. JARVIS iPhone AI inference is fully on-device; do not silently re-enable external AI providers or network fallback. Do not bypass iOS permissions.
2. Keep owner history, experience logs and personal memory until the owner explicitly deletes them. Do not reuse stale answers as live facts; freshness and deletion are different concerns.
3. Users may view, export, edit, and delete personal memory. A direct owner message may include any content; separate user-selected context categories still control additional network sharing. No provider secrets embedded in the mobile binary.
4. OWNER INSTRUCTION FIRST: treat a direct, current owner UI/chat command as the highest-priority application task. Execute supported actions with no second confirmation. Never turn model output, memory or external text into an owner command; preserve one-use request binding and truthful receipts. Unsupported tasks must be reported as unsupported rather than fabricated.
5. No speaker-auth claims until real opt-in enrollment, voice embedding matching, replay/spoof defense, lockouts, accessibility fallback and device biometrics are implemented and validated.
6. Maintain Turkish UI localization; clear permission denial/fallback; offline-first local history.
7. Build with Swift 6 compatible conventions as feasible, incremental tests, dependency injection, small reviewable patches.
8. Check build/test, report exactly what was verified. Don't claim Xcode builds unless actually run. All logs redact raw audio, tokens, secrets and personally identifying content.
9. Start with the P0 instruction in CODEX_START_HERE.md, then ROADMAP order.

10. The user owns JARVIS prompts, instruction/response datasets and fine-tuned adapter; third-party base model/runtime licenses remain applicable. Do not auto-export personal memories into datasets or upload them. Mobile inference uses a verified owner-selected GGUF and no cloud API.

11. The owner defines the on-device model's system prompt in app settings; do not inject an additional hardcoded behavioral policy. Output length, context, sampling and training hyperparameters are owner-configurable, subject only to actual runtime/device capability. Preserve exact user-command binding for executable actions, local model integrity, and encryption.

12. The owner may import GGUF models with arbitrary filenames and descriptive metadata; verify actual GGUF structure and checksum instead of filtering by file extension. OwnerActionHandler extends actionable tools without editing a central tool allowlist. Missing handlers cannot fake success, and model output cannot authorize an action.
