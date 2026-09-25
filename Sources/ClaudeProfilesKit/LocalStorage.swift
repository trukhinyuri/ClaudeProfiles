import Darwin
import Foundation

/// Reads and writes Chromium's Local Storage (LevelDB) of one Electron data directory.
///
/// Understands enough of the on-disk LevelDB format — CURRENT, the manifest's VersionEdit log, table
/// (`.ldb`/`.sst`) files and write-ahead `.log` files — to read every live key for an origin and append a
/// durable update as a brand new log file, all without linking LevelDB itself. Existing files are never
/// modified; an update is a new numbered `.log` file that LevelDB replays the next time it opens the
/// database. Use only while no process has the database open — check `isInUse` first, or let `update`
/// throw.
public struct LocalStorage: Sendable {
    public let dataDir: URL

    public init(dataDir: URL) { self.dataDir = dataDir }

    /// `<dataDir>/Local Storage/leveldb`
    public var dbDir: URL { dataDir.appending(path: "Local Storage/leveldb", directoryHint: .isDirectory) }

    var store: LevelDBStore { LevelDBStore(dir: dbDir) }

    public var exists: Bool { store.exists }

    /// Whether another process holds the database's LevelDB `LOCK`.
    public var isInUse: Bool { store.isInUse }

    /// Every live key/value pair stored under `origin`, decoded to strings.
    public func items(origin: String) throws -> [String: String] {
        let live = try store.liveEntries()
        let prefix = ChromiumKey.originPrefix(origin)
        var result: [String: String] = [:]
        for (key, value) in live where key.starts(with: prefix) {
            let encodedKey = Array(key.dropFirst(prefix.count))
            guard let decodedKey = ChromiumKey.decodeString(encodedKey),
                  let decodedValue = ChromiumKey.decodeString(value) else { continue }
            result[decodedKey] = decodedValue
        }
        return result
    }

    /// Appends one atomic batch of sets and removals for `origin`'s keys as a new log file. Never touches
    /// an existing file. Throws if the database is missing or another process has it open.
    public func update(origin: String, set: [String: String], remove: Set<String>) throws {
        let prefix = ChromiumKey.originPrefix(origin)
        try store.append(put: set.map { (prefix + ChromiumKey.encodeString($0.key), ChromiumKey.encodeString($0.value)) },
                         delete: remove.map { prefix + ChromiumKey.encodeString($0) })
    }
}

/// A LevelDB database directory, read and appended to without opening it the way LevelDB does.
struct LevelDBStore: Sendable {
    let dir: URL
    private var fm: FileManager { .default }

    var exists: Bool { fm.fileExists(atPath: dir.appending(path: "CURRENT").path) }

    /// Whether another process holds the database's `LOCK`, tested the way LevelDB itself locks it:
    /// an `fcntl` `F_SETLK` write lock and a `flock(LOCK_EX | LOCK_NB)`, both released right after the check.
    var isInUse: Bool {
        let path = dir.appending(path: "LOCK").path
        let fd = open(path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var fl = flock_t()
        fl.l_start = 0
        fl.l_len = 0
        fl.l_pid = 0
        fl.l_whence = Int16(SEEK_SET)

        fl.l_type = Int16(F_WRLCK)
        if fcntl(fd, F_SETLK, &fl) == -1 { return true }
        fl.l_type = Int16(F_UNLCK)
        _ = fcntl(fd, F_SETLK, &fl)

        if flock(fd, LOCK_EX | LOCK_NB) == -1 { return true }
        flock(fd, LOCK_UN)
        return false
    }

    /// Every live key and its value.
    func liveEntries() throws -> [[UInt8]: [UInt8]] {
        try LevelDBDatabase(dir: dir).liveEntries().values
    }

    /// Appends one atomic batch of puts and deletions as a new log file. Never touches an existing file.
    /// Throws if the database is missing or another process has it open.
    ///
    /// The lock is checked once, not held: holding it would make a Claude window starting at that moment
    /// fail to open its database. A window that opens it during the update simply doesn't see the new
    /// file until its next start; nothing that was already there is affected.
    func append(put: [([UInt8], [UInt8])], delete: [[UInt8]]) throws {
        guard exists else { throw LocalStorageError.notFound }
        guard !isInUse else { throw LocalStorageError.databaseInUse }
        guard !put.isEmpty || !delete.isEmpty else { return }

        let db = try LevelDBDatabase(dir: dir)
        let live = try db.liveEntries()
        // Opening the database, LevelDB writes each older log it replays to a table numbered from the manifest's
        // next file number; the gap keeps those numbers apart from this log's.
        let newFileNumber = max(db.state.nextFileNumber, db.highestFileNumberOnDisk) + Self.fileNumberGap
        let newSequence = max(db.state.lastSequence, live.highestSequence) + 1

        var payload = ByteWriter()
        payload.appendFixed64(newSequence)
        payload.appendFixed32(UInt32(put.count + delete.count))
        for (key, value) in put {
            payload.appendByte(LevelDBValueType.value)
            payload.appendLengthPrefixed(key)
            payload.appendLengthPrefixed(value)
        }
        for key in delete {
            payload.appendByte(LevelDBValueType.deletion)
            payload.appendLengthPrefixed(key)
        }

        let fileName = LevelDBDatabase.fileName(number: newFileNumber, suffix: "log")
        let finalURL = dir.appending(path: fileName)
        let tmpURL = dir.appending(path: ".\(fileName).tmp-\(UUID().uuidString.prefix(8))")
        try writeAtomically(LogFormat.writeRecords(payload: payload.bytes), tmpURL: tmpURL, finalURL: finalURL)
    }

    static let fileNumberGap: UInt64 = 100

    private func writeAtomically(_ bytes: [UInt8], tmpURL: URL, finalURL: URL) throws {
        // Private to the user, like the files Chromium writes.
        fm.createFile(atPath: tmpURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: tmpURL)
        try handle.write(contentsOf: Data(bytes))
        try handle.synchronize()
        try handle.close()
        try fm.moveItem(at: tmpURL, to: finalURL)
        let dirFD = open(dir.path, O_RDONLY)
        if dirFD >= 0 { fsync(dirFD); close(dirFD) }
    }
}

public enum LocalStorageError: Error, Sendable, Equatable {
    case notFound
    case databaseInUse
    case corrupt(String)
}

// MARK: - Chromium's DOM Storage key/value encoding

/// Encodes and decodes the string form Chromium's Local Storage stores keys and values in: a one-byte tag
/// (`0x01` Latin-1, `0x00` UTF-16LE) followed by the encoded characters. The tag is `0x01` whenever every
/// UTF-16 code unit fits in a byte, `0x00` otherwise.
enum ChromiumKey {
    /// `"_" + origin + "\0"`, the byte prefix every one of that origin's entries starts with.
    static func originPrefix(_ origin: String) -> [UInt8] { [0x5F] + Array(origin.utf8) + [0x00] }

    static func encodeString(_ string: String) -> [UInt8] {
        let units = Array(string.utf16)
        if units.allSatisfy({ $0 <= 0xFF }) {
            return [0x01] + units.map { UInt8($0) }
        }
        var bytes: [UInt8] = [0x00]
        bytes.reserveCapacity(1 + units.count * 2)
        for unit in units {
            bytes.append(UInt8(unit & 0xFF))
            bytes.append(UInt8(unit >> 8))
        }
        return bytes
    }

    static func decodeString(_ bytes: [UInt8]) -> String? {
        guard let tag = bytes.first else { return "" }
        let payload = bytes.dropFirst()
        switch tag {
        case 0x01:
            let units = payload.map { UInt16($0) }
            return String(utf16CodeUnits: units, count: units.count)
        case 0x00:
            guard payload.count % 2 == 0 else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(payload.count / 2)
            var iterator = payload.makeIterator()
            while let low = iterator.next(), let high = iterator.next() {
                units.append(UInt16(low) | (UInt16(high) << 8))
            }
            return String(utf16CodeUnits: units, count: units.count)
        default:
            return nil
        }
    }
}

// MARK: - Byte reading and writing

/// A cursor over a byte buffer with the primitives LevelDB's on-disk formats are built from.
struct ByteReader {
    let data: [UInt8]
    var pos: Int

    init(_ data: [UInt8], at pos: Int = 0) {
        self.data = data
        self.pos = pos
    }

    var isAtEnd: Bool { pos >= data.count }

    mutating func byte() throws -> UInt8 {
        guard pos < data.count else { throw LocalStorageError.corrupt("unexpected end of data") }
        defer { pos += 1 }
        return data[pos]
    }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, pos + count <= data.count else { throw LocalStorageError.corrupt("unexpected end of data") }
        defer { pos += count }
        return Array(data[pos..<pos + count])
    }

    mutating func varint32() throws -> UInt32 { UInt32(truncatingIfNeeded: try varint64()) }

    mutating func varint64() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let b = try byte()
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
            guard shift < 64 else { throw LocalStorageError.corrupt("varint too long") }
        }
        return result
    }

    mutating func fixed32() throws -> UInt32 {
        let b = try bytes(4)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    mutating func fixed64() throws -> UInt64 {
        let b = try bytes(8)
        var value: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) { value = (value << 8) | UInt64(b[i]) }
        return value
    }

    mutating func lengthPrefixed() throws -> [UInt8] {
        let length = try varint32()
        return try bytes(Int(length))
    }

    /// A LevelDB `BlockHandle`: an offset and a size, each a varint64.
    mutating func blockHandle() throws -> (offset: UInt64, size: UInt64) {
        (try varint64(), try varint64())
    }
}

/// Builds the byte form of a `WriteBatch`.
struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func appendByte(_ b: UInt8) { bytes.append(b) }

    mutating func appendFixed32(_ v: UInt32) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF))
        bytes.append(UInt8((v >> 24) & 0xFF))
    }

    mutating func appendFixed64(_ v: UInt64) {
        var value = v
        for _ in 0..<8 {
            bytes.append(UInt8(value & 0xFF))
            value >>= 8
        }
    }

    mutating func appendVarint32(_ v: UInt32) { appendVarint64(UInt64(v)) }

    mutating func appendVarint64(_ v: UInt64) {
        var value = v
        while value >= 0x80 {
            bytes.append(UInt8((value & 0x7F) | 0x80))
            value >>= 7
        }
        bytes.append(UInt8(value))
    }

    mutating func appendLengthPrefixed(_ data: [UInt8]) {
        appendVarint32(UInt32(data.count))
        bytes.append(contentsOf: data)
    }
}

/// LevelDB's `ValueType` tag, stored in a `WriteBatch` entry and in an internal key's trailer.
enum LevelDBValueType {
    static let deletion: UInt8 = 0
    static let value: UInt8 = 1
}

// MARK: - CRC-32C (Castagnoli), as LevelDB's log format uses it

enum CRC32C {
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0x82F6_3B78 ^ (c >> 1)) : (c >> 1)
            }
            table[i] = c
        }
        return table
    }()

    /// The raw (unmasked) CRC-32C, continued from a previous call's result.
    static func extend(_ crc: UInt32, _ bytes: [UInt8]) -> UInt32 {
        var c = crc ^ 0xFFFF_FFFF
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    static func value(_ bytes: [UInt8]) -> UInt32 { extend(0, bytes) }

    /// LevelDB stores a "masked" CRC so that data that happens to contain CRCs of its own doesn't confuse
    /// stream detection.
    static func mask(_ crc: UInt32) -> UInt32 {
        ((crc >> 15) | (crc << 17)) &+ 0xA282_EAD8
    }
}

// MARK: - Snappy decompression

enum Snappy {
    static func decompress(_ input: [UInt8]) throws -> [UInt8] {
        var reader = ByteReader(input)
        let expectedLength = Int(try reader.varint32())
        var out = [UInt8]()
        out.reserveCapacity(expectedLength)

        while reader.pos < input.count {
            let tag = try reader.byte()
            let elementType = tag & 0x3
            if elementType == 0 {
                var length = Int(tag >> 2)
                if length < 60 {
                    length += 1
                } else {
                    let extraBytes = length - 59
                    var value = 0
                    for i in 0..<extraBytes { value |= Int(try reader.byte()) << (8 * i) }
                    length = value + 1
                }
                out.append(contentsOf: try reader.bytes(length))
            } else {
                let length: Int
                let offset: Int
                switch elementType {
                case 1:
                    length = Int((tag >> 2) & 0x7) + 4
                    let low = try reader.byte()
                    offset = (Int(tag >> 5) << 8) | Int(low)
                case 2:
                    length = Int(tag >> 2) + 1
                    let b = try reader.bytes(2)
                    offset = Int(b[0]) | (Int(b[1]) << 8)
                default:
                    length = Int(tag >> 2) + 1
                    let b = try reader.bytes(4)
                    offset = Int(b[0]) | (Int(b[1]) << 8) | (Int(b[2]) << 16) | (Int(b[3]) << 24)
                }
                guard offset > 0, offset <= out.count else { throw LocalStorageError.corrupt("snappy: bad copy offset") }
                var src = out.count - offset
                for _ in 0..<length {
                    out.append(out[src])
                    src += 1
                }
            }
        }
        guard out.count == expectedLength else { throw LocalStorageError.corrupt("snappy: length mismatch") }
        return out
    }
}

// MARK: - LevelDB log format (write-ahead `.log` files and the MANIFEST)

/// The 32 KiB-block, 7-byte-header record framing shared by write-ahead log files and the manifest.
enum LogFormat {
    static let blockSize = 32768
    static let headerSize = 7

    private enum RecordType {
        static let full: UInt8 = 1
        static let first: UInt8 = 2
        static let middle: UInt8 = 3
        static let last: UInt8 = 4
    }

    /// Reassembles every complete record. A record split across a truncated tail is dropped, not thrown.
    static func readRecords(_ data: [UInt8]) -> [[UInt8]] {
        var records: [[UInt8]] = []
        var pending: [UInt8]?
        var offset = 0
        while offset < data.count {
            let blockEnd = min(offset + blockSize, data.count)
            var pos = offset
            while pos + headerSize <= blockEnd {
                let length = Int(data[pos + 4]) | (Int(data[pos + 5]) << 8)
                let type = data[pos + 6]
                if type == 0 && length == 0 { break }   // zero padding at the tail of a block
                guard pos + headerSize + length <= blockEnd else { return records }   // truncated: stop here
                let payload = Array(data[(pos + headerSize)..<(pos + headerSize + length)])
                switch type {
                case RecordType.full:
                    records.append(payload)
                    pending = nil
                case RecordType.first:
                    pending = payload
                case RecordType.middle:
                    pending?.append(contentsOf: payload)
                case RecordType.last:
                    pending?.append(contentsOf: payload)
                    if let whole = pending { records.append(whole) }
                    pending = nil
                default:
                    break   // unknown record type: ignore, matches LevelDB's own reader
                }
                pos += headerSize + length
            }
            offset += blockSize
        }
        return records
    }

    /// Frames one record payload as physical log bytes, fragmenting across 32 KiB blocks and zero-padding a
    /// block tail too short to hold a header.
    static func writeRecords(payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var blockOffset = 0
        var pos = 0
        var left = payload.count
        var begin = true
        repeat {
            let leftover = blockSize - blockOffset
            if leftover < headerSize {
                if leftover > 0 { out.append(contentsOf: repeatElement(0, count: leftover)) }
                blockOffset = 0
            }
            let available = blockSize - blockOffset - headerSize
            let fragmentLength = min(left, available)
            let end = fragmentLength == left
            let type: UInt8 = begin && end ? RecordType.full : begin ? RecordType.first : end ? RecordType.last : RecordType.middle
            let fragment = Array(payload[pos..<pos + fragmentLength])
            appendRecord(&out, type: type, data: fragment)
            blockOffset += headerSize + fragmentLength
            pos += fragmentLength
            left -= fragmentLength
            begin = false
        } while left > 0
        return out
    }

    private static func appendRecord(_ out: inout [UInt8], type: UInt8, data: [UInt8]) {
        let crc = CRC32C.mask(CRC32C.extend(CRC32C.value([type]), data))
        out.append(UInt8(crc & 0xFF))
        out.append(UInt8((crc >> 8) & 0xFF))
        out.append(UInt8((crc >> 16) & 0xFF))
        out.append(UInt8((crc >> 24) & 0xFF))
        out.append(UInt8(data.count & 0xFF))
        out.append(UInt8((data.count >> 8) & 0xFF))
        out.append(type)
        out.append(contentsOf: data)
    }
}

// MARK: - WriteBatch decoding

enum WriteBatchCodec {
    struct Entry { let sequence: UInt64; let type: UInt8; let key: [UInt8]; let value: [UInt8] }

    /// Decodes one `WriteBatch` payload: `fixed64` sequence, `fixed32` count, then that many put/delete
    /// records. Tolerates a batch truncated after its header (a corrupt or partially-written tail record).
    static func decode(_ payload: [UInt8]) throws -> [Entry] {
        var reader = ByteReader(payload)
        let sequence = try reader.fixed64()
        let count = try reader.fixed32()
        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        var index: UInt64 = 0
        while index < UInt64(count), !reader.isAtEnd {
            let tag = try reader.byte()
            switch tag {
            case LevelDBValueType.value:
                let key = try reader.lengthPrefixed()
                let value = try reader.lengthPrefixed()
                entries.append(Entry(sequence: sequence + index, type: tag, key: key, value: value))
            case LevelDBValueType.deletion:
                let key = try reader.lengthPrefixed()
                entries.append(Entry(sequence: sequence + index, type: tag, key: key, value: []))
            default:
                throw LocalStorageError.corrupt("unknown WriteBatch tag \(tag)")
            }
            index += 1
        }
        return entries
    }
}

// MARK: - MANIFEST (VersionEdit) decoding

/// The parts of a `Version`'s state that reading and appending to the database need.
struct ManifestState {
    var logNumber: UInt64 = 0
    var prevLogNumber: UInt64 = 0
    var nextFileNumber: UInt64 = 0
    var lastSequence: UInt64 = 0
    var liveFileNumbers: Set<UInt64> = []
}

enum VersionEditCodec {
    private enum Tag {
        static let comparator: UInt32 = 1
        static let logNumber: UInt32 = 2
        static let nextFileNumber: UInt32 = 3
        static let lastSequence: UInt32 = 4
        static let compactPointer: UInt32 = 5
        static let deletedFile: UInt32 = 6
        static let newFile: UInt32 = 7
        static let prevLogNumber: UInt32 = 9
    }

    /// Applies one VersionEdit record on top of the running state, in the order the manifest wrote them.
    static func apply(_ payload: [UInt8], to state: inout ManifestState) throws {
        var reader = ByteReader(payload)
        while !reader.isAtEnd {
            let tag = try reader.varint32()
            switch tag {
            case Tag.comparator:
                _ = try reader.lengthPrefixed()
            case Tag.logNumber:
                state.logNumber = try reader.varint64()
            case Tag.nextFileNumber:
                state.nextFileNumber = try reader.varint64()
            case Tag.lastSequence:
                state.lastSequence = try reader.varint64()
            case Tag.compactPointer:
                _ = try reader.varint32()   // level
                _ = try reader.lengthPrefixed()   // key
            case Tag.deletedFile:
                _ = try reader.varint32()   // level
                let number = try reader.varint64()
                state.liveFileNumbers.remove(number)
            case Tag.newFile:
                _ = try reader.varint32()   // level
                let number = try reader.varint64()
                _ = try reader.varint64()   // file size
                _ = try reader.lengthPrefixed()   // smallest key
                _ = try reader.lengthPrefixed()   // largest key
                state.liveFileNumbers.insert(number)
            case Tag.prevLogNumber:
                state.prevLogNumber = try reader.varint64()
            default:
                throw LocalStorageError.corrupt("unknown VersionEdit tag \(tag)")
            }
        }
    }
}

// MARK: - Table (.ldb / legacy .sst) reading

/// One decoded entry from a table file: its internal key (user key + 8-byte sequence/type trailer) and
/// value.
struct SSTableEntry { let internalKey: [UInt8]; let value: [UInt8] }

enum SSTableReader {
    private static let magic: UInt64 = 0xdb47_7524_8b80_fb57
    private static let footerLength = 48

    static func readAll(_ fileURL: URL) throws -> [SSTableEntry] {
        let data = try readFileBytes(fileURL)
        guard data.count >= footerLength else { throw LocalStorageError.corrupt("table too small: \(fileURL.lastPathComponent)") }
        let footer = Array(data.suffix(footerLength))

        var footerReader = ByteReader(footer)
        _ = try footerReader.blockHandle()   // metaindex handle: unused, we don't read filters
        let indexHandle = try footerReader.blockHandle()

        let magicBytes = Array(footer.suffix(8))
        var magicValue: UInt64 = 0
        for i in stride(from: 7, through: 0, by: -1) { magicValue = (magicValue << 8) | UInt64(magicBytes[i]) }
        guard magicValue == magic else { throw LocalStorageError.corrupt("bad table magic: \(fileURL.lastPathComponent)") }

        let indexBlock = try readBlock(data: data, handle: indexHandle)
        let indexEntries = try decodeBlockEntries(indexBlock)

        var entries: [SSTableEntry] = []
        for (_, handleBytes) in indexEntries {
            var handleReader = ByteReader(handleBytes)
            let handle = try handleReader.blockHandle()
            let dataBlock = try readBlock(data: data, handle: handle)
            for (key, value) in try decodeBlockEntries(dataBlock) {
                entries.append(SSTableEntry(internalKey: key, value: value))
            }
        }
        return entries
    }

    /// Reads a block's (possibly Snappy-compressed) bytes and returns them decompressed. The trailing CRC
    /// is not verified.
    private static func readBlock(data: [UInt8], handle: (offset: UInt64, size: UInt64)) throws -> [UInt8] {
        let offset = Int(handle.offset), size = Int(handle.size)
        guard offset >= 0, size >= 0, offset + size + 5 <= data.count else {
            throw LocalStorageError.corrupt("block handle out of range")
        }
        let raw = Array(data[offset..<offset + size])
        let compressionType = data[offset + size]
        switch compressionType {
        case 0: return raw
        case 1: return try Snappy.decompress(raw)
        default: throw LocalStorageError.corrupt("unknown block compression type \(compressionType)")
        }
    }

    /// Decodes every prefix-compressed entry in a block, in order. Restart points only matter for binary
    /// search; a full linear scan doesn't need them beyond finding where entry data ends.
    private static func decodeBlockEntries(_ block: [UInt8]) throws -> [(key: [UInt8], value: [UInt8])] {
        guard block.count >= 4 else { return [] }
        let numRestarts = Int(UInt32(block[block.count - 4]) | (UInt32(block[block.count - 3]) << 8)
            | (UInt32(block[block.count - 2]) << 16) | (UInt32(block[block.count - 1]) << 24))
        let restartsStart = block.count - 4 - numRestarts * 4
        guard restartsStart >= 0 else { throw LocalStorageError.corrupt("bad restart count") }

        var reader = ByteReader(block)
        var lastKey: [UInt8] = []
        var result: [(key: [UInt8], value: [UInt8])] = []
        while reader.pos < restartsStart {
            let shared = Int(try reader.varint32())
            let nonShared = Int(try reader.varint32())
            let valueLength = Int(try reader.varint32())
            let delta = try reader.bytes(nonShared)
            guard shared <= lastKey.count else { throw LocalStorageError.corrupt("bad shared-key prefix length") }
            var key = Array(lastKey.prefix(shared))
            key.append(contentsOf: delta)
            let value = try reader.bytes(valueLength)
            result.append((key, value))
            lastKey = key
        }
        return result
    }
}

private func readFileBytes(_ url: URL) throws -> [UInt8] {
    Array(try Data(contentsOf: url))
}

// MARK: - The database as a whole: CURRENT, the manifest, and every live file on disk

/// One opened-for-reading view of a LevelDB database directory: the manifest state plus every file that is
/// actually present on disk.
struct LevelDBDatabase {
    let dir: URL
    let state: ManifestState
    private let logFiles: [UInt64: URL]
    private let tableFiles: [UInt64: URL]
    let highestFileNumberOnDisk: UInt64

    struct LiveEntries { let values: [[UInt8]: [UInt8]]; let highestSequence: UInt64 }

    init(dir: URL) throws {
        self.dir = dir
        guard let currentText = try? String(contentsOf: dir.appending(path: "CURRENT"), encoding: .utf8) else {
            throw LocalStorageError.corrupt("missing CURRENT")
        }
        let manifestName = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !manifestName.isEmpty else { throw LocalStorageError.corrupt("empty CURRENT") }

        let manifestData = try readFileBytes(dir.appending(path: manifestName))
        var state = ManifestState()
        for record in LogFormat.readRecords(manifestData) {
            try VersionEditCodec.apply(record, to: &state)
        }
        self.state = state

        var logFiles: [UInt64: URL] = [:]
        var tableFiles: [UInt64: URL] = [:]
        var highest: UInt64 = 0
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for url in entries {
            let name = url.lastPathComponent
            if let number = Self.fileNumber(name, suffix: "log") {
                logFiles[number] = url
                highest = max(highest, number)
            } else if let number = Self.fileNumber(name, suffix: "ldb") {
                tableFiles[number] = url
                highest = max(highest, number)
            } else if let number = Self.fileNumber(name, suffix: "sst") {
                if tableFiles[number] == nil { tableFiles[number] = url }
                highest = max(highest, number)
            } else if name.hasPrefix("MANIFEST-"), let number = UInt64(name.dropFirst("MANIFEST-".count)) {
                highest = max(highest, number)
            }
        }
        self.logFiles = logFiles
        self.tableFiles = tableFiles
        self.highestFileNumberOnDisk = highest
    }

    static func fileNumber(_ name: String, suffix: String) -> UInt64? {
        guard name.hasSuffix(".\(suffix)") else { return nil }
        return UInt64(name.dropLast(suffix.count + 1))
    }

    /// Zero-padded to six digits like LevelDB's own names; built by hand because `%d` would cut a 64-bit number.
    static func fileName(number: UInt64, suffix: String) -> String {
        let digits = String(number)
        return String(repeating: "0", count: max(0, 6 - digits.count)) + digits + "." + suffix
    }

    /// Every currently-live user key and its value: every live table plus every log file numbered at or
    /// after the manifest's log number (and `prevLogNumber`, if set), reduced by keeping each key's highest
    /// sequence and dropping deletions.
    func liveEntries() throws -> LiveEntries {
        var best: [[UInt8]: (sequence: UInt64, type: UInt8, value: [UInt8])] = [:]
        var highestSequence: UInt64 = 0

        func consider(userKey: [UInt8], sequence: UInt64, type: UInt8, value: [UInt8]) {
            highestSequence = max(highestSequence, sequence)
            if let existing = best[userKey], existing.sequence >= sequence { return }
            best[userKey] = (sequence, type, value)
        }

        for number in state.liveFileNumbers {
            guard let url = tableFiles[number] else {
                throw LocalStorageError.corrupt("live table \(number) is missing from disk")
            }
            for entry in try SSTableReader.readAll(url) {
                guard entry.internalKey.count >= 8 else { continue }
                let trailerStart = entry.internalKey.count - 8
                var trailer: UInt64 = 0
                for i in stride(from: 7, through: 0, by: -1) {
                    trailer = (trailer << 8) | UInt64(entry.internalKey[trailerStart + i])
                }
                let type = UInt8(trailer & 0xFF)
                let sequence = trailer >> 8
                let userKey = Array(entry.internalKey[0..<trailerStart])
                consider(userKey: userKey, sequence: sequence, type: type, value: entry.value)
            }
        }

        let threshold = state.prevLogNumber > 0 ? min(state.logNumber, state.prevLogNumber) : state.logNumber
        for number in logFiles.keys.sorted() where number >= threshold {
            let data = try readFileBytes(logFiles[number]!)
            for record in LogFormat.readRecords(data) {
                for entry in try WriteBatchCodec.decode(record) {
                    consider(userKey: entry.key, sequence: entry.sequence, type: entry.type, value: entry.value)
                }
            }
        }

        var values: [[UInt8]: [UInt8]] = [:]
        for (key, entry) in best where entry.type == LevelDBValueType.value {
            values[key] = entry.value
        }
        return LiveEntries(values: values, highestSequence: highestSequence)
    }
}

/// `flock` the struct (from `<fcntl.h>`), distinguished by name from the `flock()` function it's used with.
private typealias flock_t = flock
