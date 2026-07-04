import Foundation
import ImageIO

struct MotionPhotoExtractor {
    struct ExtractionResult {
        let mp4URL: URL
        let exifDate: Date?
    }

    // MARK: - Constants

    private static let magicV1 = Data("MotionPhoto_Data".utf8)
    private static let magicV2 = Data("mpvd".utf8)
    private static let jpegSOI = Data([0xFF, 0xD8])
    private static let jpegEOI = Data([0xFF, 0xD9])

    private static let xmpStartTag = Data("<x:xmpmeta".utf8)
    private static let xmpEndTag = Data("</x:xmpmeta>".utf8)

    private static let motionPhotoSemantic = Data(#"Item:Semantic="MotionPhoto""#.utf8)
    private static let lengthAttrPrefix = Data(#"Item:Length=""#.utf8)

    private static let motionPhotoOffsetPrefixes: [Data] = [
        Data(#"GCamera:MotionPhotoOffset=""#.utf8),
        Data(#"Camera:MotionPhotoOffset=""#.utf8),
        Data(#"GCamera:MicroVideoOffset=""#.utf8),
        Data(#"Camera:MicroVideoOffset=""#.utf8),
    ]

    private static let allowedLeadingBoxTypes: Set<String> = ["free", "skip", "wide", "uuid"]

    private static let xmpSearchLimit = 512 << 10      // 512KB
    private static let markerTailSearchSize = 16 << 20  // 16MB
    private static let jpegTailSearchSize = 256 << 10   // 256KB

    // MARK: - Date formatter

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - Public

    static func extractMP4(from jpegURL: URL) throws -> ExtractionResult {
        let data = try Data(contentsOf: jpegURL)
        let exifDate = readEXIFDate(from: jpegURL)

        guard let videoStart = findVideoStart(in: data) else {
            throw ExtractionError.noEmbeddedVideo
        }

        let mp4Data = data.subdata(in: videoStart..<data.count)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        try mp4Data.write(to: tempURL)

        return ExtractionResult(mp4URL: tempURL, exifDate: exifDate)
    }

    // MARK: - Video start detection

    private static func findVideoStart(in data: Data) -> Int? {
        var seen = Set<Int>()

        // Strategy 1: XMP metadata (Item:Length or offset attributes)
        if let videoLength = findMotionPhotoVideoLength(in: data), videoLength > 0, videoLength < data.count {
            let start = data.count - videoLength
            if validateCandidate(data: data, start: start, seen: &seen) {
                return start
            }
        }

        // Strategy 2: "MotionPhoto_Data" marker
        if let start = findMarkerCandidate(data: data, magic: magicV1, seen: &seen) {
            return start
        }

        // Strategy 3: "mpvd" marker
        if let start = findMarkerCandidate(data: data, magic: magicV2, seen: &seen) {
            return start
        }

        return nil
    }

    // MARK: - Strategy 1: XMP metadata

    private static func findMotionPhotoVideoLength(in data: Data) -> Int? {
        let searchArea = data.prefix(xmpSearchLimit)

        // Narrow to XMP block if present
        let effectiveArea: Data
        if let (xmpStart, xmpEnd) = findXMPBlock(in: Data(searchArea)) {
            effectiveArea = searchArea.subdata(in: xmpStart..<xmpEnd)
        } else {
            effectiveArea = Data(searchArea)
        }

        // Try Item:Length in MotionPhoto semantic tag
        if let length = findMotionPhotoItemLength(in: effectiveArea) {
            return length
        }

        // Try offset attributes
        if let offset = findFirstIntAttribute(in: effectiveArea, prefixes: motionPhotoOffsetPrefixes) {
            return offset
        }

        return nil
    }

    private static func findXMPBlock(in data: Data) -> (Int, Int)? {
        guard let start = data.range(of: xmpStartTag)?.lowerBound else { return nil }
        guard let end = data[start...].range(of: xmpEndTag)?.upperBound else { return nil }
        let endOffset = data.distance(from: data.startIndex, to: end)
        let startOffset = data.distance(from: data.startIndex, to: start)
        return (startOffset, endOffset)
    }

    private static func findMotionPhotoItemLength(in data: Data) -> Int? {
        var searchStart = data.startIndex
        while searchStart < data.endIndex {
            guard let semanticRange = data[searchStart...].range(of: motionPhotoSemantic) else {
                return nil
            }
            let semanticIndex = semanticRange.lowerBound

            // Find enclosing XML tag
            let prefix = data[..<semanticIndex]
            guard let tagStart = prefix.lastIndex(of: 0x3C) else { // '<'
                searchStart = data.index(after: semanticIndex)
                continue
            }
            guard let tagEnd = data[semanticIndex...].firstIndex(of: 0x3E) else { // '>'
                searchStart = data.index(after: semanticIndex)
                continue
            }

            let tag = data[tagStart...tagEnd]
            if let length = findIntAttribute(in: Data(tag), prefix: lengthAttrPrefix), length > 0 {
                return length
            }

            searchStart = data.index(after: semanticIndex)
        }
        return nil
    }

    private static func findFirstIntAttribute(in data: Data, prefixes: [Data]) -> Int? {
        for prefix in prefixes {
            if let value = findIntAttribute(in: data, prefix: prefix), value > 0 {
                return value
            }
        }
        return nil
    }

    private static func findIntAttribute(in data: Data, prefix: Data) -> Int? {
        guard let prefixRange = data.range(of: prefix) else { return nil }
        var pos = prefixRange.upperBound

        var digitBytes = [UInt8]()
        while pos < data.endIndex {
            let byte = data[pos]
            if byte >= 0x30 && byte <= 0x39 {
                digitBytes.append(byte)
            } else {
                break
            }
            pos = data.index(after: pos)
        }

        guard !digitBytes.isEmpty,
              pos < data.endIndex,
              data[pos] == 0x22 else { return nil } // closing quote

        guard let str = String(data: Data(digitBytes), encoding: .ascii),
              let value = Int(str) else { return nil }
        return value
    }

    // MARK: - Strategy 2 & 3: Marker search

    private static func findMarkerCandidate(data: Data, magic: Data, seen: inout Set<Int>) -> Int? {
        guard data.count >= magic.count else { return nil }

        let searchStart: Int
        if data.count > markerTailSearchSize {
            searchStart = data.count - markerTailSearchSize
        } else {
            searchStart = 0
        }

        // Search tail region first, then head if needed
        let tailRegion = data.subdata(in: searchStart..<data.count)
        if let start = searchMarkerRegion(data: data, region: tailRegion, base: searchStart, magic: magic, seen: &seen) {
            return start
        }
        if searchStart == 0 { return nil }

        let headRegion = data.subdata(in: 0..<(searchStart + magic.count - 1))
        return searchMarkerRegion(data: data, region: headRegion, base: 0, magic: magic, seen: &seen)
    }

    private static func searchMarkerRegion(data: Data, region: Data, base: Int, magic: Data, seen: inout Set<Int>) -> Int? {
        var searchRegion = region
        while searchRegion.count >= magic.count {
            guard let markerRange = searchRegion.range(of: magic, options: .backwards) else { break }
            let markerIndex = markerRange.lowerBound
            let start = base + data.distance(from: searchRegion.startIndex, to: markerIndex) + magic.count

            if validateCandidate(data: data, start: start, seen: &seen) {
                return start
            }

            // Truncate search region before this marker
            searchRegion = searchRegion.subdata(in: searchRegion.startIndex..<markerIndex)
        }
        return nil
    }

    // MARK: - Validation

    private static func validateCandidate(data: Data, start: Int, seen: inout Set<Int>) -> Bool {
        guard start > 0, start < data.count else { return false }
        guard !seen.contains(start) else { return false }
        seen.insert(start)

        // If JPEG, verify EOI before candidate
        if data.prefix(jpegSOI.count) == jpegSOI {
            guard findJPEGEndBefore(data: data, limit: start) != nil else { return false }
        }

        // Verify MP4
        let payload = data.subdata(in: start..<data.count)
        return looksLikeMP4(data: payload)
    }

    private static func findJPEGEndBefore(data: Data, limit: Int) -> Int? {
        let effectiveLimit = min(limit, data.count)
        let searchStart: Int
        if effectiveLimit > jpegTailSearchSize {
            searchStart = effectiveLimit - jpegTailSearchSize
        } else {
            searchStart = 0
        }

        let region = data.subdata(in: searchStart..<effectiveLimit)
        if let eoiRange = region.range(of: jpegEOI, options: .backwards) {
            return searchStart + data.distance(from: region.startIndex, to: eoiRange.upperBound)
        }

        // Try full range if tail search failed
        if searchStart > 0 {
            let fullRegion = data.subdata(in: 0..<effectiveLimit)
            if let eoiRange = fullRegion.range(of: jpegEOI, options: .backwards) {
                return data.distance(from: data.startIndex, to: eoiRange.upperBound)
            }
        }

        return nil
    }

    // MARK: - MP4 detection

    private static func looksLikeMP4(data: Data) -> Bool {
        let maxBoxesToScan = 4
        let maxBytesToSniff = min(data.count, 4096)

        var offset = 0
        for _ in 0..<maxBoxesToScan {
            guard offset + 8 <= maxBytesToSniff else { return false }

            guard let (boxSize, headerSize, boxType) = readMP4BoxHeader(data: data, offset: offset) else {
                return false
            }

            guard boxSize >= headerSize, offset + boxSize <= data.count else { return false }

            if boxType == "ftyp" {
                return boxSize >= 16
            }

            guard allowedLeadingBoxTypes.contains(boxType),
                  offset + boxSize <= maxBytesToSniff else {
                return false
            }

            offset += boxSize
        }

        return false
    }

    private static func readMP4BoxHeader(data: Data, offset: Int) -> (boxSize: Int, headerSize: Int, boxType: String)? {
        guard offset + 8 <= data.count else { return nil }

        let boxTypeBytes = data.subdata(in: (offset + 4)..<(offset + 8))
        guard isASCIIBoxType(boxTypeBytes) else { return nil }
        let boxType = String(data: boxTypeBytes, encoding: .ascii)!

        guard let rawSize = data.uint32BE(at: offset) else { return nil }

        let boxSize: Int
        let headerSize: Int

        switch rawSize {
        case 0:
            return nil
        case 1:
            guard offset + 16 <= data.count, let largeSize = data.uint64BE(at: offset + 8) else { return nil }
            guard largeSize >= 16, largeSize <= data.count else { return nil }
            boxSize = Int(largeSize)
            headerSize = 16
        default:
            guard rawSize >= 8 else { return nil }
            boxSize = Int(rawSize)
            headerSize = 8
        }

        return (boxSize, headerSize, boxType)
    }

    private static func isASCIIBoxType(_ bytes: Data) -> Bool {
        for b in bytes {
            if (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39) || b == 0x20 {
                continue
            }
            return false
        }
        return true
    }

    // MARK: - EXIF

    private static func readEXIFDate(from url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String else {
            return nil
        }
        return dateFormatter.date(from: dateString)
    }

    // MARK: - Errors

    enum ExtractionError: LocalizedError {
        case noEmbeddedVideo

        var errorDescription: String? {
            switch self {
            case .noEmbeddedVideo: return "No embedded MP4 video found"
            }
        }
    }
}

// MARK: - Data extension helpers

extension Data {
    func uint32BE(at offset: Int) -> UInt32? {
        guard offset + 4 <= count else { return nil }
        var raw: UInt32 = 0
        withUnsafeBytes { buf in
            raw = UInt32(bigEndian: buf.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
        return raw
    }

    func uint64BE(at offset: Int) -> UInt64? {
        guard offset + 8 <= count else { return nil }
        var raw: UInt64 = 0
        withUnsafeBytes { buf in
            raw = UInt64(bigEndian: buf.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
        return raw
    }
}
