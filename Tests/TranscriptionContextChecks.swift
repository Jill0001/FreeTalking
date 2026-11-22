import Foundation

@main
struct TranscriptionContextChecks {
    static func main() throws {
        precondition(TranscriptionContext.excerpt("").isEmpty)
        precondition(TranscriptionContext.excerpt(" VLA 机器人操作 ") == "VLA 机器人操作")
        let document = String(repeating: "前", count: 4000) + "VLA" + String(repeating: "后", count: 4000)
        let nearby = TranscriptionContext.excerpt(document, caret: 4003)
        precondition(nearby.contains("VLA") && nearby.utf16.count == 200)
        precondition(TranscriptionContext.excerpt(document, caret: 0).allSatisfy { $0 == "前" })
        precondition(TranscriptionContext.excerpt(document).allSatisfy { $0 == "后" })
        precondition(TranscriptionContext.excerpt(document, caret: -1).utf16.count == 200)
        precondition(TranscriptionContext.excerpt(document, caret: Int.max).utf16.count == 200)
        let emoji = String(repeating: "👩🏽‍💻", count: 500)
        let excerpt = TranscriptionContext.excerpt(emoji, caret: 1003)
        precondition(!excerpt.contains("�") && excerpt.allSatisfy { $0 == "👩🏽‍💻" })
        precondition(excerpt.count == 200)
        precondition(TranscriptionContext.excerpt("VLA", limit: 0).isEmpty)
        precondition(TranscriptionContext().prompt.isEmpty)
        for focused in [String(repeating: "中", count: 300), String(repeating: "👩🏽‍💻", count: 300)] {
            let prompt = TranscriptionContext(focusedText: focused).prompt
            let data = prompt.components(separatedBy: "\n").last!.data(using: .utf8)!
            let references = try JSONSerialization.jsonObject(with: data) as! [String: String]
            precondition(Set(references.keys) == ["focused_input"])
            precondition(references["focused_input"]!.count == 200)
        }
        let context = TranscriptionContext(focusedText: "VLA\n\"robot manipulation\"")
        let json = context.prompt.components(separatedBy: "\n").last!.data(using: .utf8)!
        let parsed = try JSONSerialization.jsonObject(with: json) as! [String: String]
        precondition(parsed["focused_input"] == context.focusedText)
        let defaults = UserDefaults(suiteName: "FreeTalking.ContextChecks")!
        defer { defaults.removePersistentDomain(forName: "FreeTalking.ContextChecks") }
        defaults.set(false, forKey: TranscriptionContext.focusedTextKey)
        precondition(TranscriptionContext.capture(defaults: defaults).prompt.isEmpty)
        print("Context checks passed: caret bounds, Unicode, reference encoding, model gating, disabled sources.")
    }
}
