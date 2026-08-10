import Foundation

/// Raw Drive v3 REST against the private `appDataFolder`, via `URLSession` — no
/// Google API client library. Mirrors the shape of Android's `DriveBackup.kt`
/// exactly (same endpoints, same `multipart/related` create, same media PATCH),
/// so both platforms read and write the same two files:
///
///   filewall-backup.key       the managed passphrase (Base64 of 32 bytes)
///   filewall-backup.fwvault   the encrypted archive
///
/// The `appDataFolder` is app-private: Google stores opaque bytes it cannot read,
/// and the app cannot see the user's other Drive files.
struct DriveClient {

    /// Supplies a fresh (auto-refreshing) access token per call.
    let accessToken: () async throws -> String

    private static let driveBase = "https://www.googleapis.com/drive/v3/files"
    private static let uploadBase = "https://www.googleapis.com/upload/drive/v3/files"
    private static let appDataFolder = "appDataFolder"
    private static let octetStream = "application/octet-stream"

    enum DriveError: Error {
        case http(stage: String, code: Int, message: String?)
        case emptyBody
    }

    // MARK: - Lookup

    /// Find a file id by exact name in the app-data space, or nil.
    func findFileId(name: String) async throws -> String? {
        var comps = URLComponents(string: Self.driveBase)!
        comps.queryItems = [
            .init(name: "spaces", value: Self.appDataFolder),
            .init(name: "fields", value: "files(id,name)"),
            .init(name: "pageSize", value: "100")
        ]
        let (data, _) = try await send(request(url: comps.url!), stage: "Lookup")
        let files = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["files"] as? [[String: Any]] ?? []
        return files.first { ($0["name"] as? String) == name }?["id"] as? String
    }

    /// modifiedTime of the stored backup archive, or nil.
    func lastBackupModifiedTime() async throws -> String? {
        var comps = URLComponents(string: Self.driveBase)!
        comps.queryItems = [
            .init(name: "spaces", value: Self.appDataFolder),
            .init(name: "fields", value: "files(id,name,modifiedTime)"),
            .init(name: "pageSize", value: "10")
        ]
        let (data, _) = try await send(request(url: comps.url!), stage: "List")
        let files = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["files"] as? [[String: Any]] ?? []
        return files.first { ($0["name"] as? String) == InteropArchiveName.archive }?["modifiedTime"] as? String
    }

    // MARK: - Download

    /// Download a file's bytes into memory (used for the small managed-key file).
    func downloadData(id: String) async throws -> Data {
        let (data, _) = try await send(request(url: URL(string: "\(Self.driveBase)/\(id)?alt=media")!),
                                       stage: "Download")
        return data
    }

    /// Stream a file to `destination` (used for the archive, which can be large).
    func download(id: String, to destination: URL) async throws {
        var req = request(url: URL(string: "\(Self.driveBase)/\(id)?alt=media")!)
        req.httpMethod = "GET"
        let (tempURL, response) = try await URLSession.shared.download(for: req)
        try Self.check(response, stage: "Download")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    // MARK: - Upload (create or replace)

    /// Upload small `data` under `name`, creating or replacing.
    func uploadData(name: String, data: Data) async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        try await uploadFile(name: name, fileURL: temp)
    }

    /// Upload a file under `name`, creating (multipart) or replacing (media PATCH).
    /// Uses `uploadTask(fromFile:)` so a multi-GB archive never sits in memory.
    func uploadFile(name: String, fileURL: URL) async throws {
        let token = try await accessToken()
        if let existingId = try await findFileId(name: name) {
            // Replace: PATCH media.
            var req = URLRequest(url: URL(string: "\(Self.uploadBase)/\(existingId)?uploadType=media&fields=id")!)
            req.httpMethod = "PATCH"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue(Self.octetStream, forHTTPHeaderField: "Content-Type")
            let (_, response) = try await URLSession.shared.upload(for: req, fromFile: fileURL)
            try Self.check(response, stage: "Upload")
        } else {
            // Create: multipart/related (JSON metadata part + media part). We build
            // the multipart body to a temp file so the media part streams from disk.
            let boundary = "fwvault-\(UUID().uuidString)"
            let metadata = try JSONSerialization.data(withJSONObject: [
                "name": name,
                "parents": [Self.appDataFolder]
            ])
            let bodyURL = try Self.buildMultipart(boundary: boundary, metadata: metadata, mediaFile: fileURL)
            defer { try? FileManager.default.removeItem(at: bodyURL) }

            var req = URLRequest(url: URL(string: "\(Self.uploadBase)?uploadType=multipart&fields=id")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await URLSession.shared.upload(for: req, fromFile: bodyURL)
            try Self.check(response, stage: "Upload")
        }
    }

    // MARK: - Internals

    private func request(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        return req
    }

    /// Attach the bearer token and run the request.
    private func send(_ base: URLRequest, stage: String) async throws -> (Data, URLResponse) {
        var req = base
        req.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.check(response, stage: stage, body: data)
        return (data, response)
    }

    private static func check(_ response: URLResponse, stage: String, body: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw DriveError.emptyBody }
        guard (200..<300).contains(http.statusCode) else {
            let message = body
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String }
            throw DriveError.http(stage: stage, code: http.statusCode, message: message)
        }
    }

    /// Writes `--boundary / json part / --boundary / media part / --boundary--` to
    /// a temp file, copying the media bytes in 64 KiB chunks so the body never
    /// fully resides in memory.
    private static func buildMultipart(boundary: String, metadata: Data, mediaFile: URL) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mp-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }

        func write(_ s: String) throws { try out.write(contentsOf: Data(s.utf8)) }

        try write("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
        try out.write(contentsOf: metadata)
        try write("\r\n--\(boundary)\r\nContent-Type: \(octetStream)\r\n\r\n")

        let input = try FileHandle(forReadingFrom: mediaFile)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n")
        return url
    }
}

/// The fixed Drive file names, shared with the interop codec.
enum InteropArchiveName {
    static let archive = "filewall-backup.fwvault"
    static let key = "filewall-backup.key"
}
