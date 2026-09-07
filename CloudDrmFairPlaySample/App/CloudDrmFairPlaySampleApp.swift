import SwiftUI

@main
struct CloudDrmFairPlaySampleApp: App {
    @StateObject private var downloadManager = FairPlayDownloadManager()

    var body: some Scene {
        WindowGroup {
            ContentView(downloadManager: downloadManager)
        }
    }
}
