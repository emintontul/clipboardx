import Foundation

public enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text, link, image, file

    private static let imageTypes: Set<String> = ["public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif"]

    /// Classifies a clip from its representations and extracted text.
    public static func of(_ record: ClipRecord?, text: String) -> ClipKind {
        guard let record else { return .text }
        let utis = Set(record.representations.map(\.uti))
        if utis.contains("public.file-url") { return .file }
        if !utis.isDisjoint(with: imageTypes), !utis.contains("public.utf8-plain-text") { return .image }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"), URL(string: trimmed)?.host != nil { return .link }
        return .text
    }
}

/// Narrows a listing or search. Every field is optional; an empty value means "no restriction".
public struct ClipFilters: Equatable, Sendable {
    public var kinds: Set<ClipKind>
    public var appName: String?
    public var after: Double?
    public var before: Double?

    public init(kinds: Set<ClipKind> = [], appName: String? = nil, after: Double? = nil, before: Double? = nil) {
        self.kinds = kinds
        self.appName = appName
        self.after = after
        self.before = before
    }

    public var isEmpty: Bool { kinds.isEmpty && appName == nil && after == nil && before == nil }
}
