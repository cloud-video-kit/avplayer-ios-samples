import Foundation

/// Finds the FairPlay `skd://` key URI inside an HLS playlist.
///
/// Used by the prefetch flow, which needs the key identifier up front to request the
/// license before playback. If given a master playlist it follows the first variant
/// down to the media playlist that carries the `#EXT-X-KEY` tag.
struct HLSKeyURIResolver: Sendable {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func fairPlayKeyURI(from hlsURL: URL) async throws -> String {
        try await fairPlayKeyURI(from: hlsURL, depth: 0)
    }

    static func extractFairPlayKeyURI(from playlist: String) -> String? {
        for line in playlist.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isKeyTag = trimmed.hasPrefix("#EXT-X-KEY:") || trimmed.hasPrefix("#EXT-X-SESSION-KEY:")
            guard isKeyTag,
                  let uri = attribute(named: "URI", in: trimmed),
                  uri.lowercased().hasPrefix("skd://") else {
                continue
            }
            return uri
        }
        return nil
    }

    static func firstVariantURL(in playlist: String, relativeTo baseURL: URL) -> URL? {
        var expectsVariant = false
        for line in playlist.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXT-X-STREAM-INF:") {
                expectsVariant = true
                continue
            }
            guard expectsVariant, !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
        }
        return nil
    }

    private func fairPlayKeyURI(from playlistURL: URL, depth: Int) async throws -> String {
        guard depth < 4 else {
            throw SampleError.fairPlayKeyNotFound
        }

        let (data, response) = try await urlSession.data(from: playlistURL)
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw SampleError.httpFailure(operation: "HLS playlist request", statusCode: httpResponse.statusCode)
        }
        guard let playlist = String(data: data, encoding: .utf8), !playlist.isEmpty else {
            throw SampleError.invalidPlaylist
        }

        if let keyURI = Self.extractFairPlayKeyURI(from: playlist) {
            return keyURI
        }
        guard let variantURL = Self.firstVariantURL(in: playlist, relativeTo: playlistURL) else {
            throw SampleError.fairPlayKeyNotFound
        }
        return try await fairPlayKeyURI(from: variantURL, depth: depth + 1)
    }

    private static func attribute(named name: String, in line: String) -> String? {
        let prefix = "\(name)=\""
        guard let prefixRange = line.range(of: prefix, options: .caseInsensitive) else { return nil }
        let valueStart = prefixRange.upperBound
        guard let valueEnd = line[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(line[valueStart..<valueEnd])
    }
}
