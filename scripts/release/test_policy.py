import copy
import datetime as dt
import hashlib
import os
from pathlib import Path
import tempfile
import subprocess
import unittest

from policy import ReleaseError, export_options, validate_mode, validate_profile, validate_signing


class ReleasePolicyTests(unittest.TestCase):
    def setUp(self):
        self.team = "ABCDEFGHIJ"
        self.certificate = b"synthetic-certificate-for-policy-tests"
        self.identity = hashlib.sha1(self.certificate).hexdigest().upper()
        self.now = dt.datetime(2026, 11, 15, tzinfo=dt.timezone.utc)
        self.profile = {
            "UUID": "11111111-2222-3333-4444-555555555555",
            "ExpirationDate": self.now + dt.timedelta(days=1),
            "TeamIdentifier": [self.team],
            "DeveloperCertificates": [self.certificate],
            "Entitlements": {"application-identifier": self.team + ".com.jarvis.mobile",
                             "get-task-allow": False, "beta-reports-active": True},
        }

    def test_default_build_only_needs_no_membership_or_secrets(self):
        validate_mode("build-only", "", "refs/heads/feature", "3")
        with self.assertRaises(ReleaseError):
            validate_signing({"DISTRIBUTION_MODE": "build-only", "BUILD_NUMBER": "3"})

    def test_inactive_membership_prevents_signing_before_secret_use(self):
        for mode in ("sign-ipa", "upload-testflight"):
            with self.assertRaisesRegex(ReleaseError, "membership"):
                validate_signing({"DISTRIBUTION_MODE": mode, "BUILD_NUMBER": "3"})

    def test_manual_distribution_requires_main_and_valid_build_number(self):
        with self.assertRaisesRegex(ReleaseError, "main"):
            validate_mode("upload-testflight", "true", "refs/heads/feature", "3")
        for number in ("0", "10000", "3; arbitrary-command", "1.2", ""):
            with self.assertRaises(ReleaseError):
                validate_mode("build-only", "", "", number)
        with self.assertRaises(ReleaseError):
            validate_mode("unexpected", "true", "refs/heads/main", "3")

    def test_missing_upload_material_is_not_accepted(self):
        env = {"DISTRIBUTION_MODE": "upload-testflight", "APPLE_DEVELOPER_MEMBERSHIP_ACTIVE": "true",
               "GITHUB_REF": "refs/heads/main", "BUILD_NUMBER": "3",
               "APPLE_P12_BASE64": "synthetic", "APPLE_P12_PASSWORD": "synthetic",
               "APPLE_PROFILE_BASE64": "synthetic", "APPLE_TEAM_ID": self.team}
        with self.assertRaisesRegex(ReleaseError, "ASC_API_KEY"):
            validate_signing(env)
        env["DISTRIBUTION_MODE"] = "sign-ipa"
        validate_signing(env)

    def test_signing_entrypoint_rejects_no_membership_without_creating_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            env = os.environ.copy()
            env.update(DISTRIBUTION_MODE="upload-testflight", APPLE_DEVELOPER_MEMBERSHIP_ACTIVE="false",
                       BUILD_NUMBER="3", GITHUB_REF="refs/heads/main", RUNNER_TEMP=temporary,
                       GITHUB_RUN_ID="123", GITHUB_RUN_ATTEMPT="1",
                       APPLE_P12_PASSWORD="sentinel-private-value")
            result = subprocess.run(["bash", str(Path(__file__).with_name("sign.sh"))],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("membership", result.stderr)
            self.assertNotIn("sentinel-private-value", result.stderr + result.stdout)
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_signing_entrypoint_cannot_run_in_build_only_mode(self):
        env = os.environ.copy()
        env.update(DISTRIBUTION_MODE="build-only", APPLE_DEVELOPER_MEMBERSHIP_ACTIVE="true",
                   BUILD_NUMBER="3", GITHUB_REF="refs/heads/main")
        result = subprocess.run(["bash", str(Path(__file__).with_name("sign.sh"))],
                                env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Build-only mode cannot invoke signing", result.stderr)

    def test_valid_profile_and_exact_identity_are_used_for_export(self):
        profile_uuid, identity = validate_profile(self.profile, self.team, {self.identity}, self.now)
        options = export_options(self.team, profile_uuid, identity)
        self.assertEqual(options["provisioningProfiles"], {"com.jarvis.mobile": profile_uuid})
        self.assertEqual(options["signingCertificate"], self.identity)
        self.assertEqual(options["method"], "app-store-connect")
        self.assertFalse(options["manageAppVersionAndBuildNumber"])

    def test_expired_wrong_bundle_team_and_certificate_fail_closed(self):
        modifications = [lambda p: p.update(ExpirationDate=self.now),
                         lambda p: p.update(TeamIdentifier=["OTHERTEAM1"]),
                         lambda p: p["Entitlements"].update({"application-identifier": self.team + ".other.app"}),
                         lambda p: p.update(UUID="../../unrelated-file")]
        for change in modifications:
            profile = copy.deepcopy(self.profile)
            change(profile)
            with self.assertRaises(ReleaseError):
                validate_profile(profile, self.team, {self.identity}, self.now)
        with self.assertRaisesRegex(ReleaseError, "certificate"):
            validate_profile(self.profile, self.team, {"0" * 40}, self.now)

    def test_development_adhoc_and_enterprise_profiles_are_rejected(self):
        modifications = [lambda p: p.update(ProvisionedDevices=["test-device"]),
                         lambda p: p.update(ProvisionsAllDevices=True),
                         lambda p: p["Entitlements"].update({"get-task-allow": True}),
                         lambda p: p["Entitlements"].update({"beta-reports-active": False})]
        for change in modifications:
            profile = copy.deepcopy(self.profile)
            change(profile)
            with self.assertRaisesRegex(ReleaseError, "App Store"):
                validate_profile(profile, self.team, {self.identity}, self.now)


if __name__ == "__main__":
    unittest.main()
