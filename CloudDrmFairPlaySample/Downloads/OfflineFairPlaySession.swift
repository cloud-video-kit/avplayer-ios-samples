import AVFoundation
import Foundation
import OSLog

/// Plays a downloaded asset offline.
///
/// Same `AVContentKeySession` delegate pattern as online playback, but instead of
/// running the certificate/SPC/CKC handshake it answers the key request with the
/// persistent key saved during download – so playback works with no network.
final class OfflineFairPlaySession: NSObject, AVContentKeySessionDelegate, @unchecked Sendable {
    private let asset: AVURLAsset
    private let persistentKeyData: Data
    private let contentKeySession = AVContentKeySession(keySystem: .fairPlayStreaming)
    private let logger = Logger(subsystem: "com.insys.CloudDrmFairPlaySample", category: "OfflinePlayback")

    init(downloadedAsset: DownloadedAsset) throws {
        guard FileManager.default.fileExists(atPath: downloadedAsset.localAssetPath) else {
            throw SampleError.downloadedAssetMissing
        }
        guard FileManager.default.fileExists(atPath: downloadedAsset.persistentKeyPath) else {
            throw SampleError.persistentKeyMissing
        }

        asset = AVURLAsset(url: downloadedAsset.localAssetURL)
        persistentKeyData = try Data(contentsOf: downloadedAsset.persistentKeyURL)
        super.init()
        contentKeySession.setDelegate(self, queue: .global(qos: .userInitiated))
        contentKeySession.addContentKeyRecipient(asset)
    }

    func makePlayerItem() -> AVPlayerItem {
        AVPlayerItem(asset: asset)
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        do {
            try keyRequest.respondByRequestingPersistableContentKeyRequestAndReturnError()
        } catch {
            keyRequest.processContentKeyResponseError(error)
            logger.error("Offline key request failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        didProvide keyRequest: AVPersistableContentKeyRequest
    ) {
        keyRequest.processContentKeyResponse(
            AVContentKeyResponse(fairPlayStreamingKeyResponseData: persistentKeyData)
        )
        logger.info("Persistent FairPlay key applied")
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        contentKeyRequest keyRequest: AVContentKeyRequest,
        didFailWithError error: Error
    ) {
        logger.error("Offline FairPlay session failed: \(error.localizedDescription, privacy: .public)")
    }
}
