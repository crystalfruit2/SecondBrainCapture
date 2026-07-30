import Foundation

/// Reading the vault, and writing single lines back into it.
///
/// The capture path only ever *creates* files, which is why it can never
/// conflict with the Mac's Obsidian Git auto-commits. Task check-offs are the
/// first writes that touch an existing note, so they are kept as narrow as
/// possible: fetch the file, change exactly one line, commit with the SHA we
/// read. Anything else that moved in the meantime is left untouched, and a
/// concurrent edit surfaces as a 409 we retry once against fresh content.
extension GitHubService {

    struct RemoteFile {
        let content: String
        let sha: String
    }

    /// Fetch and decode `dashboard.json` from the repo root.
    func fetchDashboard(path: String) async throws -> Dashboard {
        guard !token.isEmpty else { throw GitHubError.missingToken }
        guard let url = contentsURL(for: path, ref: config.branch) else { throw GitHubError.badURL }

        var req = authedRequest(url: url, method: "GET")
        // The raw representation skips base64 and, more importantly, skips the
        // JSON envelope for what is already a JSON document.
        req.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        // The dashboard is rewritten by CI several times a day; a stale cached
        // copy would silently show yesterday's buckets.
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)

        do {
            return try JSONDecoder().decode(Dashboard.self, from: data)
        } catch {
            throw GitHubError.badResponse(200, "dashboard.json didn't parse: \(error.localizedDescription)")
        }
    }

    /// Fetch a text file plus its blob SHA (needed to write it back).
    func fetchFile(path: String) async throws -> RemoteFile {
        guard !token.isEmpty else { throw GitHubError.missingToken }
        guard let url = contentsURL(for: path, ref: config.branch) else { throw GitHubError.badURL }

        var req = authedRequest(url: url, method: "GET")
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String,
              let b64 = json["content"] as? String else {
            throw GitHubError.badResponse(200, "Unexpected contents response for \(path)")
        }
        // GitHub wraps base64 at 60 chars; Data(base64Encoded:) rejects the newlines.
        let cleaned = b64.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let raw = Data(base64Encoded: cleaned),
              let text = String(data: raw, encoding: .utf8) else {
            throw GitHubError.badResponse(200, "Couldn't decode \(path) as UTF-8 text")
        }
        return RemoteFile(content: text, sha: sha)
    }

    /// Rewrite exactly one line of a note.
    ///
    /// `expectedLine` / `lineNumber` come from the dashboard, which may be
    /// minutes or hours stale — so the line number is treated as a hint, not a
    /// fact, and we fall back to matching the line's text before giving up.
    /// `transform` receives the located line and returns its replacement.
    func editLine(path: String,
                  lineNumber: Int,
                  expectedLine: String,
                  message: String,
                  transform: (String) -> String) async throws {
        do {
            try await performEdit(path: path, lineNumber: lineNumber, expectedLine: expectedLine,
                                  message: message, transform: transform)
        } catch GitHubError.badResponse(let code, _) where code == 409 {
            // Someone (Obsidian Git, a Claude session) committed between our read
            // and our write. Re-read and apply on top of whatever landed.
            try await performEdit(path: path, lineNumber: lineNumber, expectedLine: expectedLine,
                                  message: message, transform: transform)
        }
    }

    private func performEdit(path: String,
                             lineNumber: Int,
                             expectedLine: String,
                             message: String,
                             transform: (String) -> String) async throws {
        let file = try await fetchFile(path: path)
        var lines = file.content.components(separatedBy: "\n")

        guard let index = TaskLineEditor.locate(expectedLine, in: lines, hint: lineNumber) else {
            throw GitHubError.badResponse(422, "That task is no longer in \(path) — pull to refresh.")
        }

        // Preserve a CRLF file's line endings: split on \n leaves the \r behind.
        let original = lines[index]
        let carriage = original.hasSuffix("\r")
        let body = carriage ? String(original.dropLast()) : original
        let updated = transform(body)
        guard updated != body else { return }   // already in the desired state — no-op commit avoided
        lines[index] = carriage ? updated + "\r" : updated

        try await putFile(path: path,
                          content: lines.joined(separator: "\n"),
                          sha: file.sha,
                          message: message)
    }

    private func putFile(path: String, content: String, sha: String, message: String) async throws {
        guard let url = contentsURL(for: path, ref: nil) else { throw GitHubError.badURL }
        let body: [String: Any] = [
            "message": message,
            "content": Data(content.utf8).base64EncodedString(),
            "sha": sha,
            "branch": config.branch
        ]
        var req = authedRequest(url: url, method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data)
    }

    private func contentsURL(for path: String, ref: String?) -> URL? {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        var comps = URLComponents(string: "https://api.github.com/repos/\(config.owner)/\(config.repo)/contents/\(encoded)")
        if let ref { comps?.queryItems = [URLQueryItem(name: "ref", value: ref)] }
        return comps?.url
    }
}

/// Pure string surgery on a markdown task line. Kept separate from the network
/// layer so the same rules apply to the optimistic local edit and the eventual
/// commit — and so they can be reasoned about without a token.
enum TaskLineEditor {

    /// Find the task's line. The dashboard's line number is only a hint: it goes
    /// stale the moment anything above it is edited, so an exact text match wins
    /// over position, and position is only trusted when the text agrees.
    static func locate(_ expected: String, in lines: [String], hint: Int) -> Int? {
        let needle = normalize(expected)
        guard !needle.isEmpty else { return nil }

        let hintIndex = hint - 1   // dashboard line numbers are 1-indexed
        if lines.indices.contains(hintIndex), normalize(lines[hintIndex]) == needle {
            return hintIndex
        }
        if let exact = lines.firstIndex(where: { normalize($0) == needle }) {
            return exact
        }
        // Last resort: the line's checkbox may already have been toggled by hand,
        // which changes the text we're matching on. Compare everything after it.
        let payload = normalize(stripCheckbox(expected))
        guard !payload.isEmpty else { return nil }
        return lines.firstIndex { line in
            isTaskLine(line) && normalize(stripCheckbox(line)) == payload
        }
    }

    /// Flip `- [ ]` ⇄ `- [x]`, leaving indentation, bullet style and the rest of
    /// the line exactly as they were.
    static func setDone(_ line: String, done: Bool) -> String {
        guard let range = checkboxRange(in: line) else { return line }
        return line.replacingCharacters(in: range, with: done ? "[x]" : "[ ]")
    }

    /// Move a task's `📅 YYYY-MM-DD` marker, adding one if it has no due date.
    static func setDue(_ line: String, to date: Date) -> String {
        let stamp = DateFormatter.vaultDay.string(from: date)
        if let range = line.range(of: #"📅\s*\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            return line.replacingCharacters(in: range, with: "📅 \(stamp)")
        }
        // No marker yet — append one, but keep it ahead of any ⏰ time marker so
        // the vault's own ordering convention survives.
        if let timeRange = line.range(of: #"\s*⏰\s*\d{1,2}:\d{2}"#, options: .regularExpression) {
            return line.replacingCharacters(in: timeRange,
                                            with: " 📅 \(stamp)" + line[timeRange])
        }
        return line.trimmingTrailingWhitespace() + " 📅 \(stamp)"
    }

    static func isTaskLine(_ line: String) -> Bool { checkboxRange(in: line) != nil }

    static func isDone(_ line: String) -> Bool {
        guard let range = checkboxRange(in: line) else { return false }
        return line[range].lowercased() != "[ ]"
    }

    // MARK: - Internals

    /// Range of the `[ ]` / `[x]` marker in a `- [ ] …` or `* [x] …` line.
    private static func checkboxRange(in line: String) -> Range<String.Index>? {
        line.range(of: #"^\s*[-*+]\s+\[[ xX]\]"#, options: .regularExpression)
            .flatMap { line.range(of: #"\[[ xX]\]"#, options: .regularExpression, range: $0) }
    }

    private static func stripCheckbox(_ line: String) -> String {
        guard let range = line.range(of: #"^\s*[-*+]\s+\[[ xX]\]\s*"#, options: .regularExpression) else {
            return line
        }
        return String(line[range.upperBound...])
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var s = self
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return s
    }
}
