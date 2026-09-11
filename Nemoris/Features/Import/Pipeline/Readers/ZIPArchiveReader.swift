import Foundation
import Compression

// MARK: - Minimal, READ-ONLY ZIP reader
//
// PURE engine (Foundation + Compression, both stateless with no implicit I/O)
// — covered by `ImportPipelineTests`.
//
// ─── Why write a ZIP reader rather than add a dependency ──────────────────
//
// An XLSX IS a ZIP archive containing XML. Opening a workbook therefore takes
// exactly two things: listing the entries and decompressing the wanted ones.
// That's ~200 lines, well charted by the APPNOTE specification.
//
// The project keeps its dependencies to a minimum. Adding ZIPFoundation to
// read two XML files per workbook would go against that, and would bring
// into the binary a whole writing, encryption and streaming engine of which
// nothing would be used.
//
// Deliberately narrow scope: read-only, STORE (0) and DEFLATE (8) methods, no
// encryption, no ZIP64. A workbook produced by Excel, Numbers, LibreOffice or
// a bank export fits within it. Anything else is rejected cleanly, never
// guessed.

struct ZIPArchiveError: Error, Equatable {
    let reason: String
}

enum ZIPArchiveReader {

    /// An archive entry, as described by the central directory.
    struct Entry: Equatable {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        /// Offset of the entry's LOCAL header, from the start of the archive.
        let localHeaderOffset: Int
    }

    // MARK: - Signatures (APPNOTE.TXT)

    private static let endOfCentralDirectory: UInt32 = 0x0605_4B50
    private static let centralFileHeader: UInt32     = 0x0201_4B50
    private static let localFileHeader: UInt32       = 0x0403_4B50

    // MARK: - Listing

    /// Lists the entries through the CENTRAL DIRECTORY, at the end of the archive.
    ///
    /// Not by scanning the local headers from the start: they can announce zero
    /// sizes and point to a descriptor placed AFTER the data (flag bit 3), which
    /// streaming writers do. The central directory always carries the real sizes.
    static func entries(in data: Data) -> Result<[Entry], ZIPArchiveError> {
        guard let eocd = locateEndOfCentralDirectory(data) else {
            return .failure(ZIPArchiveError(reason: "archive illisible (fin de répertoire introuvable)"))
        }
        let count = Int(read16(data, eocd + 10))
        var offset = Int(read32(data, eocd + 16))
        guard offset > 0, offset < data.count else {
            return .failure(ZIPArchiveError(reason: "répertoire central hors limites"))
        }

        var result: [Entry] = []
        result.reserveCapacity(count)

        for _ in 0..<count {
            guard offset + 46 <= data.count,
                  read32(data, offset) == centralFileHeader else { break }

            let method   = read16(data, offset + 10)
            let compSize = Int(read32(data, offset + 20))
            let fullSize = Int(read32(data, offset + 24))
            let nameLen  = Int(read16(data, offset + 28))
            let extraLen = Int(read16(data, offset + 30))
            let commLen  = Int(read16(data, offset + 32))
            let localAt  = Int(read32(data, offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLen <= data.count else { break }
            let name = String(decoding: data[nameStart..<(nameStart + nameLen)], as: UTF8.self)

            result.append(Entry(name: name,
                                compressionMethod: method,
                                compressedSize: compSize,
                                uncompressedSize: fullSize,
                                localHeaderOffset: localAt))

            offset = nameStart + nameLen + extraLen + commLen
        }

        guard !result.isEmpty else {
            return .failure(ZIPArchiveError(reason: "archive vide"))
        }
        return .success(result)
    }

    // MARK: - Extraction

    /// Decompressed content of an entry.
    static func extract(_ entry: Entry, from data: Data) -> Result<Data, ZIPArchiveError> {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count,
              read32(data, header) == localFileHeader else {
            return .failure(ZIPArchiveError(reason: "en-tête local invalide pour \(entry.name)"))
        }
        // The name and "extra" field lengths of the LOCAL header can differ from
        // those of the central directory (the local extra often carries timestamps
        // absent from the central one). These must be read to find where the data
        // starts, not the already-known ones.
        let nameLen  = Int(read16(data, header + 26))
        let extraLen = Int(read16(data, header + 28))
        let start = header + 30 + nameLen + extraLen
        let end = start + entry.compressedSize
        guard start <= data.count, end <= data.count else {
            return .failure(ZIPArchiveError(reason: "données tronquées pour \(entry.name)"))
        }
        let payload = data.subdata(in: start..<end)

        switch entry.compressionMethod {
        case 0:
            return .success(payload)                    // STORE
        case 8:
            guard let inflated = inflate(payload, expectedSize: entry.uncompressedSize) else {
                return .failure(ZIPArchiveError(reason: "décompression échouée pour \(entry.name)"))
            }
            return .success(inflated)                   // DEFLATE
        default:
            return .failure(ZIPArchiveError(
                reason: "méthode de compression non gérée (\(entry.compressionMethod))"))
        }
    }

    /// Content of an entry designated by its name.
    static func extract(named name: String, from data: Data) -> Result<Data, ZIPArchiveError> {
        switch entries(in: data) {
        case .failure(let error): return .failure(error)
        case .success(let list):
            guard let entry = list.first(where: { $0.name == name }) else {
                return .failure(ZIPArchiveError(reason: "entrée « \(name) » absente de l'archive"))
            }
            return extract(entry, from: data)
        }
    }

    // MARK: - DEFLATE

    /// Apple's `COMPRESSION_ZLIB` expects a **RAW** DEFLATE stream, without the
    /// 2-byte zlib header or the Adler-32 check — exactly what ZIP stores. The
    /// name is misleading: passing a real zlib stream here fails.
    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return Data() }
        // A size announced as zero by a streaming writer must not produce an empty
        // buffer: a reasonable margin is taken.
        var capacity = expectedSize > 0 ? expectedSize : max(data.count * 8, 64 * 1024)

        for _ in 0..<4 {
            var output = Data(count: capacity)
            let written: Int = output.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source -> Int in
                    guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                          let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(dst, capacity,
                                                     src, data.count,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 && written < capacity {
                return output.prefix(written)
            }
            // `written == capacity`: the buffer may have been too tight, and "exact fit"
            // can't be told from "truncated" — retry larger, and trust the size when it
            // was known.
            if written == capacity {
                if expectedSize > 0 && written == expectedSize { return output }
                capacity *= 4
                continue
            }
            return nil
        }
        return nil
    }

    // MARK: - Reading little-endian integers

    private static func read16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    /// The central directory is found by its signature, searching back from the
    /// end: its position isn't fixed, since a free-length archive comment may
    /// follow it (capped at 64 KB by the format, hence the window).
    private static func locateEndOfCentralDirectory(_ data: Data) -> Int? {
        let minimumSize = 22
        guard data.count >= minimumSize else { return nil }
        let window = min(data.count, minimumSize + 0xFFFF)
        let lowest = data.count - window
        var offset = data.count - minimumSize
        while offset >= lowest {
            if read32(data, offset) == endOfCentralDirectory { return offset }
            offset -= 1
        }
        return nil
    }
}
