import Foundation

struct FairPlayConfiguration: Equatable, Sendable {
    let hlsURL: URL
    let certificateURL: URL
    let licenseURL: URL
    let brandGuid: String
    let userToken: String

    init(
        hlsURL: String,
        certificateURL: String,
        licenseURL: String,
        brandGuid: String,
        userToken: String
    ) throws {
        self.hlsURL = try Self.validHTTPURL(hlsURL, field: "HLS URL")
        self.certificateURL = try Self.validHTTPURL(certificateURL, field: "Certificate URL")
        self.licenseURL = try Self.validHTTPURL(licenseURL, field: "License URL")

        let trimmedBrandGuid = brandGuid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: trimmedBrandGuid) != nil else {
            throw SampleError.invalidBrandGuid
        }
        self.brandGuid = trimmedBrandGuid

        let trimmedToken = userToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw SampleError.missingToken
        }
        self.userToken = trimmedToken
    }

    /// Builds the FairPlay license request URL used by both playback and downloads.
    ///
    /// The host and path come from the configured License URL (your DRM endpoint).
    /// The query is composed explicitly from two known sources:
    /// - `brandGuid` – the tenant id, taken from configuration;
    /// - `KID` / `IV` – copied from the stream's `skd://` key identifier.
    ///
    /// The query is rebuilt rather than extended, so only these parameters are sent.
    /// The user token is never placed in the URL – it travels in the request header.
    func licenseRequestURL(for keyIdentifier: String) -> URL {
        guard var components = URLComponents(url: licenseURL, resolvingAgainstBaseURL: false) else {
            return licenseURL
        }

        // Start the query from the tenant id, then add only KID/IV from the stream.
        var queryItems = [URLQueryItem(name: "brandGuid", value: brandGuid)]
        if let keyComponents = URLComponents(string: keyIdentifier) {
            for item in keyComponents.queryItems ?? [] where ["kid", "iv"].contains(item.name.lowercased()) {
                queryItems.append(item)
            }
        }

        // Assigning queryItems replaces any query already on the configured URL.
        components.queryItems = queryItems
        return components.url ?? licenseURL
    }

    /// Normalises the key request identifier (the `skd://` URI) into the two shapes
    /// the FairPlay APIs need: the `raw` string (used to build the license URL) and
    /// the bytes after `skd://` (the content id passed when generating the SPC).
    static func contentIdentifier(from rawIdentifier: Any?) throws -> (raw: String, data: Data) {
        let raw: String
        if let value = rawIdentifier as? String {
            raw = value
        } else if let value = rawIdentifier as? URL {
            raw = value.absoluteString
        } else {
            throw SampleError.invalidKeyIdentifier
        }

        let contentID = raw.hasPrefix("skd://") ? String(raw.dropFirst("skd://".count)) : raw
        guard !contentID.isEmpty, let data = contentID.data(using: .utf8) else {
            throw SampleError.invalidKeyIdentifier
        }
        return (raw, data)
    }

    private static func validHTTPURL(_ value: String, field: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw SampleError.invalidURL(field)
        }
        return url
    }
}
