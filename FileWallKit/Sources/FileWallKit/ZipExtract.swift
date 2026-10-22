import Foundation

/// Unzip and Word text, decoded inside the kit so the app and the tests share one implementation.
public enum ZipExtract {
    /// Every file in a zip (folders and Mac metadata skipped), with its base name and bytes.
    public static func files(in data: Data) throws -> [(name: String, data: Data)] {
        let reader = try ZipReader(data: data)
        var out: [(name: String, data: Data)] = []
        for entry in reader.entries where !entry.name.hasSuffix("/") && !entry.name.hasPrefix("__MACOSX") {
            let name = (entry.name as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            out.append((name: name, data: try reader.data(for: entry)))
        }
        return out
    }

    /// Plain text of a .docx file: the text runs of each paragraph, one line per paragraph.
    public static func docxText(_ data: Data) throws -> String {
        let reader = try ZipReader(data: data)
        guard let entry = reader.entries.first(where: { $0.name == "word/document.xml" }) else { return "" }
        let xml = String(decoding: try reader.data(for: entry), as: UTF8.self)
        let run = try NSRegularExpression(pattern: "<w:t(?:\\s[^>]*)?>([^<]*)</w:t>")
        let lines = xml.components(separatedBy: "</w:p>").map { paragraph -> String in
            let ns = paragraph as NSString
            return run.matches(in: paragraph, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range(at: 1)) }
                .joined()
        }
        return unescape(lines.joined(separator: "\n"))
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
