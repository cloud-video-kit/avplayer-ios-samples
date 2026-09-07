import Foundation

struct DownloadedAsset: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let sourceHLSURL: String
    let localAssetPath: String
    let persistentKeyPath: String
    let fairPlayKeyIdentifier: String
    let downloadedAt: Date

    var localAssetURL: URL {
        URL(fileURLWithPath: localAssetPath)
    }

    var persistentKeyURL: URL {
        URL(fileURLWithPath: persistentKeyPath)
    }
}
