import Foundation

/// Conservative credential-pattern guard, not a general PII classifier or proof of safe content.
/// It never logs matching text. Sharing still requires informed user opt-in.
public enum CredentialFilter {
    public static func containsCredential(_ text: String) -> Bool {
        let patterns = [
            #"\bsk-[A-Za-z0-9_-]{16,}"#,
            #"\bgh[pousr]_[A-Za-z0-9]{20,}"#,
            #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
            #"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"#,
            #"\b(?:[A-Za-z0-9]+[_ -])?(?:api[_ -]?key|access[_ -]?token|authorization|password|parola|şifre|sifre|secret)\s*[:=]\s*\S{4,}"#,
            #"\bBearer\s+[A-Za-z0-9._~-]{12,}"#,
            #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
            #"https?://[^/\s:@]+:[^/\s@]+@"#,
            #"[?&](?:api_key|token|access_token|secret|password|sig|signature|x-amz-signature)=[^&#\s]{4,}"#,
            #"\b(?:otp|tek kullanımlık kod|doğrulama kodu)\s*[:=]?\s*\d{4,8}\b"#
        ]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}
