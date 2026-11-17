import Foundation

/// Transparent offline retrieval: Turkish lexical normalization, a small documented
/// synonym vocabulary and evidence metadata. This is not an embedding model.
/// Selection never deletes owner history or turns context text into an action.
public enum LocalConversationContext {
    public static let maxCharacters = 3_600
    public static let maxEntries = 7

    private struct Candidate {
        let id: String
        let content: String
        let weight: Int
        let time: Date
    }

    public static func select(state: MemorySnapshot, query: String,
                              consent: AISharingConsent, now: Date = Date()) -> [AIContextEntry] {
        let terms = words(query)
        let historical = asksForHistory(query)
        // An explicit owner request to use every personal record is different
        // from normal relevance retrieval. Keep whole facts; the native context
        // window reports overflow rather than silently dropping owner-selected data.
        if consent.personalMemory && asksForAllPersonalMemory(query) {
            return state.personal.filter { $0.createdAt <= now }.map {
                AIContextEntry(id: "personal:\($0.id)", text: $0.text)
            }
        }
        let personalOverview = asksForPersonalOverview(query)
        var candidates: [Candidate] = []

        if consent.confirmedLearning {
            // Imported legacy state can contain two confirmed records under the same
            // key. A correction wins; historic revisions never enter model context.
            let eligible = state.learning.records.filter {
                usable($0, now: now, historical: historical)
            }
            let grouped = Dictionary(grouping: eligible, by: { normalized($0.key) })
            let preferred = grouped.values.compactMap { values in
                values.sorted {
                    let left = $0.source == .userCorrection, right = $1.source == .userCorrection
                    if left != right { return left }
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    return $0.id.uuidString < $1.id.uuidString
                }.first
            }
            for record in preferred {
                let text = record.key + ": " + record.text
                let score = overlap(text, terms)
                guard score > 0 || isGlobalOwnerRule(record) else { continue }
                let sourceWeight: Int
                switch record.source {
                case .userCorrection: sourceWeight = 95
                case .userInput: sourceWeight = 60
                case .taskResult: sourceWeight = verifiedTask(for: record, in: state.learning) ? 50 : 10
                case .externalSource: sourceWeight = trustedExternal(record) ? 30 : 0
                }
                let provenance = record.provenance.sourceURL?.absoluteString ?? record.provenance.sourceID
                let label = "[öğrenme; kaynak=\(record.source.rawValue):\(provenance); güven=\(record.confidence); kayıt=\(stamp(record.updatedAt)); \(freshness(record, now))]"
                candidates.append(.init(id: "learning:\(record.id)", content: label + "\n" + text,
                    weight: 100 + sourceWeight + score * 25, time: record.updatedAt))
            }
            // Completed tool results are evidence only with a real execution receipt.
            // Proposed/model-created task prose must never become learned evidence.
            for item in state.learning.experiences where item.createdAt <= now &&
                item.outcome == .succeeded && nonempty(item.executionReceipt) {
                guard let result = item.result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      result != "completed" else { continue }
                let text = item.action + ": " + result
                let score = overlap(text, terms)
                guard score > 0 else { continue }
                candidates.append(.init(id: "experience:\(item.id)",
                    content: "[makbuzlu görev sonucu; kayıt=\(stamp(item.createdAt)); güncel dış bilgi kanıtı değildir]\n" + text,
                    weight: 90 + score * 25, time: item.createdAt))
            }
        }
        if consent.personalMemory {
            for item in state.personal where item.createdAt <= now {
                let score = overlap(item.text, terms)
                guard score > 0 || personalOverview else { continue }
                candidates.append(.init(id: "personal:\(item.id)", content: item.text,
                    weight: 160 + score * 25, time: item.createdAt))
            }
        }
        if consent.recentHistory {
            let historyByID = Dictionary(state.generatedAnswers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let followup = isFollowUp(query)
            let local = state.conversations.filter { $0.createdAt <= now }
                .suffix(12)
            for (index, item) in local.enumerated() {
                guard !item.text.contains("Kişisel hafıza komutu işlendi.") else { continue }
                let score = overlap(item.text, terms)
                guard score > 0 || (followup && index >= max(0, local.count - 2)) else { continue }
                candidates.append(.init(id: "conversation:\(item.id)", content: item.text,
                    weight: (followup ? 210 : 65) + score * 15, time: item.createdAt))
            }
            let answers = state.generatedAnswers.filter { $0.savedAt <= now && $0.response.generatedAt <= now }
                .suffix(12)
            for (index, item) in answers.enumerated() {
                guard permitsHistory(item, state: state, consent: consent, historyByID: historyByID) else { continue }
                let text = "Kullanıcı: \(item.question)\nJARVIS: \(item.response.text)"
                let score = overlap(text, terms)
                guard score > 0 || (followup && index >= max(0, answers.count - 2)) else { continue }
                // Dialogue can resolve references; a past model answer is not verified fact.
                candidates.append(.init(id: "answer:\(item.id)",
                    content: "[önceki konuşma; yanıt doğrulanmış güncel bilgi değildir]\n" + text,
                    weight: (followup ? 215 : 70) + score * 15, time: item.savedAt))
            }
        }
        let ranked = candidates.sorted {
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            if $0.time != $1.time { return $0.time > $1.time }
            return $0.id < $1.id
        }
        var selected: [AIContextEntry] = []
        var used = 0
        var seen = Set<String>()
        for item in ranked {
            guard selected.count < maxEntries else { break }
            let content = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Never cut a saved fact in the middle: dropping a late negation or
            // qualification can invert its meaning. Skip it if it cannot fit whole.
            guard !content.isEmpty, content.count <= maxCharacters - used,
                  seen.insert(content).inserted else { continue }
            selected.append(.init(id: item.id, text: content))
            used += content.count
        }
        return selected
    }

    /// Current external facts require actual, owner-confirmed evidence. Personal
    /// preferences and past AI replies cannot establish a live exchange rate/weather.
    public static func hasFreshEvidence(state: MemorySnapshot, query: String,
                                        consent: AISharingConsent, now: Date = Date(),
                                        selectedContext: [AIContextEntry]? = nil) -> Bool {
        guard consent.confirmedLearning else { return false }
        let terms = words(query)
        let ageLimit = liveEvidenceAge(query)
        let selectedIDs = Set((selectedContext ?? select(state: state, query: query, consent: consent, now: now)).map(\.id))
        return state.learning.records.contains { record in
            guard record.kind == .knowledge, selectedIDs.contains("learning:\(record.id)"),
                  usable(record, now: now, historical: false),
                  record.confidence >= 0.75, let expiry = record.expiresAt, expiry > now,
                  now.timeIntervalSince(record.provenance.capturedAt) <= ageLimit,
                  Double(overlap(record.key + " " + record.text, terms)) >= max(1, ceil(Double(terms.count) * 0.6)) else { return false }
            switch record.source {
            case .userInput, .userCorrection: return true
            case .externalSource: return trustedExternal(record)
            case .taskResult: return verifiedTask(for: record, in: state.learning)
            }
        }
    }

    public static func isFollowUp(_ query: String) -> Bool {
        let text = normalized(query)
        if ["onceki mesaj", "son mesaj", "az once", "son konusma", "ne demistin"].contains(where: { text.contains($0) }) { return true }
        let references = ["devam", "baska", "bir tane daha", "biraz daha", "daha fazla", "bunu", "onu", "bunlari", "peki"]
        return words(query).count <= 2 && references.contains { text.contains($0) }
    }

    private static func usable(_ record: LearnedMemory, now: Date, historical: Bool) -> Bool {
        guard record.userConfirmed, record.supersededBy == nil,
              record.createdAt <= now, record.updatedAt <= now, record.provenance.capturedAt <= now,
              record.confidence.isFinite, (0...1).contains(record.confidence),
              nonempty(record.provenance.sourceID), nonempty(record.text) else { return false }
        if let expiry = record.expiresAt, expiry <= now, !historical { return false }
        if record.kind == .knowledge, !historical {
            guard record.confidence >= 0.5 else { return false }
            if record.source == .externalSource, !trustedExternal(record) { return false }
        }
        return true
    }

    private static func permitsHistory(_ answer: StoredAIAnswer, state: MemorySnapshot,
                                       consent: AISharingConsent, historyByID: [UUID: StoredAIAnswer]) -> Bool {
        // Follow older answer-only ancestry too: previous schema-v3 records
        // may carry a derived category without the original source IDs. Use an
        // iterative walk so long/cyclic imported histories cannot recurse forever.
        var pending = [answer]
        var visited = Set<UUID>()
        while let current = pending.popLast() {
            guard visited.insert(current.id).inserted else { continue }
            for id in current.contextIDs {
                if (id.hasPrefix("personal:") || id == "derived:personal"), !consent.personalMemory { return false }
                if (id.hasPrefix("learning:") || id.hasPrefix("experience:") || id == "derived:learning"), !consent.confirmedLearning { return false }
                if id.hasPrefix("learning:"), let uuid = UUID(uuidString: String(id.dropFirst("learning:".count))) {
                    guard let record = state.learning.records.first(where: { $0.id == uuid }),
                          record.userConfirmed, record.supersededBy == nil,
                          record.updatedAt <= current.savedAt else { return false }
                }
                if id.hasPrefix("personal:"), let uuid = UUID(uuidString: String(id.dropFirst("personal:".count))) {
                    guard let record = state.personal.first(where: { $0.id == uuid }),
                          (record.updatedAt ?? record.createdAt) <= current.savedAt else { return false }
                }
                if id.hasPrefix("experience:"), let uuid = UUID(uuidString: String(id.dropFirst("experience:".count))),
                   !state.learning.experiences.contains(where: { $0.id == uuid }) { return false }
                if id.hasPrefix("answer:"), let uuid = UUID(uuidString: String(id.dropFirst("answer:".count))) {
                    guard let parent = historyByID[uuid] else { return false }
                    pending.append(parent)
                }
            }
        }
        return true
    }

    private static func verifiedTask(for record: LearnedMemory, in state: LearningState) -> Bool {
        guard let id = UUID(uuidString: record.provenance.sourceID) else { return false }
        return state.experiences.contains { $0.id == id && $0.outcome == .succeeded && nonempty($0.executionReceipt) }
    }
    private static func trustedExternal(_ record: LearnedMemory) -> Bool {
        record.provenance.sourceURL?.scheme?.lowercased() == "https" &&
            nonempty(record.provenance.sourceURL?.host) && nonempty(record.provenance.sourceID)
    }
    private static func isGlobalOwnerRule(_ record: LearnedMemory) -> Bool {
        record.kind == .rule && (record.source == .userInput || record.source == .userCorrection) &&
            ["owner.directive.", "response.", "yanit.", "cevap."].contains { record.key.hasPrefix($0) }
    }
    private static func freshness(_ record: LearnedMemory, _ now: Date) -> String {
        guard let expiry = record.expiresAt else { return "güncellik süresi belirtilmemiş" }
        return expiry > now ? "geçerlilik=\(stamp(expiry))" : "geçerlilik sona ermiş tarihsel kayıt"
    }
    private static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func nonempty(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    private static func liveEvidenceAge(_ query: String) -> TimeInterval {
        let terms = words(query)
        if !terms.isDisjoint(with: ["fiyat", "kur", "dolar", "euro", "borsa", "trafik"]) { return 15 * 60 }
        if terms.contains("hava") { return 3 * 3600 }
        return 24 * 3600
    }
    private static func asksForAllPersonalMemory(_ query: String) -> Bool {
        let text = normalized(query)
        let tokens = Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted))
        let all = !tokens.isDisjoint(with: ["tum", "butun", "hepsi", "tamamini"])
        return all && ["kisisel hafiza", "hafiza kayit", "kisisel kayit"].contains { text.contains($0) }
    }
    private static func asksForPersonalOverview(_ query: String) -> Bool {
        let text = normalized(query)
        return ["beni taniyan", "beni tanidigin", "tercihlerime gore", "hakkimda bildik"].contains { text.contains($0) }
    }
    private static func asksForHistory(_ query: String) -> Bool {
        let text = normalized(query)
        return ["eski", "gecmis", "daha once", "onceki", "tarihsel"].contains { text.contains($0) }
    }
    private static func overlap(_ text: String, _ terms: Set<String>) -> Int { words(text).intersection(terms).count }
    private static func normalized(_ text: String) -> String {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i")
    }
    private static let stopWords: Set<String> = ["ben", "benim", "bana", "beni", "sen", "sana", "biz", "siz", "bir", "bu", "su", "ve", "ile", "icin", "gibi", "olan", "olarak", "ne", "nedir", "neydi", "nasil", "neden", "hangi", "hangisi", "lutfen", "hakkinda", "daha", "tane", "baska", "oner", "devam", "peki", "bunu", "onu", "bugun", "simdi", "guncel", "durum", "son", "kac", "derece"]
    private static let aliases: [String: String] = [
        "espresso": "kahve", "latte": "kahve", "cappuccino": "kahve", "kahvem": "kahve", "kahveyi": "kahve", "kahvemi": "kahve", "kahvenin": "kahve",
        "tercihim": "tercih", "tercihimi": "tercih", "severim": "tercih", "seviyorum": "tercih", "sevdigim": "tercih", "favori": "tercih", "begeniyorum": "tercih", "preference": "tercih",
        "guzergah": "rota", "route": "rota", "yolculuk": "rota", "roman": "kitap", "kitab": "kitap", "eser": "kitap", "sicaklik": "hava", "yagmur": "hava", "weather": "hava", "temperature": "hava", "forecast": "hava", "bedel": "fiyat", "ucret": "fiyat", "price": "fiyat", "cost": "fiyat", "forex": "kur", "currency": "kur", "fiyati": "fiyat", "versiyon": "surum"
    ]
    private static func words(_ text: String) -> Set<String> {
        Set(normalized(text).components(separatedBy: CharacterSet.alphanumerics.inverted).compactMap { word in
            guard word.count >= 3, !stopWords.contains(word) else { return nil }
            if let alias = aliases[word] { return alias }
            var stem = word
            for suffix in ["lerindeydik", "larindaydik", "lerinizden", "larinizdan", "lerimiz", "larimiz", "lerden", "lardan", "lerinin", "larinin", "lerini", "larini", "lerin", "larin", "lerden", "lardan", "ler", "lar", "imiz", "umuz", "iniz", "unuz", "nin", "dan", "den", "dir", "tir", "im", "um", "in", "un", "yi", "yu", "si", "su", "da", "de"] {
                if stem.hasSuffix(suffix), stem.count - suffix.count >= 3 {
                    stem = String(stem.dropLast(suffix.count)); break
                }
            }
            return aliases[stem] ?? stem
        })
    }
}
