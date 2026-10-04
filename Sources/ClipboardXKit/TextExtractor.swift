import Foundation

/// Pulls searchable text out of a pasteboard item. Payload bytes stay untouched in the blob store.
public enum TextExtractor {
    public static func text(from items: [PasteboardItem]) -> String {
        items.map(text(from:)).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func text(from item: PasteboardItem) -> String {
        if let data = item.dataByType["public.utf8-plain-text"], let s = String(data: data, encoding: .utf8) { return s }
        if let data = item.dataByType["public.utf16-external-plain-text"], let s = String(data: data, encoding: .utf16) { return s }
        if let data = item.dataByType["public.text"], let s = String(data: data, encoding: .utf8) { return s }
        if let data = item.dataByType["public.file-url"], let s = String(data: data, encoding: .utf8) {
            return s.split(separator: "\n").map { URL(string: String($0))?.path ?? String($0) }.joined(separator: "\n")
        }
        if let data = item.dataByType["public.html"], let s = String(data: data, encoding: .utf8) { return stripHTML(s) }
        return ""
    }

    private static func stripHTML(_ html: String) -> String {
        var out = ""
        var inTag = false
        for ch in html {
            if ch == "<" { inTag = true } else if ch == ">" { inTag = false } else if !inTag { out.append(ch) }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
