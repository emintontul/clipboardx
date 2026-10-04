import Foundation

/// One pasteboard item: ordered UTI list plus the raw bytes for each UTI.
public struct PasteboardItem: Equatable, Sendable {
    public let types: [String]
    public let dataByType: [String: Data]

    public init(types: [String], dataByType: [String: Data]) {
        self.types = types
        self.dataByType = dataByType
    }
}
