import Foundation

/// Reads and writes string records of one object store in Chromium's IndexedDB, which keeps an origin's
/// databases in a LevelDB database of its own. Covers what Claude's small key-value stores (idb-keyval) use:
/// string keys, values that are one string, no indexes and no key generator. A store that has either is not read,
/// and a record stored with blobs is reported and never written.
///
/// Like `LocalStorage`, a write is one new `.log` file; existing files are never changed.
struct IndexedDBStore: Sendable {
    let dataDir: URL
    let database: String
    let objectStore: String
    /// Chromium's directory name for the origin.
    var origin = "https_claude.ai_0"

    var dbDir: URL { dataDir.appending(path: "IndexedDB/\(origin).indexeddb.leveldb", directoryHint: .isDirectory) }
    var store: LevelDBStore { LevelDBStore(dir: dbDir) }
    var exists: Bool { store.exists }
    var isInUse: Bool { store.isInUse }

    struct Record: Equatable, Sendable {
        let version: UInt64
        /// The value as Chromium serialized it, without the version in front.
        let value: [UInt8]
        /// The string the value holds, if it is one string.
        var string: String? { IDBValue.string(in: value) }
    }

    struct Snapshot: Sendable {
        /// The serialization format of the whole backing store; values are comparable only when it matches.
        let dataVersion: UInt64?
        let databaseID: UInt64
        let objectStoreID: UInt64
        let lastVersion: UInt64
        let records: [String: Record]
        /// Keys whose record has blobs.
        let blobKeys: Set<String>
    }

    /// The object store and its string-keyed records, or `nil` if the database or the store doesn't exist or
    /// has an index or a key generator, which a write here would not update.
    func read() throws -> Snapshot? {
        let live = try store.liveEntries()

        // DatabaseNameKey: global prefix, type 201, origin, name → database ID.
        let names = IDBKey.prefix(0, 0, 0) + [201]
        var databaseIDs: [UInt64] = []
        for (key, value) in live where key.starts(with: names) {
            var reader = ByteReader(key, at: names.count)
            guard (try? IDBKey.readString(&reader)) != nil, let name = try? IDBKey.readString(&reader),
                  reader.isAtEnd, name == database, let id = IDBKey.decodeInt(value) else { continue }
            databaseIDs.append(id)
        }
        guard databaseIDs.count == 1, let databaseID = databaseIDs.first else { return nil }

        // ObjectStoreNamesKey: database prefix, type 200, name → store ID; confirmed by the store's own name entry.
        let storeName = IDBKey.prefix(databaseID, 0, 0) + [200] + IDBKey.stringWithLength(objectStore)
        guard let idBytes = live[storeName], idBytes.count == 1, idBytes[0] < 0x80 else { return nil }
        let objectStoreID = UInt64(idBytes[0])
        guard live[IDBKey.objectStoreMetadata(databaseID, objectStoreID, .name)] == IDBKey.utf16BE(objectStore) else { return nil }
        let lastVersion = live[IDBKey.objectStoreMetadata(databaseID, objectStoreID, .lastVersion)].flatMap(IDBKey.decodeInt) ?? 0
        if let autoIncrement = live[IDBKey.objectStoreMetadata(databaseID, objectStoreID, .autoIncrement)],
           autoIncrement.contains(where: { $0 != 0 }) { return nil }
        var storeID = ByteWriter()
        storeID.appendVarint64(objectStoreID)
        let indexes = IDBKey.prefix(databaseID, 0, 0) + [IDBKey.indexMetadataType] + storeID.bytes
        guard !live.keys.contains(where: { $0.starts(with: indexes) }) else { return nil }

        var records: [String: Record] = [:], blobKeys = Set<String>()
        let data = IDBKey.prefix(databaseID, objectStoreID, IDBKey.dataIndex)
        let blobs = IDBKey.prefix(databaseID, objectStoreID, IDBKey.blobIndex)
        for (key, value) in live {
            if key.starts(with: data), let name = IDBKey.stringKey(key, after: data.count) {
                var reader = ByteReader(value)
                guard let version = try? reader.varint64() else { continue }
                records[name] = Record(version: version, value: Array(value[reader.pos...]))
            } else if key.starts(with: blobs), let name = IDBKey.stringKey(key, after: blobs.count) {
                blobKeys.insert(name)
            }
        }
        return Snapshot(dataVersion: live[IDBKey.prefix(0, 0, 0) + [IDBKey.dataVersionType]].flatMap(IDBKey.decodeInt),
                        databaseID: databaseID, objectStoreID: objectStoreID, lastVersion: lastVersion,
                        records: records, blobKeys: blobKeys)
    }

    /// Stores each value (serialized the way `Record.value` is) under its key, as IndexedDB's own `put` does:
    /// the record with a new version number, its exists entry, and the store's last version.
    func write(_ values: [String: [UInt8]], into snapshot: Snapshot) throws {
        guard !values.isEmpty else { return }
        guard values.keys.allSatisfy({ !snapshot.blobKeys.contains($0) }) else { throw LocalStorageError.corrupt("record has blobs") }
        let db = snapshot.databaseID, os = snapshot.objectStoreID
        var version = max(snapshot.lastVersion, snapshot.records.values.map(\.version).max() ?? 0)
        var put: [([UInt8], [UInt8])] = []
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            version += 1
            var record = ByteWriter()
            record.appendVarint64(version)
            put.append((IDBKey.prefix(db, os, IDBKey.dataIndex) + IDBKey.string(key), record.bytes + value))
            put.append((IDBKey.prefix(db, os, IDBKey.existsIndex) + IDBKey.string(key), IDBKey.encodeInt(version)))
        }
        put.append((IDBKey.objectStoreMetadata(db, os, .lastVersion), IDBKey.encodeInt(version)))
        try store.append(put: put, delete: [])
    }
}

/// Chromium's IndexedDB key encoding (`indexed_db_leveldb_coding`).
enum IDBKey {
    static let dataIndex: UInt64 = 1, existsIndex: UInt64 = 2, blobIndex: UInt64 = 3
    /// Key types: the backing store's data version (global), and an index's metadata (per database).
    static let dataVersionType: UInt8 = 2, indexMetadataType: UInt8 = 100

    enum ObjectStoreMetadata: UInt8 { case name = 0, autoIncrement = 2, lastVersion = 4 }

    /// A `KeyPrefix`: one byte giving the lengths of the three IDs, then each ID in as few little-endian bytes as it needs.
    static func prefix(_ database: UInt64, _ objectStore: UInt64, _ index: UInt64) -> [UInt8] {
        let d = encodeInt(database), o = encodeInt(objectStore), i = encodeInt(index)
        let lengths: Int = (d.count - 1) << 5 | (o.count - 1) << 2 | (i.count - 1)
        var key: [UInt8] = [UInt8(lengths)]
        key += d
        key += o
        key += i
        return key
    }

    static func objectStoreMetadata(_ database: UInt64, _ objectStore: UInt64, _ type: ObjectStoreMetadata) -> [UInt8] {
        var writer = ByteWriter()
        writer.appendVarint64(objectStore)
        var key = prefix(database, 0, 0)
        key.append(50)
        key += writer.bytes
        key.append(type.rawValue)
        return key
    }

    /// `EncodeInt`: little-endian, as few bytes as the value needs, at least one.
    static func encodeInt(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = [], n = value
        repeat { bytes.append(UInt8(n & 0xFF)); n >>= 8 } while n > 0
        return bytes
    }

    static func decodeInt(_ bytes: [UInt8]) -> UInt64? {
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        return bytes.enumerated().reduce(0) { $0 | (UInt64($1.element) << (8 * UInt64($1.offset))) }
    }

    static func utf16BE(_ string: String) -> [UInt8] { string.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] } }

    /// `StringWithLength`: the length in UTF-16 units as a varint, then the units big-endian.
    static func stringWithLength(_ string: String) -> [UInt8] {
        var writer = ByteWriter()
        writer.appendVarint64(UInt64(string.utf16.count))
        return writer.bytes + utf16BE(string)
    }

    /// An IndexedDB key that is a string.
    static func string(_ string: String) -> [UInt8] { [0x01] + stringWithLength(string) }

    static func readString(_ reader: inout ByteReader) throws -> String {
        let count = Int(try reader.varint64())
        let bytes = try reader.bytes(count * 2)
        let units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
        return String(decoding: units, as: UTF16.self)
    }

    /// The string an object store key holds, if the rest of `key` after `offset` is exactly one string key.
    static func stringKey(_ key: [UInt8], after offset: Int) -> String? {
        guard key.count > offset, key[offset] == 0x01 else { return nil }
        var reader = ByteReader(key, at: offset + 1)
        guard let string = try? readString(&reader), reader.isAtEnd else { return nil }
        return string
    }
}

/// The few shapes of a serialized IndexedDB value (Blink's envelope around V8's serializer) that hold one string.
enum IDBValue {
    static func string(in bytes: [UInt8]) -> String? {
        var reader = ByteReader(bytes)
        do {
            // Version headers: Blink's (with an optional trailer offset of 12 bytes after it), then V8's.
            while !reader.isAtEnd, reader.data[reader.pos] == 0xFF {
                _ = try reader.byte()
                _ = try reader.varint64()
                if !reader.isAtEnd, reader.data[reader.pos] == 0xFE { _ = try reader.bytes(13) }
            }
            while !reader.isAtEnd, reader.data[reader.pos] == 0x00 { _ = try reader.byte() }   // padding
            let tag = try reader.byte()
            let length = Int(try reader.varint64())
            let payload = try reader.bytes(length)
            guard reader.isAtEnd else { return nil }
            switch tag {
            case 0x22: return String(decoding: payload.map { UInt16($0) }, as: UTF16.self)   // Latin-1
            case 0x63:   // UTF-16LE
                guard length % 2 == 0 else { return nil }
                let units = stride(from: 0, to: length, by: 2).map { UInt16(payload[$0]) | UInt16(payload[$0 + 1]) << 8 }
                return String(decoding: units, as: UTF16.self)
            case 0x53: return String(bytes: payload, encoding: .utf8)
            default: return nil
            }
        } catch {
            return nil
        }
    }
}
