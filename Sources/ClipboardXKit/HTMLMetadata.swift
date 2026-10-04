import Foundation

public struct PageMetadata: Equatable, Sendable {
    public var title: String?
    public var imageURL: URL?
    public var iconURL: URL?
}

/// Reads a page's title, social image and icon out of its HTML. Used when the system's link fetcher cannot load a page.
/// Only the first 256 KB are looked at, and only http(s) URLs are accepted.
public enum HTMLMetadata {
    private static let readLimit = 256_000

    public static func parse(_ html: String, base: URL) -> PageMetadata {
        let head = String(html.prefix(readLimit))
        var og: String?, twitter: String?, image: String?, icon: String?
        for tag in matches(#"<meta\b[^>]*>"#, in: head) {
            let attrs = attributes(of: tag)
            let key = (attrs["property"] ?? attrs["name"])?.lowercased()
            guard let content = attrs["content"] else { continue }
            switch key {
            case "og:title": og = og ?? content
            case "twitter:title": twitter = twitter ?? content
            case "og:image", "og:image:url", "twitter:image": image = image ?? content
            default: break
            }
        }
        for tag in matches(#"<link\b[^>]*>"#, in: head) {
            let attrs = attributes(of: tag)
            if let rel = attrs["rel"]?.lowercased(), rel.contains("icon"), let href = attrs["href"] { icon = icon ?? href }
        }
        var title = og ?? twitter
        if title == nil, let raw = firstCapture(#"<title[^>]*>(.*?)</title>"#, in: head) { title = raw }
        return PageMetadata(title: clean(title), imageURL: image.flatMap { resolve($0, base: base) },
                            iconURL: (icon.flatMap { resolve($0, base: base) }) ?? resolve("/favicon.ico", base: base))
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func attributes(of tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: #"([a-zA-Z:_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#) else { return [:] }
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            guard let name = Range(match.range(at: 1), in: tag) else { continue }
            let value = (Range(match.range(at: 2), in: tag) ?? Range(match.range(at: 3), in: tag)).map { String(tag[$0]) } ?? ""
            result[String(tag[name]).lowercased()] = value
        }
        return result
    }

    private static func resolve(_ raw: String, base: URL) -> URL? {
        let text = decode(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = decode(raw).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func decode(_ text: String) -> String {
        var out = text
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        guard let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) else { return out }
        for match in regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
            if let whole = Range(match.range, in: out), let number = Range(match.range(at: 1), in: out),
               let code = UInt32(out[number]), let scalar = Unicode.Scalar(code) {
                out.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return out
    }
}
