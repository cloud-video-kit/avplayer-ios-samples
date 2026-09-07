import AVFoundation
import Foundation
import OSLog

/// Drives FairPlay Streaming for online playback (`PLAY` and `PREFETCH AND PLAY`).
///
/// FairPlay is handled through an `AVContentKeySession`. The asset is registered as
/// a "content key recipient"; whenever AVFoundation needs a content key it calls
/// this delegate, which runs the standard FairPlay handshake:
///
///     certificate  ->  SPC (Server Playback Context)  ->  CKC (Content Key Context)
///
/// The two entry points differ only in *when* the key is fetched:
/// - `makeStreamingPlayerItem()` – the key is requested lazily, the first time the
///   player needs it while loading (this is the normal AVPlayer behaviour).
/// - `makePrefetchedPlayerItem()` – the key is requested up front and awaited, so
///   the license is already in place before the player item is returned.
final class FairPlaySession: NSObject, AVContentKeySessionDelegate, @unchecked Sendable {
    private let configuration: FairPlayConfiguration
    private let licenseClient: FairPlayLicenseClient
    private let resolver: HLSKeyURIResolver
    private let contentKeySession = AVContentKeySession(keySystem: .fairPlayStreaming)
    private let logger = Logger(subsystem: "com.insys.CloudDrmFairPlaySample", category: "FairPlay")
    private let stateLock = NSLock()

    // Kept for the lifetime of the session so the player item plays the same asset
    // that was registered for content keys.
    private var asset: AVURLAsset?
    // Certificate fetched during prefetch, reused by the delegate to skip a second download.
    private var prefetchedCertificate: Data?
    // Lets the prefetch call suspend until the key handshake finishes.
    private var prefetchContinuation: CheckedContinuation<Void, Error>?
    private var prefetchFinished = false

    init(
        configuration: FairPlayConfiguration,
        licenseClient: FairPlayLicenseClient = FairPlayLicenseClient(),
        resolver: HLSKeyURIResolver = HLSKeyURIResolver()
    ) {
        self.configuration = configuration
        self.licenseClient = licenseClient
        self.resolver = resolver
        super.init()
        contentKeySession.setDelegate(self, queue: .global(qos: .userInitiated))
    }

    /// `PLAY`: build a player item and let AVFoundation ask for the key on demand.
    func makeStreamingPlayerItem() -> AVPlayerItem {
        logger.info("Preparing standard FairPlay playback")
        let nextAsset = AVURLAsset(url: configuration.hlsURL)
        // Registering the asset here is what makes AVFoundation route its key
        // requests to this session's delegate.
        contentKeySession.addContentKeyRecipient(nextAsset)
        asset = nextAsset
        return AVPlayerItem(asset: nextAsset)
    }

    /// `PREFETCH AND PLAY`: acquire the FairPlay key *before* returning the player item.
    func makePrefetchedPlayerItem() async throws -> AVPlayerItem {
        #if targetEnvironment(simulator)
        logger.warning("FairPlay playback requires a physical iOS device")
        #endif

        // Find the `skd://` key URI in the HLS playlist so we can ask for the key
        // ourselves instead of waiting for AVFoundation to reach it during playback.
        logger.info("Resolving HLS playlist")
        let keyURI = try await resolver.fairPlayKeyURI(from: configuration.hlsURL)

        logger.info("Fetching FairPlay certificate")
        let certificate = try await licenseClient.fetchCertificate(configuration: configuration)

        let nextAsset = AVURLAsset(url: configuration.hlsURL)
        contentKeySession.addContentKeyRecipient(nextAsset)
        asset = nextAsset

        stateLock.withLock {
            prefetchedCertificate = certificate
            prefetchFinished = false
        }

        // Kick off the key request explicitly and suspend until the delegate below
        // has processed the CKC. When this returns, the license is ready.
        logger.info("Requesting FairPlay key before playback")
        try await withCheckedThrowingContinuation { continuation in
            stateLock.withLock {
                prefetchContinuation = continuation
            }
            contentKeySession.processContentKeyRequest(
                withIdentifier: keyURI,
                initializationData: nil,
                options: nil
            )
        }

        logger.info("FairPlay prefetch completed")
        return AVPlayerItem(asset: nextAsset)
    }

    /// The FairPlay handshake, shared by both entry points. AVFoundation calls this
    /// whenever it needs a content key for the registered asset.
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        Task {
            do {
                // The identifier is the `skd://` URI; we need its raw form (for the
                // license request) and its bytes (for the SPC).
                let identifier = try FairPlayConfiguration.contentIdentifier(from: keyRequest.identifier)
                let certificate = try await certificateData()

                // SPC: the device's signed request for a key, bound to the certificate.
                logger.info("Generating SPC")
                let spcData = try await makeSPC(
                    for: keyRequest,
                    certificate: certificate,
                    contentIdentifier: identifier.data
                )

                // CKC: the license server's response containing the content key.
                logger.info("Requesting CKC")
                let ckcData = try await licenseClient.acquireLicense(
                    configuration: configuration,
                    keyIdentifier: identifier.raw,
                    spcData: spcData
                )

                // Hand the CKC back to AVFoundation to unlock playback.
                keyRequest.processContentKeyResponse(
                    AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckcData)
                )
                logger.info("FairPlay key ready")
                completePrefetch()
            } catch {
                keyRequest.processContentKeyResponseError(error)
                logger.error("FairPlay key request failed: \(error.localizedDescription, privacy: .public)")
                failPrefetch(with: error)
            }
        }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        contentKeyRequest keyRequest: AVContentKeyRequest,
        didFailWithError error: Error
    ) {
        logger.error("AVContentKeySession failed: \(error.localizedDescription, privacy: .public)")
        failPrefetch(with: error)
    }

    /// Reuse the certificate fetched during prefetch; otherwise fetch it now (PLAY path).
    private func certificateData() async throws -> Data {
        if let prefetched = stateLock.withLock({ prefetchedCertificate }) {
            return prefetched
        }
        logger.info("Fetching FairPlay certificate")
        return try await licenseClient.fetchCertificate(configuration: configuration)
    }

    /// Ask AVFoundation to build the SPC for this key request and the app certificate.
    private func makeSPC(
        for keyRequest: AVContentKeyRequest,
        certificate: Data,
        contentIdentifier: Data
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            keyRequest.makeStreamingContentKeyRequestData(
                forApp: certificate,
                contentIdentifier: contentIdentifier,
                options: [AVContentKeyRequestProtocolVersionsKey: [1]]
            ) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: SampleError.contentKeyRequestFailed)
                }
            }
        }
    }

    // Resume the prefetch waiter once. On the PLAY path there is no waiter, so these
    // are no-ops.
    private func completePrefetch() {
        stateLock.withLock {
            guard !prefetchFinished else { return }
            prefetchFinished = true
            prefetchContinuation?.resume()
            prefetchContinuation = nil
        }
    }

    private func failPrefetch(with error: Error) {
        stateLock.withLock {
            guard !prefetchFinished, let continuation = prefetchContinuation else { return }
            prefetchFinished = true
            prefetchContinuation = nil
            continuation.resume(throwing: error)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
