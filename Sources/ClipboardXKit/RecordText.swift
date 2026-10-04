import Foundation

/// Reads the searchable text of a stored record back from the blob store.
enum RecordText {
    private static let preferred = ["public.utf8-plain-text", "public.utf16-external-plain-text", "public.text", "public.file-url", "public.html"]

    static func text(for record: ClipRecord, blobs: BlobStore) -> String {
        let grouped = Dictionary(grouping: record.representations, by: \.item)
        var items: [PasteboardItem] = []
        for index in grouped.keys.sorted() {
            var data: [String: Data] = [:]
            for rep in grouped[index] ?? [] where preferred.contains(rep.uti) {
                if let bytes = try? blobs.get(rep.blob) { data[rep.uti] = bytes }
            }
            items.append(PasteboardItem(types: preferred.filter { data[$0] != nil }, dataByType: data))
        }
        return TextExtractor.text(from: items)
    }
}
