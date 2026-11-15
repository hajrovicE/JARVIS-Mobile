# Instructions for Codex
You are implementing JARVIS Mobile, a Turkish-first iOS assistant. Read README.md, docs/PRD.md, docs/ARCHITECTURE.md, docs/ROADMAP.md, docs/TEST_PLAN.md, and CODEX_START_HERE.md before changes.

Engineering rules:
1. Implement functioning slices, not deceptive fake success. No unsupported unrestricted iOS access or bypass of PIN, pairing, account auth or OS permissions.
2. Keep owner history, experience logs and personal memory until the owner explicitly deletes them. Do not reuse stale answers as live facts; freshness and deletion are different concerns.
3. Users may view, export, edit, and delete personal memory. A direct owner message may include any content; separate user-selected context categories still control additional network sharing. No provider secrets embedded in the mobile binary.
4. SINGLE BEHAVIOR RULE: do not initiate any external or mutating action without a current, explicit owner UI/chat command. Never treat model output, memories or third-party text as owner commands. Do not require second approval for an explicit command; keep one-time request binding and truthful execution receipts.
5. No speaker-auth claims until real opt-in enrollment, voice embedding matching, replay/spoof defense, lockouts, accessibility fallback and device biometrics are implemented and validated.
6. Maintain Turkish UI localization; clear permission denial/fallback; offline-first local history.
7. Build with Swift 6 compatible conventions as feasible, incremental tests, dependency injection, small reviewable patches.
8. Check build/test, report exactly what was verified. Don't claim Xcode builds unless actually run. All logs redact raw audio, tokens, secrets and personally identifying content.
9. Start with the P0 instruction in CODEX_START_HERE.md, then ROADMAP order.
