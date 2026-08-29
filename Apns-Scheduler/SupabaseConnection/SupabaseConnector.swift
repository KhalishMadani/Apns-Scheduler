//
//  SupabaseConnector.swift
//  Apns-Scheduler
//
//  Created by Muhammad Khalish Madani on 29/08/26.
//

import Foundation

// MARK: - Configuration

struct SupabaseConfig {
    let url: URL
    let anonKey: String

    /// Reads `SUPABASE_URL` and `SUPABASE_ANON_KEY` from the app's Info.plist.
    /// Add them there (backed by an .xcconfig) so keys stay out of source control.
    static func fromInfoPlist(bundle: Bundle = .main) throws -> SupabaseConfig {
        guard
            let urlString = bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            let url = URL(string: urlString)
        else { throw SupabaseError.missingConfiguration("SUPABASE_URL") }

        guard let key = bundle.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
              !key.isEmpty
        else { throw SupabaseError.missingConfiguration("SUPABASE_ANON_KEY") }

        return SupabaseConfig(url: url, anonKey: key)
    }
}

// MARK: - Errors

enum SupabaseError: LocalizedError {
    case missingConfiguration(String)
    case invalidURL
    case notAuthenticated
    /// Non-2xx response. `message` is the PostgREST/GoTrue error body when present.
    case api(status: Int, message: String)
    case decoding(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let key):
            return "Missing Supabase configuration value: \(key)"
        case .invalidURL:
            return "Could not build a valid Supabase request URL."
        case .notAuthenticated:
            return "No Supabase session. Sign in first."
        case .api(let status, let message):
            return "Supabase returned \(status): \(message)"
        case .decoding(let underlying):
            return "Failed to decode Supabase response: \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Session

nonisolated struct SupabaseSession: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: SupabaseUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
    }
}

nonisolated struct SupabaseUser: Codable, Sendable {
    let id: String
    let email: String?
}


// MARK: - Date parsing

private enum SupabaseDateFormat {
    static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - Connector

/// Minimal Supabase client over URLSession: PostgREST tables, RPC, and email/password auth.
/// An actor so the cached session can't be raced from multiple tasks.
actor SupabaseConnector {

    private let config: SupabaseConfig
    private let session: URLSession
    private var currentSession: SupabaseSession?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Postgres timestamptz comes back with fractional seconds
        // ("2026-08-29T11:43:00.123456+00:00"), which .iso8601 rejects.
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = SupabaseDateFormat.withFractionalSeconds.date(from: raw) {
                return date
            }
            if let date = SupabaseDateFormat.plain.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Unrecognized timestamp: \(raw)")
            )
        }
        return d
    }()

    init(config: SupabaseConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    var accessToken: String? { currentSession?.accessToken }
    var userID: String? { currentSession?.user.id }
    var isAuthenticated: Bool { currentSession != nil }

    /// Restore a session persisted elsewhere (Keychain) so requests resume as that user.
    func restore(session: SupabaseSession) {
        currentSession = session
    }

    // MARK: Auth

    @discardableResult
    func signUp(email: String, password: String) async throws -> SupabaseSession {
        try await authenticate(path: "/auth/v1/signup", email: email, password: password)
    }

    @discardableResult
    func signIn(email: String, password: String) async throws -> SupabaseSession {
        try await authenticate(
            path: "/auth/v1/token",
            query: [URLQueryItem(name: "grant_type", value: "password")],
            email: email,
            password: password
        )
    }

    func signOut() async throws {
        guard currentSession != nil else { return }
        var request = try makeRequest(path: "/auth/v1/logout", method: "POST")
        request.httpBody = Data("{}".utf8)
        _ = try await perform(request)
        currentSession = nil
    }

    @discardableResult
    func refreshSession() async throws -> SupabaseSession {
        guard let refreshToken = currentSession?.refreshToken else {
            throw SupabaseError.notAuthenticated
        }
        var request = try makeRequest(
            path: "/auth/v1/token",
            method: "POST",
            query: [URLQueryItem(name: "grant_type", value: "refresh_token")]
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["refresh_token": refreshToken]
        )
        let data = try await perform(request)
        let session = try decode(SupabaseSession.self, from: data)
        currentSession = session
        return session
    }

    private func authenticate(
        path: String,
        query: [URLQueryItem] = [],
        email: String,
        password: String
    ) async throws -> SupabaseSession {
        var request = try makeRequest(path: path, method: "POST", query: query)
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["email": email, "password": password]
        )
        let data = try await perform(request)
        let session = try decode(SupabaseSession.self, from: data)
        currentSession = session
        return session
    }

    // MARK: PostgREST

    /// SELECT. `filters` are raw PostgREST operators, e.g. `["user_id": "eq.\(id)"]`.
    func select<T: Decodable>(
        _ type: T.Type = T.self,
        from table: String,
        columns: String = "*",
        filters: [String: String] = [:],
        order: String? = nil,
        limit: Int? = nil
    ) async throws -> [T] {
        var query = [URLQueryItem(name: "select", value: columns)]
        query += filters.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let order { query.append(URLQueryItem(name: "order", value: order)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }

        let request = try makeRequest(path: "/rest/v1/\(table)", method: "GET", query: query)
        let data = try await perform(request)
        return try decode([T].self, from: data)
    }

    /// INSERT. Returns the inserted rows.
    @discardableResult
    func insert<Body: Encodable, T: Decodable>(
        _ values: Body,
        into table: String,
        returning: T.Type = T.self
    ) async throws -> [T] {
        var request = try makeRequest(path: "/rest/v1/\(table)", method: "POST")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try encoder.encode(values)
        let data = try await perform(request)
        return try decode([T].self, from: data)
    }

    /// UPSERT. `onConflict` is the unique column PostgREST merges on (e.g. "device_token").
    @discardableResult
    func upsert<Body: Encodable, T: Decodable>(
        _ values: Body,
        into table: String,
        onConflict: String? = nil,
        returning: T.Type = T.self
    ) async throws -> [T] {
        var query: [URLQueryItem] = []
        if let onConflict { query.append(URLQueryItem(name: "on_conflict", value: onConflict)) }

        var request = try makeRequest(path: "/rest/v1/\(table)", method: "POST", query: query)
        request.setValue(
            "resolution=merge-duplicates,return=representation",
            forHTTPHeaderField: "Prefer"
        )
        request.httpBody = try encoder.encode(values)
        let data = try await perform(request)
        return try decode([T].self, from: data)
    }

    /// UPDATE. `filters` are required — without them PostgREST updates every row.
    @discardableResult
    func update<Body: Encodable, T: Decodable>(
        _ values: Body,
        in table: String,
        filters: [String: String],
        returning: T.Type = T.self
    ) async throws -> [T] {
        let query = filters.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = try makeRequest(path: "/rest/v1/\(table)", method: "PATCH", query: query)
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try encoder.encode(values)
        let data = try await perform(request)
        return try decode([T].self, from: data)
    }

    /// DELETE. `filters` are required for the same reason as `update`.
    func delete(from table: String, filters: [String: String]) async throws {
        let query = filters.map { URLQueryItem(name: $0.key, value: $0.value) }
        let request = try makeRequest(path: "/rest/v1/\(table)", method: "DELETE", query: query)
        _ = try await perform(request)
    }

    // MARK: RPC

    @discardableResult
    func rpc<Body: Encodable, T: Decodable>(
        _ function: String,
        params: Body,
        returning: T.Type = T.self
    ) async throws -> T {
        var request = try makeRequest(path: "/rest/v1/rpc/\(function)", method: "POST")
        request.httpBody = try encoder.encode(params)
        let data = try await perform(request)
        return try decode(T.self, from: data)
    }

    // MARK: Plumbing

    private func makeRequest(
        path: String,
        method: String,
        query: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: config.url.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw SupabaseError.invalidURL }

        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SupabaseError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Fall back to the anon key so RLS policies for anonymous access still apply.
        let bearer = currentSession?.accessToken ?? config.anonKey
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.api(status: -1, message: "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "<no body>"
            throw SupabaseError.api(status: http.statusCode, message: message)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // DELETE and logout return an empty body; hand decodable-void callers something valid.
        if data.isEmpty, let empty = "{}".data(using: .utf8) {
            do { return try decoder.decode(T.self, from: empty) } catch { /* fall through */ }
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw SupabaseError.decoding(underlying: error)
        }
    }
}
