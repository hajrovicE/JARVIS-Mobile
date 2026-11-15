import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "ios" / "JarvisMobile" / "JarvisMobileApp.swift"
RUNTIME = ROOT / "ios" / "JarvisMobile" / "GGUFInferenceRuntime.swift"


class LocalOnlyMobileTests(unittest.TestCase):
    def test_iphone_chat_has_no_cloud_provider_or_api_key_route(self):
        text = UI.read_text(encoding="utf-8")
        self.assertNotIn("HTTPRelayAIProvider(", text)
        self.assertNotIn("RelayCredentials.", text)
        self.assertNotIn("relayEndpoint", text)
        self.assertIn("processingMode: .onDevice", text)
        self.assertIn("networkAllowed: false", text)
        self.assertIn("localManifest", "localManifest" if "selectedModelManifest" in text else "")

    def test_llama_inference_is_local_and_owner_command_gate_remains(self):
        text = RUNTIME.read_text(encoding="utf-8")
        self.assertIn("llama_model_load_from_file", text)
        self.assertIn("generationBudget", text)
        self.assertIn("Sahibinin komutu olmadan eylem başlatma", text)
        self.assertNotIn("URLSession", text)
        self.assertNotIn("urllib", text)


if __name__ == "__main__":
    unittest.main()
