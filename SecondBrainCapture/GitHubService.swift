import Foundation

struct GitHubConfig {
    var owner: String
    var repo: String
    var branch: String
    var folder: String
}

enum GitHubError: LocalizedError {
    case missingToken
    case badURL
    case badResponse(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingToken: return "No GitHub token set — add one in Settings."
        case .badURL: return "Couldn't build the request URL."
        case .badResponse(let code, let msg): return "GitHub \(code): \(msg)"
        }
    }
}

/// Writes notes into the repo's Inbox folder via the GitHub Contents API.
/// Only ever creates new files (timestamped), so it never conflicts with the
/// Mac's Obsidian Git auto-commits.
struct GitHubService {
    let config: GitHubConfig
    let token: String

    private func authedRequest(url: URL, method: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("SecondBrainCapture", forHTTPHeaderField: "User-Agent")
        return req
    }

    /// GET the repo to verify token + owner/repo are valid.
    func testConnection() async throws {
        guard !token.isEmpty else { throw GitHubError.missingToken }
        guard let url = URL(string: "https://api.github.com/repos/\(config.owner)/\(config.repo)") else {
            throw GitHubError.badURL
        }
        let (data, resp) = try await URLSession.shared.data(for: authedRequest(url: url, method: "GET"))
        try Self.check(resp, data)
    }

    /// Create a new markdown note in `<folder>/`. Returns the filename written.
    /// `date` is the moment the note was captured — passing it explicitly keeps
    /// queued offline notes stamped with their original time, not their sync time.
    @discardableResult
    func commitNote(text: String, date: Date = Date()) async throws -> String {
        guard !token.isEmpty else { throw GitHubError.missingToken }

        let filename = Self.makeFilename(from: text, date: date)
        let path = "\(config.folder)/\(filename)"
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.github.com/repos/\(config.owner)/\(config.repo)/contents/\(encodedPath)") else {
            throw GitHubError.badURL
        }

        let markdown = Self.makeMarkdown(from: text, date: date)
        let body: [String: Any] = [
            "message": "mobile capture: \(filename)",
            "content": Data(markdown.utf8).base64EncodedString(),
            "branch": config.branch
        ]

        var req = authedRequest(url: url, method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
        return filename
    }

    // MARK: - Helpers

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let msg = (json?["message"] as? String)
                ?? String(data: data, encoding: .utf8)
                ?? "Unknown error"
            throw GitHubError.badResponse(http.statusCode, msg)
        }
    }

    static func makeFilename(from text: String, date: Date = Date()) -> String {
        let stamp = DateFormatter.filenameStamp.string(from: date)
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let slug = slugify(firstLine)
        return slug.isEmpty ? "\(stamp).md" : "\(stamp) - \(slug).md"
    }

    static func makeMarkdown(from text: String, date: Date = Date()) -> String {
        let iso = ISO8601DateFormatter().string(from: date)
        return """
        ---
        date: \(iso)
        tags:
          - inbox
          - mobile-capture
        source: mobile
        ---

        \(text)
        """
    }

    static func slugify(_ s: String) -> String {
        let mapped = s.lowercased().map { ($0.isLetter || $0.isNumber) ? $0 : "-" }
        var slug = String(mapped)
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(slug.prefix(40))
    }
}

extension DateFormatter {
    static let filenameStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
