import Foundation

/// Ask AI on iOS: the same Gemini calls as the Android app. The key comes from the
/// app's Info.plist key `GEMINI_API_KEY`, set in the Xcode target's Info tab.
enum GeminiClient {
    struct Turn: Equatable {
        let fromUser: Bool
        let text: String
    }

    enum Failure: LocalizedError {
        case noKey, noAnswer, http(Int)
        var errorDescription: String? {
            switch self {
            case .noKey: return "The Gemini key is missing from the app's Info settings."
            case .noAnswer: return "No answer from Gemini."
            case .http(let code): return "Gemini returned an error (\(code))."
            }
        }
    }

    static let models = ["gemini-3.8-flash", "gemini-3.6-flash"]
    private static let system = "You help the user with their own files. When context is given, answer from it and say clearly when the answer is not in it. Keep answers short and plain. The document text is split into pages marked '=== Page N ===='. When your answer comes from one specific page, end your reply with a final line exactly: PAGE: N. Otherwise write no PAGE line."

    static var apiKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String
    }

    static func ask(_ question: String, context: String, history: [Turn]) async throws -> String {
        guard let key = apiKey, !key.isEmpty else { throw Failure.noKey }
        let body = requestBody(question: question, context: context, history: history)
        var lastError: Error = Failure.noAnswer
        for model in models {
            do { return try await post(model: model, key: key, body: body) } catch { lastError = error }
        }
        throw lastError
    }

    /// Three questions a reader would ask about this document, written from its text.
    static func suggestQuestions(context: String) async throws -> [String] {
        let prompt = "Write exactly 3 short questions a reader would ask about this document, based only on its text. One question per line. No numbering, no bullets, no answers. Keep each under 60 characters."
        let answer = try await ask(prompt, context: context, history: [])
        let lines = answer.split(whereSeparator: \.isNewline).map { line -> String in
            var t = line.trimmingCharacters(in: .whitespaces)
            t = t.replacingOccurrences(of: "^[-*•]\\s*", with: "", options: .regularExpression)
            t = t.replacingOccurrences(of: "^\\d+[.)]\\s*", with: "", options: .regularExpression)
            return t
        }
        return lines.filter { !$0.isEmpty && $0.count <= 60 && !$0.hasPrefix("PAGE") }.prefix(3).map { $0 }
    }

    private static func requestBody(question: String, context: String, history: [Turn]) -> [String: Any] {
        var contents: [[String: Any]] = history.map {
            ["role": $0.fromUser ? "user" : "model", "parts": [["text": $0.text]]]
        }
        let prompt = context.isEmpty ? question : "Context:\n\(context)\n\nQuestion: \(question)"
        contents.append(["role": "user", "parts": [["text": prompt]]])
        return ["system_instruction": ["parts": [["text": system]]], "contents": contents]
    }

    private static func post(model: String, key: String, body: [String: Any]) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else { throw Failure.http(code) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else { throw Failure.noAnswer }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
