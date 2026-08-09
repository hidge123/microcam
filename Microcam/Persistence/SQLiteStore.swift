import Foundation
import SQLite3

enum SQLiteStoreError: LocalizedError {
    case openFailed(String)
    case statementFailed(String)
    case corruptedEncryptedField

    var errorDescription: String? {
        switch self {
        case let .openFailed(message): "无法打开活动数据库：\(message)"
        case let .statementFailed(message): "数据库操作失败：\(message)"
        case .corruptedEncryptedField: "数据库中的加密字段已损坏"
        }
    }
}

actor SQLiteStore {
    // SQLite is opened in FULLMUTEX mode and every operation is serialized by this actor.
    // `nonisolated(unsafe)` is limited to allowing deinit to close the C pointer.
    nonisolated(unsafe) private var database: OpaquePointer?
    private let cryptoBox: CryptoBox
    let databaseURL: URL

    init(cryptoBox: CryptoBox, databaseURL overrideURL: URL? = nil) throws {
        self.cryptoBox = cryptoBox

        let url: URL
        if let overrideURL {
            url = overrideURL
        } else {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let directory = applicationSupport.appendingPathComponent("Microcam", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            url = directory.appendingPathComponent("microcam.sqlite")
        }
        databaseURL = url

        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw SQLiteStoreError.openFailed(message)
        }
        database = handle
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        try Self.execute(handle, "PRAGMA journal_mode=WAL;")
        try Self.execute(handle, "PRAGMA synchronous=NORMAL;")
        try Self.execute(handle, "PRAGMA secure_delete=ON;")
        try Self.execute(handle, "PRAGMA foreign_keys=ON;")
        try Self.migrate(handle)
    }

    deinit {
        sqlite3_close(database)
    }

    func save(_ segment: ActivitySegment) throws {
        let sql = """
        INSERT INTO activity_segments
            (id, start_at, end_at, active_seconds, bundle_id, app_name, title_ciphertext, capture_policy, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            start_at = excluded.start_at,
            end_at = excluded.end_at,
            active_seconds = excluded.active_seconds,
            bundle_id = excluded.bundle_id,
            app_name = excluded.app_name,
            title_ciphertext = excluded.title_ciphertext,
            capture_policy = excluded.capture_policy;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        let titleData = try cryptoBox.seal(segment.sanitizedTitle)
        bind(segment.id.uuidString, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, segment.startAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, segment.endAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, segment.activeSeconds)
        bind(segment.bundleID, to: 5, in: statement)
        bind(segment.appName, to: 6, in: statement)
        bind(titleData, to: 7, in: statement)
        bind(segment.capturePolicy.rawValue, to: 8, in: statement)
        sqlite3_bind_double(statement, 9, Date().timeIntervalSince1970)
        try step(statement)
    }

    func fetchSegments(from start: Date, to end: Date) throws -> [ActivitySegment] {
        let sql = """
        SELECT id, start_at, end_at, bundle_id, app_name, title_ciphertext, capture_policy
        FROM activity_segments
        WHERE end_at > ? AND start_at < ?
        ORDER BY start_at ASC;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, end.timeIntervalSince1970)

        var segments: [ActivitySegment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let idValue = columnString(statement, 0),
                let id = UUID(uuidString: idValue),
                let bundleID = columnString(statement, 3),
                let appName = columnString(statement, 4),
                let policyValue = columnString(statement, 6),
                let policy = AppCapturePolicy(rawValue: policyValue)
            else { continue }

            let encryptedTitle = columnData(statement, 5)
            let title: String?
            do {
                title = try cryptoBox.open(encryptedTitle)
            } catch {
                throw SQLiteStoreError.corruptedEncryptedField
            }

            segments.append(ActivitySegment(
                id: id,
                startAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                endAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                bundleID: bundleID,
                appName: appName,
                sanitizedTitle: title,
                capturePolicy: policy
            ))
        }
        return segments
    }

    func fetchActivityDaySummaries(
        calendar: Calendar = .autoupdatingCurrent,
        now: Date = Date()
    ) throws -> [ActivityDaySummary] {
        // Keep this query deliberately free of title_ciphertext. Daily list rendering
        // must never decrypt or otherwise touch window titles.
        let statement = try prepare("""
        SELECT start_at, end_at, bundle_id, app_name
        FROM activity_segments
        WHERE end_at > start_at
        ORDER BY start_at ASC;
        """)
        defer { sqlite3_finalize(statement) }

        var records: [ActivityIntervalRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let bundleID = columnString(statement, 2),
                let appName = columnString(statement, 3)
            else { continue }
            records.append(ActivityIntervalRecord(
                startAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                endAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                bundleID: bundleID,
                appName: appName
            ))
        }
        return ActivityDayAggregator.summarize(records, calendar: calendar, now: now)
    }

    func fetchSegments(
        forDay day: String,
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> [ActivitySegment] {
        guard
            let start = DateCoding.date(fromDay: day, calendar: calendar),
            let interval = calendar.dateInterval(of: .day, for: start)
        else { return [] }

        return try fetchSegments(from: interval.start, to: interval.end).compactMap { segment in
            let clippedStart = max(segment.startAt, interval.start)
            let clippedEnd = min(segment.endAt, interval.end)
            guard clippedEnd > clippedStart else { return nil }
            return ActivitySegment(
                id: segment.id,
                startAt: clippedStart,
                endAt: clippedEnd,
                bundleID: segment.bundleID,
                appName: segment.appName,
                sanitizedTitle: segment.sanitizedTitle,
                capturePolicy: segment.capturePolicy
            )
        }
    }

    func save(_ diary: DiaryEntry) throws {
        let sql = """
        INSERT INTO diary_entries (day, status, content_ciphertext, model, generated_at, error_code)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(day) DO UPDATE SET
            status = excluded.status,
            content_ciphertext = excluded.content_ciphertext,
            model = excluded.model,
            generated_at = excluded.generated_at,
            error_code = excluded.error_code;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(diary.day, to: 1, in: statement)
        bind(diary.status.rawValue, to: 2, in: statement)
        bind(try cryptoBox.seal(diary.content), to: 3, in: statement)
        bind(diary.model, to: 4, in: statement)
        if let generatedAt = diary.generatedAt {
            sqlite3_bind_double(statement, 5, generatedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        bind(diary.errorCode, to: 6, in: statement)
        try step(statement)
    }

    func fetchDiaries() throws -> [DiaryEntry] {
        let statement = try prepare("""
        SELECT day, status, content_ciphertext, model, generated_at, error_code
        FROM diary_entries ORDER BY day DESC;
        """)
        defer { sqlite3_finalize(statement) }
        var result: [DiaryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let diary = try decodeDiary(statement) { result.append(diary) }
        }
        return result
    }

    func diary(for day: String) throws -> DiaryEntry? {
        let statement = try prepare("""
        SELECT day, status, content_ciphertext, model, generated_at, error_code
        FROM diary_entries WHERE day = ? LIMIT 1;
        """)
        defer { sqlite3_finalize(statement) }
        bind(day, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decodeDiary(statement)
    }

    func deleteActivities(
        forDay day: String,
        calendar: Calendar = .autoupdatingCurrent
    ) throws {
        guard
            let date = DateCoding.date(fromDay: day, calendar: calendar),
            let interval = calendar.dateInterval(of: .day, for: date)
        else { return }

        // Preserve portions of any legacy segment that crosses this day's boundary.
        // Current monitoring normally closes segments at midnight, but this also keeps
        // deletion safe for databases created by older builds.
        let overlapping = try fetchSegments(from: interval.start, to: interval.end)
        guard !overlapping.isEmpty else { return }

        try execute("BEGIN IMMEDIATE;")
        do {
            let statement = try prepare("DELETE FROM activity_segments WHERE end_at > ? AND start_at < ?;")
            sqlite3_bind_double(statement, 1, interval.start.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, interval.end.timeIntervalSince1970)
            do {
                try step(statement)
                sqlite3_finalize(statement)
            } catch {
                sqlite3_finalize(statement)
                throw error
            }

            for segment in overlapping {
                let hasLeadingPart = segment.startAt < interval.start
                if hasLeadingPart {
                    try save(ActivitySegment(
                        id: segment.id,
                        startAt: segment.startAt,
                        endAt: interval.start,
                        bundleID: segment.bundleID,
                        appName: segment.appName,
                        sanitizedTitle: segment.sanitizedTitle,
                        capturePolicy: segment.capturePolicy
                    ))
                }
                if segment.endAt > interval.end {
                    try save(ActivitySegment(
                        id: hasLeadingPart ? UUID() : segment.id,
                        startAt: interval.end,
                        endAt: segment.endAt,
                        bundleID: segment.bundleID,
                        appName: segment.appName,
                        sanitizedTitle: segment.sanitizedTitle,
                        capturePolicy: segment.capturePolicy
                    ))
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func deleteDiary(for day: String) throws {
        let statement = try prepare("DELETE FROM diary_entries WHERE day = ?;")
        defer { sqlite3_finalize(statement) }
        bind(day, to: 1, in: statement)
        try step(statement)
    }

    func deleteActivities(olderThan cutoff: Date? = nil) throws {
        if let cutoff {
            let statement = try prepare("DELETE FROM activity_segments WHERE end_at < ?;")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
            try step(statement)
        } else {
            try execute("DELETE FROM activity_segments;")
            try execute("PRAGMA wal_checkpoint(TRUNCATE);")
        }
    }

    func deleteDiaries() throws {
        try execute("DELETE FROM diary_entries;")
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    func deleteAllData() throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try execute("DELETE FROM activity_segments;")
            try execute("DELETE FROM diary_entries;")
            try execute("COMMIT;")
            try execute("PRAGMA wal_checkpoint(TRUNCATE);")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func decodeDiary(_ statement: OpaquePointer?) throws -> DiaryEntry? {
        guard
            let day = columnString(statement, 0),
            let statusValue = columnString(statement, 1),
            let status = DiaryStatus(rawValue: statusValue),
            let model = columnString(statement, 3)
        else { return nil }
        let content: String?
        do {
            content = try cryptoBox.open(columnData(statement, 2))
        } catch {
            throw SQLiteStoreError.corruptedEncryptedField
        }
        let generatedAt = sqlite3_column_type(statement, 4) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
        return DiaryEntry(
            day: day,
            status: status,
            content: content,
            model: model,
            generatedAt: generatedAt,
            errorCode: columnString(statement, 5)
        )
    }

    private static func migrate(_ database: OpaquePointer) throws {
        try execute(database, """
        CREATE TABLE IF NOT EXISTS activity_segments (
            id TEXT PRIMARY KEY NOT NULL,
            start_at REAL NOT NULL,
            end_at REAL NOT NULL,
            active_seconds REAL NOT NULL,
            bundle_id TEXT NOT NULL,
            app_name TEXT NOT NULL,
            title_ciphertext BLOB,
            capture_policy TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_activity_time ON activity_segments(start_at, end_at);
        CREATE INDEX IF NOT EXISTS idx_activity_app ON activity_segments(bundle_id);
        CREATE TABLE IF NOT EXISTS diary_entries (
            day TEXT PRIMARY KEY NOT NULL,
            status TEXT NOT NULL,
            content_ciphertext BLOB,
            model TEXT NOT NULL,
            generated_at REAL,
            error_code TEXT
        );
        PRAGMA user_version=1;
        """)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteStoreError.statementFailed(errorMessage)
        }
        return statement
    }

    private func step(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.statementFailed(errorMessage)
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw SQLiteStoreError.openFailed("closed") }
        try Self.execute(database, sql)
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(message)
            throw SQLiteStoreError.statementFailed(text)
        }
    }

    private var errorMessage: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed"
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        sqlite3_bind_text(statement, index, value, -1, sqliteTransientDestructor())
    }

    private func bind(_ value: Data?, to index: Int32, in statement: OpaquePointer?) {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), sqliteTransientDestructor())
        }
    }

    private func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func columnData(_ statement: OpaquePointer?, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
}

private func sqliteTransientDestructor() -> sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
