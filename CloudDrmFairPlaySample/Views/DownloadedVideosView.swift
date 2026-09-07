import SwiftUI

struct DownloadedVideosView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var downloadManager: FairPlayDownloadManager
    @State private var playerRequest: PlayerRequest?
    @State private var assetToDelete: DownloadedAsset?

    var body: some View {
        NavigationStack {
            Group {
                if downloadManager.records.isEmpty {
                    ContentUnavailableView("No downloaded videos", systemImage: "tray")
                } else {
                    List(downloadManager.records) { asset in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(asset.displayName)
                                    .font(.headline)
                                    .lineLimit(2)
                                Text(asset.downloadedAt, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                playerRequest = PlayerRequest(source: .offline(asset))
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Play \(asset.displayName)")

                            Button(role: .destructive) {
                                assetToDelete = asset
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete \(asset.displayName)")
                        }
                        .padding(.vertical, 5)
                    }
                }
            }
            .navigationTitle("Downloaded Videos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .fullScreenCover(item: $playerRequest) { request in
            PlayerView(request: request)
        }
        .confirmationDialog(
            "Delete downloaded video?",
            isPresented: Binding(
                get: { assetToDelete != nil },
                set: { if !$0 { assetToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let assetToDelete {
                    downloadManager.delete(assetToDelete)
                }
                assetToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                assetToDelete = nil
            }
        }
    }
}
