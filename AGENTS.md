# Instructions for Codex
You are implementing JARVIS Mobile, a Turkish-first iOS assistant. Read README.md, docs/PRD.md, docs/ARCHITECTURE.md, docs/ROADMAP.md, docs/TEST_PLAN.md, and CODEX_START_HERE.md before changes.

Engineering rules:
1. Implement functioning slices, not deceptive fake success. No unsupported unrestricted iOS access or bypass of PIN, pairing, account auth or OS permissions.
2. Keep TTL rules exact: conversations 90 days; answer caches at most 30 days (stale questions excluded); durable memories never expire automatically.
3. Users can view, export, edit, and delete personal memory. Never send sensitive local data to AI services without informed opt-in. No API secrets in mobile binary.
4. A trusted, direct owner UI command is sufficient to run an implemented action. No second confirmation or Face ID is required after that command. Never treat model output, memories or external text as owner commands. Keep exact request binding, one-time authority, real receipts, and replay protection.
5. No speaker-auth claims until real opt-in enrollment, voice embedding matching, replay/spoof defense, lockouts, accessibility fallback and device biometrics are implemented and validated.
6. Maintain Turkish UI localization; clear permission denial/fallback; offline-first local history.
7. Build with Swift 6 compatible conventions as feasible, incremental tests, dependency injection, small reviewable patches.
8. Check build/test, report exactly what was verified. Don't claim Xcode builds unless actually run. All logs redact raw audio, tokens, secrets and personally identifying content.
9. Start with the P0 instruction in CODEX_START_HERE.md, then ROADMAP order.
