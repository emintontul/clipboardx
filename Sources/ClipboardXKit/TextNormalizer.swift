import Foundation

/// Search-time text folding: case, Turkish dotted/dotless i, diacritics, spacing and punctuation.
public enum TextNormalizer {
    public static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "İ", with: "i")
            .replacingOccurrences(of: "I", with: "i")
            .replacingOccurrences(of: "ı", with: "i")
            .lowercased()
            .decomposedStringWithCompatibilityMapping
            .unicodeScalars
            .filter { !(0x0300...0x036F).contains($0.value) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    /// Folded text with everything except letters and digits removed: "Togg Lite" and "ToggLite" both become "togglite".
    public static func compact(_ text: String) -> String {
        String(fold(text).filter { $0.isLetter || $0.isNumber })
    }

    public static func tokens(_ text: String) -> [String] {
        fold(text).split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }
}
