import AVFoundation
import Combine
import Foundation
import OSLog

/// Downloads a FairPlay-protected HLS asset for offline playback.
///
/// Two things happen in parallel while a download runs:
/// 1. `AVAssetDownloadURLSession` streams the HLS package to local storage.
/// 2. `AVContentKeySession` asks for a key. Instead of a normal (streaming) key we
///    request a *persistable* key, turn the CKC into a persistent key, and save it
///    to disk so the asset can be decrypted later with no network.
///
/// A record is only written once both the package and the persistent key are ready.
/// A single download runs at a time; failure or cancellation cleans up partial files.
final class FairPlayDownloadManager: NSObject, ObservableObject, AVAssetDownloadDelegate, AVContentKeySessionDelegate, @unchecked Sendable {
    @Published private(set) var records: [DownloadedAsset]
    @Published private(set) var progress = 0.0
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastError: String?

    private final class DownloadContext {
        let id: UUID
        let configuration: FairPlayConfiguration
        let displayName: String
        let keySession: AVContentKeySession
        let task: AVAssetDownloadTask
        var localAssetPath: String?
        var persistentKeyPath: String?
        var keyIdentifier: String?
        var downloadFinished = false
        var reported = false

        init(
            id: UUID,
            configuration: FairPlayConfiguration,
            displayName: String,
            keySession: AVContentKeySession,
            task: AVAssetDownloadTask
        ) {
            self.id = id
            self.configuration = configuration
            self.displayName = displayName
            self.keySession = keySession
            self.task = task
        }
    }

    private let logger = Logger(subsystem: "com.insys.CloudDrmFairPlaySample", category: "Download")
    private let licenseClient = FairPlayLicenseClient()
    private let fileManager = FileManager.default
    private let contextLock = NSLock()
    private var activeContext: DownloadContext?
    private var downloadSession: AVAssetDownloadURLSession!

    override init() {
        records = Self.loadRecords(fileManager: .default)
        super.init()

        let bundleID = Bundle.main.bundleIdentifier ?? "com.insys.CloudDrmFairPlaySample"
        let configuration = URLSessionConfiguration.background(withIdentifier: "\(bundleID).downloads")
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        downloadSession = AVAssetDownloadURLSession(
            configuration: configuration,
            assetDownloadDelegate: self,
            delegateQueue: nil
        )
    }

    func startDownload(configuration: FairPlayConfiguration) throws {
        guard contextLock.withLock({ activeContext == nil }) else {
            throw SampleError.downloadInProgress
        }
        guard !records.contains(where: { $0.sourceHLSURL == configuration.hlsURL.absoluteString }) else {
            throw SampleError.downloadAlreadyExists
        }

        let id = UUID()
        let displayName = Self.displayName(for: configuration.hlsURL)
        let asset = AVURLAsset(url: configuration.hlsURL)
        let keySession = AVContentKeySession(keySystem: .fairPlayStreaming)
        keySession.setDelegate(self, queue: .global(qos: .userInitiated))
        keySession.addContentKeyRecipient(asset)

        guard let task = downloadSession.makeAssetDownloadTask(
            asset: asset,
            assetTitle: displayName,
            assetArtworkData: nil,
            options: nil
        ) else {
            throw SampleError.downloadTaskCreationFailed
        }

        task.taskDescription = id.uuidString
        let context = DownloadContext(
            id: id,
            configuration: configuration,
            displayName: displayName,
            keySession: keySession,
            task: task
        )
        contextLock.withLock {
            activeContext = context
        }

        progress = 0
        lastError = nil
        statusMessage = "Preparing download"
        isBusy = true
        logger.info("Starting HLS download")
        task.resume()
    }

    func cancelDownload() {
        guard let context = contextLock.withLock({ activeContext }) else { return }
        context.task.cancel()
        cleanUp(context: context)
        contextLock.withLock {
            if activeContext?.id == context.id {
                activeContext = nil
            }
        }
        progress = 0
        isBusy = false
        statusMessage = "Download cancelled"
        logger.info("HLS download cancelled")
    }

    func delete(_ asset: DownloadedAsset) {
        try? fileManager.removeItem(at: asset.localAssetURL)
        try? fileManager.removeItem(at: asset.persistentKeyURL)
        records.removeAll { $0.id == asset.id }
        persistRecords()
        logger.info("Downloaded asset deleted")
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        do {
            // For downloads we don't want a one-off streaming key. Upgrading the
            // request re-delivers it below as an AVPersistableContentKeyRequest.
            logger.info("Requesting persistable FairPlay key")
            try keyRequest.respondByRequestingPersistableContentKeyRequestAndReturnError()
        } catch {
            keyRequest.processContentKeyResponseError(error)
            failDownload(for: session, error: error)
        }
    }

    // Same certificate -> SPC -> CKC handshake as streaming, but the CKC is turned
    // into a persistent key and written to disk instead of being used once.
    func contentKeySession(
        _ session: AVContentKeySession,
        didProvide keyRequest: AVPersistableContentKeyRequest
    ) {
        guard let context = context(for: session) else {
            keyRequest.processContentKeyResponseError(SampleError.downloadTaskCreationFailed)
            return
        }

        Task {
            do {
                let identifier = try FairPlayConfiguration.contentIdentifier(from: keyRequest.identifier)
                logger.info("Fetching FairPlay certificate for download")
                let certificate = try await licenseClient.fetchCertificate(configuration: context.configuration)
                logger.info("Certificate for download: \(certificate.count) bytes")

                logger.info("Generating SPC for persistent key")
                let spcData = try await makeSPC(
                    for: keyRequest,
                    certificate: certificate,
                    contentIdentifier: identifier.data
                )
                logger.info("Persistent SPC generated: \(spcData.count) bytes")

                // Playback and downloads build the license URL the same way:
                // configured host/path + brandGuid + KID/IV (see licenseRequestURL).
                let licenseURL = context.configuration.licenseRequestURL(for: identifier.raw)
                logger.info("Requesting persistent CKC from \(licenseURL.absoluteString, privacy: .public)")
                let ckcData = try await licenseClient.acquireLicense(
                    licenseURL: licenseURL,
                    configuration: context.configuration,
                    spcData: spcData
                )
                logger.info("Persistent CKC received: \(ckcData.count) bytes")

                // Turn the CKC into a key that can be stored and reused offline.
                // Requires the license to permit persistence (an offline/persistent token).
                let persistentKey: Data
                do {
                    persistentKey = try keyRequest.persistableContentKey(
                        fromKeyVendorResponse: ckcData,
                        options: nil
                    )
                } catch {
                    logger.error("persistableContentKey failed: \(Self.describe(error), privacy: .public)")
                    throw error
                }
                guard !persistentKey.isEmpty else {
                    throw SampleError.persistentKeyCreationFailed
                }
                logger.info("Persistent key created: \(persistentKey.count) bytes")

                let keyURL = try persistentKeyURL(for: context.id)
                try persistentKey.write(to: keyURL, options: .atomic)
                let isStillActive = contextLock.withLock {
                    guard activeContext?.id == context.id else { return false }
                    activeContext?.persistentKeyPath = keyURL.path
                    activeContext?.keyIdentifier = identifier.raw
                    return true
                }
                guard isStillActive else {
                    try? fileManager.removeItem(at: keyURL)
                    return
                }

                keyRequest.processContentKeyResponse(
                    AVContentKeyResponse(fairPlayStreamingKeyResponseData: persistentKey)
                )
                updateStatus("Persistent key stored")
                logger.info("Persistent FairPlay key stored")
                finishDownloadIfReady(id: context.id)
            } catch {
                logger.error("Persistent key flow failed: \(Self.describe(error), privacy: .public)")
                keyRequest.processContentKeyResponseError(error)
                failDownload(for: session, error: error)
            }
        }
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        contentKeyRequest keyRequest: AVContentKeyRequest,
        didFailWithError error: Error
    ) {
        failDownload(for: session, error: error)
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        guard let context = context(for: assetDownloadTask) else { return }
        contextLock.withLock {
            guard activeContext?.id == context.id else { return }
            activeContext?.localAssetPath = location.path
        }
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let context = context(for: assetDownloadTask) else { return }
        contextLock.withLock {
            guard activeContext?.id == context.id else { return }
            activeContext?.localAssetPath = location.path
        }
        logger.info("HLS package downloaded")
    }

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        let expected = timeRangeExpectedToLoad.duration.seconds
        guard expected.isFinite, expected > 0 else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        let nextProgress = min(max(loaded / expected, 0), 1)

        DispatchQueue.main.async { [weak self] in
            self?.progress = nextProgress
            self?.statusMessage = "Downloading \(Int(nextProgress * 100))%"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            logger.error("AVAssetDownloadTask finished with error: \(Self.describe(error), privacy: .public)")
        }
        guard let context = context(for: task) else { return }
        if let error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                return
            }
            failDownload(context: context, error: error)
            return
        }

        contextLock.withLock {
            guard activeContext?.id == context.id else { return }
            activeContext?.downloadFinished = true
        }
        finishDownloadIfReady(id: context.id)
    }

    private func makeSPC(
        for keyRequest: AVPersistableContentKeyRequest,
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

    private func finishDownloadIfReady(id: UUID) {
        let completed: DownloadedAsset? = contextLock.withLock {
            guard let context = activeContext,
                  context.id == id,
                  context.downloadFinished,
                  let localAssetPath = context.localAssetPath,
                  let persistentKeyPath = context.persistentKeyPath,
                  let keyIdentifier = context.keyIdentifier else {
                return nil
            }

            let record = DownloadedAsset(
                id: context.id,
                displayName: context.displayName,
                sourceHLSURL: context.configuration.hlsURL.absoluteString,
                localAssetPath: localAssetPath,
                persistentKeyPath: persistentKeyPath,
                fairPlayKeyIdentifier: keyIdentifier,
                downloadedAt: Date()
            )
            activeContext = nil
            return record
        }

        guard let completed else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            records.append(completed)
            records.sort { $0.downloadedAt > $1.downloadedAt }
            persistRecords()
            progress = 1
            isBusy = false
            statusMessage = "Download completed"
        }
    }

    private func context(for session: AVContentKeySession) -> DownloadContext? {
        contextLock.withLock {
            guard let context = activeContext, context.keySession === session else { return nil }
            return context
        }
    }

    private func context(for task: URLSessionTask) -> DownloadContext? {
        contextLock.withLock {
            guard let context = activeContext,
                  context.task.taskIdentifier == task.taskIdentifier else { return nil }
            return context
        }
    }

    private func failDownload(for session: AVContentKeySession, error: Error) {
        guard let context = context(for: session) else { return }
        failDownload(context: context, error: error)
    }

    private func failDownload(context: DownloadContext, error: Error) {
        // The key-request callback and the download task can both report a failure
        // for the same context; only act on the first one.
        let shouldReport = contextLock.withLock { () -> Bool in
            guard !context.reported else { return false }
            context.reported = true
            return true
        }
        guard shouldReport else { return }

        context.task.cancel()
        cleanUp(context: context)
        contextLock.withLock {
            if activeContext?.id == context.id {
                activeContext = nil
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.progress = 0
            self?.isBusy = false
            self?.statusMessage = "Download failed"
            self?.lastError = error.localizedDescription
        }
        logger.error("Download failed: \(Self.describe(error), privacy: .public)")
    }

    /// Compact description of an error, including the real domain/code and any
    /// underlying error, so console logs pinpoint the actual failure instead of a
    /// generic "The operation could not be completed".
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var parts = ["\(ns.domain) code=\(ns.code)"]
        if let reason = ns.localizedFailureReason {
            parts.append("reason=\(reason)")
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=\(underlying.domain) code=\(underlying.code)")
        }
        parts.append("desc=\(ns.localizedDescription)")
        return parts.joined(separator: " | ")
    }

    private func cleanUp(context: DownloadContext) {
        if let path = context.localAssetPath {
            try? fileManager.removeItem(atPath: path)
        }
        if let path = context.persistentKeyPath {
            try? fileManager.removeItem(atPath: path)
        }
    }

    private func updateStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = message
        }
    }

    private func persistentKeyURL(for id: UUID) throws -> URL {
        let directory = Self.applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("FairPlayKeys", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(id.uuidString).key")
    }

    private func persistRecords() {
        do {
            let directory = Self.applicationSupportDirectory(fileManager: fileManager)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: Self.recordsURL(fileManager: fileManager), options: .atomic)
        } catch {
            lastError = "Could not save downloaded asset metadata: \(error.localizedDescription)"
        }
    }

    private static func loadRecords(fileManager: FileManager) -> [DownloadedAsset] {
        let url = recordsURL(fileManager: fileManager)
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([DownloadedAsset].self, from: data) else { return [] }
        return decoded
            .filter {
                fileManager.fileExists(atPath: $0.localAssetPath) &&
                    fileManager.fileExists(atPath: $0.persistentKeyPath)
            }
            .sorted { $0.downloadedAt > $1.downloadedAt }
    }

    private static func recordsURL(fileManager: FileManager) -> URL {
        applicationSupportDirectory(fileManager: fileManager)
            .appendingPathComponent("downloaded-assets.json")
    }

    private static func applicationSupportDirectory(fileManager: FileManager) -> URL {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return root.appendingPathComponent("CloudDrmFairPlaySample", isDirectory: true)
    }

    private static func displayName(for url: URL) -> String {
        let fileName = url.deletingPathExtension().lastPathComponent
        if !fileName.isEmpty, fileName.lowercased() != "master" {
            return fileName
        }
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? "Downloaded video" : parent
    }
}
