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
        self.assertIn("selectedModelManifest", text)
        self.assertIn("ownerInstructions: ownerInstructions", text)
        self.assertIn("maxNewTokens: modelMaxNewTokens", text)
        self.assertIn("contextLength: Int32(clamping: modelContextTokens)", text)
        self.assertIn("temperature: Float(modelTemperature)", text)

    def test_llama_inference_is_local_and_owner_command_gate_remains(self):
        text = RUNTIME.read_text(encoding="utf-8")
        self.assertIn("llama_model_load_from_file", text)
        self.assertIn("generationBudget", text)
        self.assertIn("Sahibinin doğrudan komutu olmadan telefon işlemi başlatma", text)
        self.assertIn("ownerInstructions", text)
        self.assertIn("llama_sampler_chain_init", text)
        self.assertIn("llama_sampler_init_top_p", text)
        self.assertIn("llama_sampler_init_temp", text)
        self.assertIn("llama_sampler_init_dist", text)
        self.assertNotIn("URLSession", text)
        self.assertNotIn("urllib", text)


if __name__ == "__main__":
    unittest.main()
