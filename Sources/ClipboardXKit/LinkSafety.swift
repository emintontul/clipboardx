import Foundation

/// Decides whether a link may be fetched for a preview. Fetching sends the URL to its server, so anything that points at the
/// local network, carries credentials, or looks like a one-time or tokenized link is never requested.
public enum LinkSafety {
    private static let sensitiveKeys: Set<String> = [
        "token", "access_token", "id_token", "refresh_token", "key", "apikey", "api_key", "sig", "signature", "code", "auth", "authorization",
        "password", "passwd", "pwd", "secret", "session", "sessionid", "session_id", "otp", "jwt", "ticket", "magic",
        "x-amz-signature", "x-amz-credential", "x-amz-security-token", "x-goog-signature",
    ]
    private static let oneTimeWords = ["reset", "verify", "confirm", "magic", "unsubscribe", "invite", "activate", "login", "signin", "oauth"]
    private static let privateSuffixes = [".localhost", ".local", ".lan", ".home.arpa", ".internal"]

    public static func isFetchable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if url.user != nil || url.password != nil { return false }
        if isPrivate(host: host) { return false }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        if (parts.queryItems ?? []).contains(where: { sensitiveKeys.contains($0.name.lowercased()) }) { return false }
        if let fragment = parts.fragment, let items = URLComponents(string: "?" + fragment)?.queryItems,
           items.contains(where: { sensitiveKeys.contains($0.name.lowercased()) }) { return false }
        for segment in parts.path.lowercased().split(separator: "/") {
            for word in oneTimeWords where segment == word || segment.hasPrefix(word + "-") || segment.hasPrefix(word + "_") { return false }
        }
        return true
    }

    private static func isPrivate(host: String) -> Bool {
        if host == "localhost" || privateSuffixes.contains(where: host.hasSuffix) { return true }
        if host.contains(":") { return host == "::1" || host.hasPrefix("fe80") || host.hasPrefix("fc") || host.hasPrefix("fd") }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, octets.count == host.split(separator: ".").count {
            switch (octets[0], octets[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
            case (172, 16...31), (100, 64...127): return true
            case (224..., _): return true
            default: return false
            }
        }
        return !host.contains(".")   // single-label names such as "intranet" are internal
    }
}
