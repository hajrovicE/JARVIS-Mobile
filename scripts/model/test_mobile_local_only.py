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
        self.assertIn("contextLength: contextTokens", text)
        self.assertIn("temperature: Float(modelTemperature)", text)

    def test_owner_selected_security_gates_are_off(self):
        ui = UI.read_text(encoding="utf-8")
        runtime = (ROOT / "Sources" / "JarvisCore" / "LocalAIProvider.swift").read_text(encoding="utf-8")
        permissions = (ROOT / "Sources" / "JarvisCore" / "PermissionManager.swift").read_text(encoding="utf-8")
        self.assertIn("PlainFileStorage.migratingLegacySnapshot(", ui)
        self.assertNotIn("PlatformSHA256Checker()", ui)
        self.assertNotIn("digester.sha256", runtime)
        self.assertNotIn("authenticator.authenticate(reason:", permissions)
        self.assertNotIn("clock().addingTimeInterval(30)", permissions)
        self.assertIn("request.origin == .userInterface", permissions)

    def test_llama_inference_is_local_and_owner_command_gate_remains(self):
        text = RUNTIME.read_text(encoding="utf-8")
        self.assertIn("llama_model_load_from_file", text)
        self.assertIn("generationBudget", text)
        self.assertIn("ownerInstructions.isEmpty", text)
        self.assertIn("ActionExecutor", text)
        self.assertNotIn("Sen JARVIS isimli, cihaz üzerinde çalışan Türkçe yapay zekâsın", text)
        self.assertIn("ownerInstructions", text)
        self.assertIn("llama_sampler_chain_init", text)
        self.assertIn("llama_sampler_init_top_p", text)
        self.assertIn("llama_sampler_init_temp", text)
        self.assertIn("llama_sampler_init_dist", text)
        self.assertNotIn("URLSession", text)
        self.assertNotIn("urllib", text)


    def test_training_parameters_are_owner_selectable(self):
        script = (ROOT / "scripts" / "model" / "train_lora.py").read_text(encoding="utf-8")
        for flag in ("--thinking", "--lora-rank", "--lora-alpha", "--batch-size",
                     "--accumulation", "--epochs", "--device"):
            self.assertIn(flag, script)

    def test_owner_prompt_is_not_overridden_by_fixed_local_policy(self):
        runtime = RUNTIME.read_text(encoding="utf-8")
        provider = (ROOT / "Sources" / "JarvisCore" / "LocalAIProvider.swift").read_text(encoding="utf-8")
        self.assertIn("if !ownerInstructions.isEmpty", runtime)
        self.assertIn("llama_model_chat_template(model, nil)", runtime)
        self.assertIn("content: try cString(ownerInstructions)", runtime)
        self.assertNotIn("Gereksiz ikinci onay isteme", provider)

if __name__ == "__main__":
    unittest.main()
