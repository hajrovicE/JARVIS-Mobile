#!/bin/bash
# Also runs as an always() workflow step, in case the signing shell was interrupted.
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
: "${RUNNER_TEMP:?}"
: "${GITHUB_RUN_ID:?}"
: "${GITHUB_RUN_ATTEMPT:?}"
case "$GITHUB_RUN_ID:$GITHUB_RUN_ATTEMPT" in *[!0-9:]* ) exit 1 ;; esac
SIGNING_WORK="$RUNNER_TEMP/jarvis-signing-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
[ -d "$SIGNING_WORK" ] || exit 0
if [ -f "$SIGNING_WORK/installed-profiles.txt" ]; then
  while IFS= read -r installed_profile; do
    profile_filename="${installed_profile##*/}"
    if ! [[ "$profile_filename" =~ ^[A-F0-9]{8}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{12}\.mobileprovision$ ]]; then
      echo 'Unexpected profile filename rejected.' >&2
      continue
    fi
    # Require the exact parent and canonical UUID; a wildcard must never accept nested paths.
    case "$installed_profile" in
      "$HOME/Library/MobileDevice/Provisioning Profiles/$profile_filename"|"$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/$profile_filename") rm -f -- "$installed_profile" ;;
      *) echo 'Unexpected cleanup path rejected.' >&2 ;;
    esac
  done < "$SIGNING_WORK/installed-profiles.txt"
fi
if [ -f "$SIGNING_WORK/previous-keychains.json" ]; then
  python3 "$SCRIPT_DIR/policy.py" restore-keychains "$SIGNING_WORK/previous-keychains.json" >/dev/null 2>&1 || true
fi
security delete-keychain "$SIGNING_WORK/signing.keychain-db" >/dev/null 2>&1 || true
rm -rf -- "$SIGNING_WORK"
