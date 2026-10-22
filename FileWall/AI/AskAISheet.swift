import SwiftUI
import PDFKit

/// Consent for Ask AI. Visible items remember the choice; hidden items are asked every time.
enum AIConsent {
    static let allFilesKey = "ai_allow_all_files"

    static func allowed(for item: VaultFileSnapshot) -> Bool {
        if item.isHidden { return false }
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: allFilesKey) || defaults.bool(forKey: "ai_doc_\(item.id.uuidString)")
    }

    static func remember(for item: VaultFileSnapshot) {
        guard !item.isHidden else { return }
        UserDefaults.standard.set(true, forKey: "ai_doc_\(item.id.uuidString)")
    }
}

/// Reads the text of a decrypted preview file (PDF or plain text).
enum DocText {
    static func read(url: URL) -> String {
        if url.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: url) {
            return doc.string ?? ""
        }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

struct AskAISheet: View {
    let item: VaultFileSnapshot
    let side: VaultSideSelector

    @Environment(\.dismiss) private var dismiss
    @State private var allowed = false
    @State private var context = ""
    @State private var suggestions: [String] = []
    @State private var turns: [GeminiClient.Turn] = []
    @State private var input = ""
    @State private var sending = false

    var body: some View {
        NavigationView {
            Group {
                if allowed { chat } else { consentCard }
            }
            .navigationTitle("Ask AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .onAppear { allowed = AIConsent.allowed(for: item) }
        .task(id: allowed) { if allowed { await prepare() } }
    }

    private var consentCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send to Google Gemini?").font(.title3.bold())
            Text(item.isHidden
                 ? "This item is in the hidden vault, so you are asked every time. Nothing is remembered."
                 : "To answer, FileWall sends the text it needs to Google Gemini. Choose Not now and nothing is sent. Your choice is remembered for this item.")
                .foregroundColor(.secondary)
            HStack {
                Button("Not now") { dismiss() }
                Spacer()
                Button("Allow") {
                    AIConsent.remember(for: item)
                    allowed = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if turns.isEmpty {
                        Text("Ask about this file").font(.headline)
                        Text("Tap a suggestion, or type your own question.")
                            .foregroundColor(.secondary)
                        ForEach(suggestions, id: \.self) { s in
                            Button(s) { send(s) }.buttonStyle(.bordered)
                        }
                    }
                    ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                        HStack {
                            if turn.fromUser { Spacer() }
                            Text(turn.text)
                                .padding(10)
                                .background(turn.fromUser ? Color.accentColor : Color(.secondarySystemBackground))
                                .foregroundColor(turn.fromUser ? .white : .primary)
                                .cornerRadius(14)
                            if !turn.fromUser { Spacer() }
                        }
                    }
                    if sending { ProgressView("Thinking…") }
                }
                .padding()
            }
            HStack {
                TextField("Type your question", text: $input, onCommit: { send(input) })
                    .textFieldStyle(.roundedBorder)
                Button { send(input) } label: { Image(systemName: "paperplane.fill") }
                    .disabled(sending || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal)
            Text("This is an AI and can make mistakes. The model used here is Gemini by Google Inc.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(8)
        }
    }

    private func prepare() async {
        guard context.isEmpty else { return }
        var text = ""
        if let url = try? await VaultService.shared.decryptToPreviewCache(id: item.id, name: item.name, side: side) {
            text = DocText.read(url: url)
        }
        context = String(text.prefix(60000))
        if !context.isEmpty {
            suggestions = (try? await GeminiClient.suggestQuestions(context: context)) ?? []
        }
    }

    private func send(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !sending else { return }
        let history = turns
        turns.append(GeminiClient.Turn(fromUser: true, text: question))
        input = ""
        sending = true
        Task {
            let answer: String
            do {
                answer = try await GeminiClient.ask(question, context: context, history: Array(history.suffix(8)))
            } catch {
                answer = "Sorry, I couldn't get an answer right now. (\(error.localizedDescription))"
            }
            await MainActor.run {
                turns.append(GeminiClient.Turn(fromUser: false, text: answer))
                sending = false
            }
        }
    }
}
