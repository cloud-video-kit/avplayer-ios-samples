import Foundation
import Security

/// The two DRM network calls FairPlay needs:
/// - `fetchCertificate` – GET the FairPlay application certificate;
/// - `acquireLicense` – POST the SPC and receive the CKC (the license).
///
/// Responses are accepted in the encodings Cloud DRM can return (certificate as raw
/// DER, base64 or PEM; CKC as raw bytes or a `{ "ckc": "<base64>" }` wrapper).
struct FairPlayLicenseClient: Sendable {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func fetchCertificate(configuration: FairPlayConfiguration) async throws -> Data {
        guard var components = URLComponents(
            url: configuration.certificateURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw SampleError.invalidURL("Certificate URL")
        }

        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "brandGuid", value: configuration.brandGuid),
            URLQueryItem(name: "usertoken", value: configuration.userToken)
        ]
        guard let url = components.url else {
            throw SampleError.invalidURL("Certificate URL")
        }

        let (data, response) = try await urlSession.data(from: url)
        try Self.validate(response: response, operation: "Certificate request")
        return try Self.decodeCertificate(data)
    }

    /// Streaming license request: uses the configured License URL with `KID`/`IV`
    /// copied from the manifest identifier.
    func acquireLicense(
        configuration: FairPlayConfiguration,
        keyIdentifier: String,
        spcData: Data
    ) async throws -> Data {
        try await acquireLicense(
            licenseURL: configuration.licenseRequestURL(for: keyIdentifier),
            configuration: configuration,
            spcData: spcData
        )
    }

    /// License request against an explicit URL. Used by downloads, which post the
    /// SPC to the manifest-derived license URL so the server issues a persistable
    /// license.
    func acquireLicense(
        licenseURL: URL,
        configuration: FairPlayConfiguration,
        spcData: Data
    ) async throws -> Data {
        var request = URLRequest(url: licenseURL)
        request.httpMethod = "POST"
        request.httpBody = spcData
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.brandGuid, forHTTPHeaderField: "x-drm-brandGuid")
        request.setValue(configuration.userToken, forHTTPHeaderField: "x-drm-usertoken")

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response: response, operation: "License request")
        return try Self.extractCKC(from: data)
    }

    static func decodeCertificate(_ data: Data) throws -> Data {
        if SecCertificateCreateWithData(nil, data as CFData) != nil {
            return data
        }

        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw SampleError.invalidCertificate
        }

        let base64Payload: String
        if text.contains("BEGIN CERTIFICATE") {
            base64Payload = text
                .split(whereSeparator: \.isNewline)
                .filter { !$0.hasPrefix("-----") }
                .joined()
        } else {
            base64Payload = text.filter { !$0.isWhitespace }
        }

        guard let decoded = Data(base64Encoded: base64Payload, options: [.ignoreUnknownCharacters]),
              SecCertificateCreateWithData(nil, decoded as CFData) != nil else {
            throw SampleError.invalidCertificate
        }
        return decoded
    }

    static func extractCKC(from data: Data) throws -> Data {
        if let wrapper = try? JSONDecoder().decode(CKCWrapper.self, from: data),
           let decoded = Data(base64Encoded: wrapper.ckc) {
            return decoded
        }
        guard !data.isEmpty else {
            throw SampleError.invalidCKC
        }
        return data
    }

    private static func validate(response: URLResponse, operation: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SampleError.httpFailure(operation: operation, statusCode: httpResponse.statusCode)
        }
    }

    private struct CKCWrapper: Decodable {
        let ckc: String
    }
}
