import Foundation

enum CloudDefaults {
    static let baseURL = "https://ledger.893884474.xyz"
    static let clientType = "ios"
}

struct RemoteDirectoryRecord: Codable, Equatable {
    let name: String
    let createdAt: String?
    let updatedAt: String?
}

struct RemoteBillItemRecord: Codable, Equatable {
    let customer: String
    let employee: String
    let model: String
    let quantity: Int
    let colorCount: Int
}

struct RemoteBillRecord: Codable, Equatable {
    let date: String
    let submittedAt: String
    let items: [RemoteBillItemRecord]
}

struct RemoteWorkshopData: Codable, Equatable {
    let schemaVersion: Int
    let customers: [RemoteDirectoryRecord]
    let employees: [RemoteDirectoryRecord]
    let bills: [RemoteBillRecord]
}

struct RemoteSnapshotRecord: Codable, Identifiable, Equatable {
    let id: Int
    let localDate: String
    let fileName: String
    let sizeBytes: Int
    let sha256: String
    let revision: Int
    let createdAt: String
    let downloadUrl: String?

    var createdDate: Date? {
        CloudDate.parse(createdAt)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }
}

struct RemoteSessionInfo: Codable, Equatable {
    let clientType: String
    let scope: String
}

struct RemoteWorkspaceResponse: Codable {
    let revision: Int
    let updatedAt: String
    let serverTime: String
    let latestSnapshot: RemoteSnapshotRecord?
    let data: RemoteWorkshopData
    let session: RemoteSessionInfo?
}

struct RemoteLoginResponse: Codable {
    let token: String
    let tokenType: String
    let expiresAt: String
    let username: String
    let clientType: String
    let scope: String
}

struct RemoteSaveResponse: Codable {
    let ok: Bool
    let revision: Int
    let updatedAt: String
    let latestSnapshot: RemoteSnapshotRecord?
}

struct RemoteSnapshotListResponse: Codable {
    let snapshots: [RemoteSnapshotRecord]
}

struct RemoteSnapshotEnvelope: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let localDate: String
    let revision: Int
    let data: RemoteWorkshopData
}

private struct RemoteLoginRequest: Encodable {
    let username: String
    let password: String
    let clientType: String
}

private struct RemoteWorkshopUploadRequest: Encodable {
    let data: RemoteWorkshopData
}

private struct RemoteSimpleResponse: Decodable {
    let ok: Bool?
}

enum CloudDate {
    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        return regular.date(from: value)
    }
}

enum RemoteLedgerError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "服务器地址格式不正确。"
        case .invalidResponse:
            return "服务器返回了无法识别的数据。"
        case .unauthorized:
            return "账号登录已失效，请重新登录。"
        case .server(_, let message):
            return message
        }
    }
}

final class HTTPRemoteLedgerService {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 90
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)
        }
    }

    func login(baseURL: URL, username: String, password: String, clientType: String) async throws -> RemoteLoginResponse {
        let body = try encoder.encode(RemoteLoginRequest(username: username, password: password, clientType: clientType))
        return try await request(baseURL: baseURL, path: "/api/v1/auth/login", method: "POST", token: nil, body: body)
    }

    func logout(baseURL: URL, token: String) async {
        guard let url = URL(string: "/api/v1/auth/logout", relativeTo: baseURL) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    func fetchWorkspace(baseURL: URL, token: String) async throws -> RemoteWorkspaceResponse {
        try await request(baseURL: baseURL, path: "/api/v1/workshop", method: "GET", token: token, body: nil)
    }

    func saveWorkspace(baseURL: URL, token: String, data: RemoteWorkshopData) async throws -> RemoteSaveResponse {
        let body = try encoder.encode(RemoteWorkshopUploadRequest(data: data))
        return try await request(baseURL: baseURL, path: "/api/v1/workshop", method: "PUT", token: token, body: body)
    }

    func listSnapshots(baseURL: URL, token: String, limit: Int = 10) async throws -> [RemoteSnapshotRecord] {
        let response: RemoteSnapshotListResponse = try await request(
            baseURL: baseURL,
            path: "/api/v1/snapshots?limit=\(min(10, max(1, limit)))",
            method: "GET",
            token: token,
            body: nil
        )
        return response.snapshots
    }

    func fetchSnapshot(baseURL: URL, token: String, id: Int) async throws -> RemoteSnapshotEnvelope {
        try await request(
            baseURL: baseURL,
            path: "/api/v1/snapshots/\(id)/json",
            method: "GET",
            token: token,
            body: nil
        )
    }

    private func request<Response: Decodable>(
        baseURL: URL,
        path: String,
        method: String,
        token: String?,
        body: Data?
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw RemoteLedgerError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteLedgerError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? decoder.decode(ServerErrorResponse.self, from: data)
            if http.statusCode == 401 {
                throw RemoteLedgerError.unauthorized
            }
            throw RemoteLedgerError.server(
                status: http.statusCode,
                message: payload?.error ?? "服务器请求失败（HTTP \(http.statusCode)）"
            )
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw RemoteLedgerError.invalidResponse
        }
    }
}

private struct ServerErrorResponse: Decodable {
    let error: String
}
