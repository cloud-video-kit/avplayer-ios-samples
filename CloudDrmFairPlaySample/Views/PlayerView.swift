import AVFoundation
import AVKit
import SwiftUI

struct PlayerRequest: Identifiable {
    enum Source {
        case online(FairPlayConfiguration, prefetch: Bool)
        case offline(DownloadedAsset)
    }

    let id = UUID()
    let source: Source
}

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: PlayerViewModel

    init(request: PlayerRequest) {
        _model = StateObject(wrappedValue: PlayerViewModel(request: request))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VideoPlayer(player: model.player)
                    .ignoresSafeArea(edges: .bottom)

                if model.isPreparing {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        Text(model.status)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                    }
                }
            }
            .navigationTitle("Cloud DRM FairPlay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .alert("Playback Error", isPresented: $model.showsError) {
                Button("Close") { dismiss() }
            } message: {
                Text(model.errorMessage)
            }
        }
        .task {
            await model.prepare()
        }
        .onDisappear {
            model.stop()
        }
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var status = "Preparing"
    @Published private(set) var isPreparing = true
    @Published var showsError = false
    @Published private(set) var errorMessage = ""

    private let request: PlayerRequest
    private var fairPlaySession: FairPlaySession?
    private var offlineSession: OfflineFairPlaySession?
    private var itemStatusObservation: NSKeyValueObservation?
    private var didPrepare = false

    init(request: PlayerRequest) {
        self.request = request
    }

    func prepare() async {
        guard !didPrepare else { return }
        didPrepare = true

        do {
            switch request.source {
            case .online(let configuration, let prefetch):
                let session = FairPlaySession(configuration: configuration)
                fairPlaySession = session

                if prefetch {
                    // PREFETCH AND PLAY: acquire the license first, then show the
                    // player paused ("Ready") so the user starts an already-licensed item.
                    status = "Prefetching license"
                    let item = try await session.makePrefetchedPlayerItem()
                    setPlayerItem(item, autoplay: false)
                    status = "Ready"
                    isPreparing = false
                } else {
                    // PLAY: start immediately; the license is fetched on demand while
                    // the player loads.
                    let item = session.makeStreamingPlayerItem()
                    setPlayerItem(item, autoplay: true)
                    isPreparing = false
                    status = "Playing"
                }

            case .offline(let asset):
                // Offline: decrypt with the stored persistent key, no network needed.
                status = "Opening download"
                let session = try OfflineFairPlaySession(downloadedAsset: asset)
                offlineSession = session
                setPlayerItem(session.makePlayerItem(), autoplay: true)
                isPreparing = false
                status = "Playing offline"
            }
        } catch {
            errorMessage = error.localizedDescription
            isPreparing = false
            showsError = true
        }
    }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        itemStatusObservation = nil
        fairPlaySession = nil
        offlineSession = nil
    }

    private func setPlayerItem(_ item: AVPlayerItem, autoplay: Bool) {
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "AVPlayer could not prepare this HLS asset."
            Task { @MainActor [weak self] in
                self?.errorMessage = message
                self?.isPreparing = false
                self?.showsError = true
            }
        }

        let nextPlayer = AVPlayer(playerItem: item)
        player = nextPlayer
        if autoplay {
            nextPlayer.play()
        }
    }
}
