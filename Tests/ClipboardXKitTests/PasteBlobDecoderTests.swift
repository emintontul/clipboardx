import XCTest
import Compression
@testable import ClipboardXKit

final class PasteBlobDecoderTests: XCTestCase {
    private let payload = Data("hello clipboard".utf8)

    private func manifestJSON() throws -> Data {
        let obj: [[String: Any]] = [[
            "types": ["public.utf8-plain-text", "public.html"],
            "dataByType": [
                "public.utf8-plain-text": payload.base64EncodedString(),
                "public.html": Data("<b>hi</b>".utf8).base64EncodedString(),
            ],
        ]]
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private func manifestPlist() throws -> Data {
        let obj: [[String: Any]] = [[
            "types": ["public.utf8-plain-text"],
            "dataByType": ["public.utf8-plain-text": payload],
        ]]
        return try PropertyListSerialization.data(fromPropertyList: obj, format: .binary, options: 0)
    }

    private func compress(_ data: Data, _ algorithm: compression_algorithm) -> Data {
        var out = Data(count: data.count + 4096)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                    src.bindMemory(to: UInt8.self).baseAddress!, src.count,
                    nil, algorithm)
            }
        }
        return out.prefix(n)
    }

    func testDecodesInlineDeflateJSON() throws {
        let blob = Data([0x01]) + compress(try manifestJSON(), COMPRESSION_ZLIB)
        let result = try PasteBlobDecoder.decode(blob, externalDirectory: nil)
        XCTAssertEqual(result.format, .inlineDeflate)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].types, ["public.utf8-plain-text", "public.html"])
        XCTAssertEqual(result.items[0].dataByType["public.utf8-plain-text"], payload)
    }

    func testDecodesInlineLZFSEJSON() throws {
        let blob = Data([0x01]) + compress(try manifestJSON(), COMPRESSION_LZFSE)
        let result = try PasteBlobDecoder.decode(blob, externalDirectory: nil)
        XCTAssertEqual(result.format, .inlineLZFSE)
        XCTAssertEqual(result.items[0].dataByType["public.html"], Data("<b>hi</b>".utf8))
    }

    func testDecodesInlinePlist() throws {
        let blob = Data([0x01]) + (try manifestPlist())
        let result = try PasteBlobDecoder.decode(blob, externalDirectory: nil)
        XCTAssertEqual(result.format, .inlinePlist)
        XCTAssertEqual(result.items[0].dataByType["public.utf8-plain-text"], payload)
    }

    func testDecodesExternalFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let uuid = "ADFAD374-4762-4FD6-B74E-2F357CA79508"
        try compress(try manifestJSON(), COMPRESSION_ZLIB).write(to: dir.appendingPathComponent(uuid))
        let blob = Data([0x02]) + Data(uuid.utf8) + Data([0x00])
        let result = try PasteBlobDecoder.decode(blob, externalDirectory: dir)
        XCTAssertEqual(result.format, .externalDeflate)
        XCTAssertEqual(result.items[0].dataByType["public.utf8-plain-text"], payload)
    }

    func testMissingExternalFileThrowsInsteadOfDropping() {
        let uuid = "00000000-0000-0000-0000-000000000000"
        let blob = Data([0x02]) + Data(uuid.utf8) + Data([0x00])
        let dir = FileManager.default.temporaryDirectory
        XCTAssertThrowsError(try PasteBlobDecoder.decode(blob, externalDirectory: dir)) { error in
            XCTAssertEqual(error as? PasteBlobDecoder.DecodeError, .externalFileMissing(uuid))
        }
    }

    func testUndecodableBlobThrows() {
        let blob = Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try PasteBlobDecoder.decode(blob, externalDirectory: nil))
    }

    func testUnknownTagThrows() {
        XCTAssertThrowsError(try PasteBlobDecoder.decode(Data([0x07, 0x00]), externalDirectory: nil)) { error in
            XCTAssertEqual(error as? PasteBlobDecoder.DecodeError, .unknownTag(7))
        }
    }

    func testTypeOrderIsPreserved() throws {
        let obj: [[String: Any]] = [[
            "types": ["z.last", "a.first", "m.mid"],
            "dataByType": ["a.first": "AA==", "m.mid": "AA==", "z.last": "AA=="],
        ]]
        let json = try JSONSerialization.data(withJSONObject: obj)
        let result = try PasteBlobDecoder.decode(Data([0x01]) + compress(json, COMPRESSION_ZLIB), externalDirectory: nil)
        XCTAssertEqual(result.items[0].types, ["z.last", "a.first", "m.mid"])
    }
}
