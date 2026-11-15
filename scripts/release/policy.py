#!/usr/bin/env python3
"""Release guards and profile validation. Importing this module performs no deployment."""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import sys
import uuid

BUNDLE_ID = "com.jarvis.mobile"
MODES = {"build-only", "sign-ipa", "upload-testflight"}
SIGNING_SECRETS = ("APPLE_P12_BASE64", "APPLE_P12_PASSWORD", "APPLE_PROFILE_BASE64", "APPLE_TEAM_ID")
UPLOAD_SECRETS = ("ASC_API_KEY_P8_BASE64", "ASC_API_KEY_ID", "ASC_API_ISSUER_ID")


class ReleaseError(ValueError):
    pass


def validate_mode(mode, membership, ref, build_number):
    if mode not in MODES:
        raise ReleaseError("Unknown release mode")
    if not re.fullmatch(r"[1-9][0-9]{0,3}", build_number):
        raise ReleaseError("Build number must be an integer from 1 to 9999")
    if mode != "build-only":
        if membership != "true":
            raise ReleaseError("Active paid Apple Developer membership is required; no signing or upload attempted")
        if ref != "refs/heads/main":
            raise ReleaseError("Signing and upload are allowed only from main")


def validate_signing(env):
    mode = env.get("DISTRIBUTION_MODE", "build-only")
    validate_mode(mode, env.get("APPLE_DEVELOPER_MEMBERSHIP_ACTIVE", "false"),
                  env.get("GITHUB_REF", ""), env.get("BUILD_NUMBER", ""))
    if mode == "build-only":
        raise ReleaseError("Build-only mode cannot invoke signing")
    required = SIGNING_SECRETS + (UPLOAD_SECRETS if mode == "upload-testflight" else ())
    missing = [name for name in required if not env.get(name, "").strip()]
    if missing:
        raise ReleaseError("Required GitHub Secrets missing: " + ", ".join(missing))
    if not re.fullmatch(r"[A-Z0-9]{10}", env["APPLE_TEAM_ID"]):
        raise ReleaseError("Invalid Apple team identifier")
    if mode == "upload-testflight":
        if not re.fullmatch(r"[A-Z0-9]{10}", env["ASC_API_KEY_ID"]):
            raise ReleaseError("Invalid App Store Connect key identifier")
        try:
            uuid.UUID(env["ASC_API_ISSUER_ID"])
        except ValueError as exc:
            raise ReleaseError("Invalid App Store Connect issuer identifier") from exc


def validate_profile(profile, team_id, identity_hashes, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    if not isinstance(profile, dict):
        raise ReleaseError("Malformed distribution profile")
    try:
        profile_uuid = str(uuid.UUID(profile["UUID"])).upper()
        expiry = profile["ExpirationDate"]
        entitlements = profile["Entitlements"]
        certificates = profile["DeveloperCertificates"]
    except (KeyError, TypeError, ValueError) as exc:
        raise ReleaseError("Malformed distribution profile") from exc
    if (not isinstance(expiry, dt.datetime) or not isinstance(entitlements, dict) or
            not isinstance(certificates, list) or not all(isinstance(value, bytes) for value in certificates) or
            not isinstance(profile.get("TeamIdentifier"), list)):
        raise ReleaseError("Malformed distribution profile fields")
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=dt.timezone.utc)
    if expiry <= now:
        raise ReleaseError("Distribution profile has expired")
    if team_id not in profile.get("TeamIdentifier", []):
        raise ReleaseError("Profile does not belong to configured Apple team")
    if entitlements.get("application-identifier") != f"{team_id}.{BUNDLE_ID}":
        raise ReleaseError("Profile application identifier must exactly match the app")
    if (profile.get("ProvisionedDevices") or profile.get("ProvisionsAllDevices") or
            entitlements.get("get-task-allow") is not False or
            entitlements.get("beta-reports-active") is not True):
        raise ReleaseError("An App Store distribution profile is required")
    matches = [hashlib.sha1(cert).hexdigest().upper() for cert in certificates
               if isinstance(cert, bytes)]
    identity = next((value for value in matches if value in identity_hashes), None)
    if not identity:
        raise ReleaseError("Profile certificate does not match imported valid signing identity")
    return profile_uuid, identity


def export_options(team_id, profile_uuid, identity):
    return {"method": "app-store-connect", "destination": "export", "teamID": team_id,
            "signingStyle": "manual", "signingCertificate": identity,
            "provisioningProfiles": {BUNDLE_ID: profile_uuid},
            "manageAppVersionAndBuildNumber": False, "uploadSymbols": True,
            "stripSwiftSymbols": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check-mode", "check-signing", "decode", "prepare", "save-keychains", "restore-keychains"])
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args()
    if args.command == "check-mode":
        validate_mode(os.getenv("DISTRIBUTION_MODE", "build-only"), os.getenv("APPLE_DEVELOPER_MEMBERSHIP_ACTIVE", "false"),
                      os.getenv("GITHUB_REF", ""), os.getenv("BUILD_NUMBER", ""))
    elif args.command == "check-signing":
        validate_signing(os.environ)
    elif args.command == "decode":
        name, output = args.paths
        try:
            value = base64.b64decode("".join(os.environ[name].split()), validate=True)
        except (KeyError, ValueError) as exc:
            raise ReleaseError("Invalid encoded signing material") from exc
        if not value:
            raise ReleaseError("Empty encoded signing material")
        with open(output, "xb") as destination:
            os.chmod(output, 0o600)
            destination.write(value)
    elif args.command == "prepare":
        profile_path, identities_path, options_path, metadata_path = map(Path, args.paths)
        profile = plistlib.loads(profile_path.read_bytes())
        identities = {item.upper() for item in re.findall(r"\b[0-9A-Fa-f]{40}\b", identities_path.read_text())}
        profile_uuid, identity = validate_profile(profile, os.environ["APPLE_TEAM_ID"], identities)
        options_path.write_bytes(plistlib.dumps(export_options(os.environ["APPLE_TEAM_ID"], profile_uuid, identity)))
        metadata_path.write_text(json.dumps({"uuid": profile_uuid, "identity": identity}))
    elif args.command == "save-keychains":
        keychain, backup = args.paths
        previous = shlex.split(subprocess.check_output(["security", "list-keychains", "-d", "user"], text=True))
        Path(backup).write_text(json.dumps(previous))
        subprocess.run(["security", "list-keychains", "-d", "user", "-s", keychain, *previous], check=True, capture_output=True)
    elif args.command == "restore-keychains":
        previous = json.loads(Path(args.paths[0]).read_text())
        subprocess.run(["security", "list-keychains", "-d", "user", "-s", *previous], check=True, capture_output=True)


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        # Never print subprocess output, certificate names, tokens, or decoded signing material.
        print(f"Release configuration rejected: {error if isinstance(error, ReleaseError) else type(error).__name__}", file=sys.stderr)
        sys.exit(1)
