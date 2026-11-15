#!/bin/bash
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
python3 "$SCRIPT_DIR/policy.py" check-signing
: "${RUNNER_TEMP:?GitHub runner temp directory required}"
: "${GITHUB_RUN_ID:?GitHub run ID required}"
: "${GITHUB_RUN_ATTEMPT:?GitHub run attempt required}"
case "$GITHUB_RUN_ID:$GITHUB_RUN_ATTEMPT" in *[!0-9:]* ) exit 1 ;; esac
SIGNING_WORK="$RUNNER_TEMP/jarvis-signing-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
mkdir -m 700 "$SIGNING_WORK"
export SIGNING_WORK
trap '"$SCRIPT_DIR/cleanup.sh"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
SIGNING_KEYCHAIN="$SIGNING_WORK/signing.keychain-db"
SIGNING_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
python3 "$SCRIPT_DIR/policy.py" decode APPLE_P12_BASE64 "$SIGNING_WORK/certificate.p12"
python3 "$SCRIPT_DIR/policy.py" decode APPLE_PROFILE_BASE64 "$SIGNING_WORK/profile.mobileprovision"
security cms -D -i "$SIGNING_WORK/profile.mobileprovision" > "$SIGNING_WORK/profile.plist" 2> "$SIGNING_WORK/private.log"
security create-keychain -p "$SIGNING_PASSWORD" "$SIGNING_KEYCHAIN" >> "$SIGNING_WORK/private.log" 2>&1
security set-keychain-settings -lut 3600 "$SIGNING_KEYCHAIN" >> "$SIGNING_WORK/private.log" 2>&1
security unlock-keychain -p "$SIGNING_PASSWORD" "$SIGNING_KEYCHAIN" >> "$SIGNING_WORK/private.log" 2>&1
security import "$SIGNING_WORK/certificate.p12" -k "$SIGNING_KEYCHAIN" -P "$APPLE_P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >> "$SIGNING_WORK/private.log" 2>&1
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$SIGNING_PASSWORD" "$SIGNING_KEYCHAIN" >> "$SIGNING_WORK/private.log" 2>&1
python3 "$SCRIPT_DIR/policy.py" save-keychains "$SIGNING_KEYCHAIN" "$SIGNING_WORK/previous-keychains.json"
security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" > "$SIGNING_WORK/identities.txt" 2>> "$SIGNING_WORK/private.log"
python3 "$SCRIPT_DIR/policy.py" prepare "$SIGNING_WORK/profile.plist" "$SIGNING_WORK/identities.txt" "$SIGNING_WORK/ExportOptions.plist" "$SIGNING_WORK/metadata.json"
PROFILE_UUID="$(python3 -c 'import json,os; print(json.load(open(os.environ["SIGNING_WORK"]+"/metadata.json"))["uuid"])')"
SIGNING_IDENTITY="$(python3 -c 'import json,os; print(json.load(open(os.environ["SIGNING_WORK"]+"/metadata.json"))["identity"])')"
# Xcode's standard profile lookup locations are runner-only. Install only a validated UUID;
# record each path before copy and remove it unconditionally during cleanup.
for PROFILE_DIRECTORY in "$HOME/Library/MobileDevice/Provisioning Profiles" "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"; do
  mkdir -p "$PROFILE_DIRECTORY"
  PROFILE_DESTINATION="$PROFILE_DIRECTORY/$PROFILE_UUID.mobileprovision"
  if [ -e "$PROFILE_DESTINATION" ]; then
    echo 'Refusing to replace an existing provisioning profile.' >&2
    exit 1
  fi
  printf '%s\n' "$PROFILE_DESTINATION" >> "$SIGNING_WORK/installed-profiles.txt"
  cp "$SIGNING_WORK/profile.mobileprovision" "$PROFILE_DESTINATION"
done
RELEASE_OUTPUT="$RUNNER_TEMP/jarvis-release-output"
mkdir -p "$RELEASE_OUTPUT"
echo 'Validated signing configuration. Creating Release archive.'
xcodebuild -project ios/JarvisMobile.xcodeproj -scheme JarvisMobile -configuration Release -destination 'generic/platform=iOS' -archivePath "$SIGNING_WORK/JarvisMobile.xcarchive" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" PROVISIONING_PROFILE_SPECIFIER="$PROFILE_UUID" archive >> "$SIGNING_WORK/private.log" 2>&1
xcodebuild -exportArchive -archivePath "$SIGNING_WORK/JarvisMobile.xcarchive" -exportPath "$RELEASE_OUTPUT" -exportOptionsPlist "$SIGNING_WORK/ExportOptions.plist" >> "$SIGNING_WORK/private.log" 2>&1
if [ ! -f "$RELEASE_OUTPUT/JarvisMobile.ipa" ]; then
  echo 'IPA export did not produce the expected file.' >&2
  exit 1
fi
if [ -d "$SIGNING_WORK/JarvisMobile.xcarchive/dSYMs" ]; then
  ditto -c -k --keepParent "$SIGNING_WORK/JarvisMobile.xcarchive/dSYMs" "$RELEASE_OUTPUT/JarvisMobile-dSYMs.zip"
fi
if [ "$DISTRIBUTION_MODE" = 'upload-testflight' ]; then
  mkdir -m 700 "$SIGNING_WORK/private_keys"
  export API_PRIVATE_KEYS_DIR="$SIGNING_WORK/private_keys"
  python3 "$SCRIPT_DIR/policy.py" decode ASC_API_KEY_P8_BASE64 "$API_PRIVATE_KEYS_DIR/AuthKey_$ASC_API_KEY_ID.p8"
  openssl pkey -in "$API_PRIVATE_KEYS_DIR/AuthKey_$ASC_API_KEY_ID.p8" -noout >> "$SIGNING_WORK/private.log" 2>&1
  xcrun altool --upload-app --type ios --file "$RELEASE_OUTPUT/JarvisMobile.ipa" --apiKey "$ASC_API_KEY_ID" --apiIssuer "$ASC_API_ISSUER_ID" >> "$SIGNING_WORK/private.log" 2>&1
  echo 'Upload request accepted by Apple. Processing and tester availability must be checked in App Store Connect.'
  printf '%s\n' 'Apple accepted the upload request. TestFlight processing/tester availability is not yet verified.' >> "$GITHUB_STEP_SUMMARY"
else
  echo 'Signed IPA exported. No TestFlight upload attempted.'
  printf '%s\n' 'Signed IPA exported; no TestFlight upload attempted.' >> "$GITHUB_STEP_SUMMARY"
fi
