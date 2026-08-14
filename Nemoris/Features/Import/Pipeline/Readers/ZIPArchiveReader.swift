import Foundation
import Compression

// MARK: - Lecteur ZIP minimal, en LECTURE SEULE
//
// Moteur PUR (Foundation + Compression, tous deux sans état ni I/O implicite) —
// testable via `run_import_pipeline_tests.sh`.
//
// ─── Pourquoi écrire un lecteur ZIP plutôt qu'ajouter une dépendance ───────
//
// Un XLSX EST une archive ZIP contenant du XML. Ouvrir un classeur demande donc
// exactement deux choses : lister les entrées et décompresser celles qu'on veut.
// C'est ~200 lignes bien balisées par la spécification APPNOTE.
//
// Le projet a une doctrine explicite de réduction des dépendances ( a
// retiré 7 paquets SPM pour ~100 Mo d'embed). Ajouter ZIPFoundation pour lire
// deux fichiers XML par classeur irait contre cette ligne, et ferait entrer
// dans le binaire tout un moteur d'écriture, de chiffrement et de streaming
// dont on n'utiliserait rien.
//
// ⚠️ Périmètre volontairement étroit : lecture seule, méthodes STORE (0) et
// DEFLATE (8), pas de chiffrement, pas de ZIP64. Un classeur produit par Excel,
// Numbers, LibreOffice ou un export bancaire entre dans ce cadre. Le reste est
// refusé proprement, jamais deviné.

struct ZIPArchiveError: Error, Equatable {
    let reason: String
}

enum ZIPArchiveReader {

    /// Une entrée de l'archive, telle que décrite par le répertoire central.
    struct Entry: Equatable {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        /// Offset de l'en-tête LOCAL de l'entrée, depuis le début de l'archive.
        let localHeaderOffset: Int
    }

    // MARK: - Signatures (APPNOTE.TXT)

    private static let endOfCentralDirectory: UInt32 = 0x0605_4B50
    private static let centralFileHeader: UInt32     = 0x0201_4B50
    private static let localFileHeader: UInt32       = 0x0403_4B50

    // MARK: - Listing

    /// Liste les entrées via le RÉPERTOIRE CENTRAL, en fin d'archive.
    ///
    /// ⚠️ Pas en balayant les en-têtes locaux depuis le début : ceux-ci peuvent
    /// annoncer des tailles à zéro et renvoyer à un descripteur placé APRÈS les
    /// données (bit 3 des drapeaux), ce que font les outils qui écrivent en
    /// flux. Le répertoire central, lui, porte toujours les tailles réelles.
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

    /// Contenu décompressé d'une entrée.
    static func extract(_ entry: Entry, from data: Data) -> Result<Data, ZIPArchiveError> {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count,
              read32(data, header) == localFileHeader else {
            return .failure(ZIPArchiveError(reason: "en-tête local invalide pour \(entry.name)"))
        }
        // ⚠️ Les longueurs de nom et de champ « extra » de l'en-tête LOCAL
        // peuvent différer de celles du répertoire central (l'extra local porte
        // souvent des horodatages absents du central). Il faut donc lire
        // celles-ci, pas celles déjà connues, pour trouver le début des données.
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

    /// Contenu d'une entrée désignée par son nom.
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

    /// ⚠️ `COMPRESSION_ZLIB` d'Apple attend un flux DEFLATE **BRUT**, sans
    /// l'en-tête zlib de 2 octets ni le contrôle Adler-32 — c'est exactement ce
    /// que ZIP stocke. Le nom prête à confusion : passer un vrai flux zlib ici
    /// échoue.
    private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return Data() }
        // Une taille annoncée à zéro par un writer en flux ne doit pas produire
        // un tampon vide : on prend une marge raisonnable.
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
            // `written == capacity` : le tampon était peut-être trop juste, on
            // ne peut pas distinguer « pile poil » de « tronqué » — on retente
            // plus grand, et si la taille était connue on la croit.
            if written == capacity {
                if expectedSize > 0 && written == expectedSize { return output }
                capacity *= 4
                continue
            }
            return nil
        }
        return nil
    }

    // MARK: - Lecture d'entiers petit-boutistes

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

    /// Le répertoire central se trouve par sa signature, en remontant depuis la
    /// fin : sa position n'est pas fixe, un commentaire d'archive de longueur
    /// libre peut le suivre (limité à 64 Ko par le format, d'où la fenêtre).
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
