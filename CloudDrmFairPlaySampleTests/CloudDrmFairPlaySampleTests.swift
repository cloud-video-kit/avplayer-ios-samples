import Foundation
import XCTest
@testable import CloudDrmFairPlaySample

final class CloudDrmFairPlaySampleTests: XCTestCase {
    func testConfigurationRejectsInvalidBrandGuid() {
        XCTAssertThrowsError(
            try FairPlayConfiguration(
                hlsURL: "https://example.com/master.m3u8",
                certificateURL: "https://drm.example.com/certificate",
                licenseURL: "https://drm.example.com/license",
                brandGuid: "not-a-guid",
                userToken: "token"
            )
        )
    }

    func testLicenseURLKeepsHostAndRebuildsQuery() throws {
        let configuration = try makeConfiguration()
        let result = configuration.licenseRequestURL(
            for: "skd://manifest.example.com/key?KID=abc&IV=def&brandGuid=ignored"
        )
        let components = try XCTUnwrap(URLComponents(url: result, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        // Host/path come from the configured License URL.
        XCTAssertEqual(components.host, "drm.example.com")
        XCTAssertEqual(components.path, "/license")
        // KID/IV are copied from the stream identifier.
        XCTAssertEqual(items["KID"], "abc")
        XCTAssertEqual(items["IV"], "def")
        // brandGuid comes from the configured field, never from the skd:// URL.
        XCTAssertEqual(items["brandGuid"], "11111111-2222-3333-4444-555555555555")
        // Any other pasted parameter is dropped.
        XCTAssertNil(items["existing"])
        XCTAssertNil(items["usertoken"])
    }

    func testLicenseURLDropsPastedUsertoken() throws {
        let configuration = try FairPlayConfiguration(
            hlsURL: "https://example.com/master.m3u8",
            certificateURL: "https://drm.example.com/certificate",
            licenseURL: "https://drm.example.com/license?brandGuid=abc&usertoken=STALE",
            brandGuid: "11111111-2222-3333-4444-555555555555",
            userToken: "token"
        )
        let result = configuration.licenseRequestURL(for: "skd://manifest.example.com/key?KID=abc&IV=def")
        let components = try XCTUnwrap(URLComponents(url: result, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        XCTAssertNil(items["usertoken"])
        XCTAssertEqual(items["brandGuid"], "11111111-2222-3333-4444-555555555555")
    }

    func testResolverExtractsMediaPlaylistKey() {
        let playlist = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://license.example.com/key?KID=123"
        #EXTINF:6,
        segment.ts
        """

        XCTAssertEqual(
            HLSKeyURIResolver.extractFairPlayKeyURI(from: playlist),
            "skd://license.example.com/key?KID=123"
        )
    }

    func testResolverExtractsSessionKey() {
        let playlist = """
        #EXTM3U
        #EXT-X-SESSION-KEY:METHOD=SAMPLE-AES,URI="skd://license.example.com/key"
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        media.m3u8
        """

        XCTAssertEqual(
            HLSKeyURIResolver.extractFairPlayKeyURI(from: playlist),
            "skd://license.example.com/key"
        )
    }

    func testResolverResolvesRelativeVariantURL() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://example.com/hls/master.m3u8"))
        let playlist = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        video/main.m3u8
        """

        XCTAssertEqual(
            HLSKeyURIResolver.firstVariantURL(in: playlist, relativeTo: baseURL)?.absoluteString,
            "https://example.com/hls/video/main.m3u8"
        )
    }

    func testCKCJSONWrapperIsDecoded() throws {
        let expected = Data([0x01, 0x02, 0x03])
        let response = try XCTUnwrap("{\"ckc\":\"\(expected.base64EncodedString())\"}".data(using: .utf8))

        XCTAssertEqual(try FairPlayLicenseClient.extractCKC(from: response), expected)
    }

    func testDownloadedAssetRoundTrip() throws {
        let asset = DownloadedAsset(
            id: UUID(),
            displayName: "video",
            sourceHLSURL: "https://example.com/master.m3u8",
            localAssetPath: "/tmp/video.movpkg",
            persistentKeyPath: "/tmp/video.key",
            fairPlayKeyIdentifier: "skd://example.com/key",
            downloadedAt: Date(timeIntervalSince1970: 1_000)
        )

        let data = try JSONEncoder().encode(asset)
        XCTAssertEqual(try JSONDecoder().decode(DownloadedAsset.self, from: data), asset)
    }

    private func makeConfiguration() throws -> FairPlayConfiguration {
        try FairPlayConfiguration(
            hlsURL: "https://example.com/master.m3u8",
            certificateURL: "https://drm.example.com/certificate",
            licenseURL: "https://drm.example.com/license?existing=1",
            brandGuid: "11111111-2222-3333-4444-555555555555",
            userToken: "token"
        )
    }
}
