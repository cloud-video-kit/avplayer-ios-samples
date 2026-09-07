import SwiftUI

struct ContentView: View {
    @ObservedObject var downloadManager: FairPlayDownloadManager

    @State private var hlsURL = ""
    @State private var certificateURL = ""
    @State private var licenseURL = ""
    @State private var brandGuid = ""
    @State private var userToken = ""
    @State private var playerRequest: PlayerRequest?
    @State private var showsDownloads = false
    @State private var errorMessage = ""
    @State private var showsError = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Image("CloudDRMLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 230)
                        .padding(.vertical, 14)

                    inputField("HLS URL", text: $hlsURL, keyboard: .URL)
                    inputField("Certificate URL", text: $certificateURL, keyboard: .URL)

                    VStack(alignment: .leading, spacing: 4) {
                        inputField("License URL", text: $licenseURL, keyboard: .URL)
                        Text("Only the host/path and brandGuid are used. KID/IV are taken from the stream; any other query parameter (e.g. usertoken) is ignored.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    inputField("Brand GUID / Tenant ID", text: $brandGuid)
                    inputField("User Token", text: $userToken)

                    if downloadManager.isBusy || downloadManager.statusMessage != nil {
                        downloadStatus
                    }

                    actionButton("PLAY", systemImage: "play.fill") {
                        openPlayer(prefetch: false)
                    }
                    .disabled(downloadManager.isBusy)

                    actionButton("PREFETCH AND PLAY", systemImage: "bolt.fill") {
                        openPlayer(prefetch: true)
                    }
                    .disabled(downloadManager.isBusy)

                    actionButton(
                        downloadManager.isBusy ? "CANCEL" : "DOWNLOAD",
                        systemImage: downloadManager.isBusy ? "xmark" : "arrow.down.circle.fill"
                    ) {
                        handleDownloadButton()
                    }

                    Button {
                        showsDownloads = true
                    } label: {
                        Label("DOWNLOADED VIDEOS", systemImage: "tray.full.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(SampleActionButtonStyle(isPrimary: false))
                }
                .padding(20)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Cloud DRM FairPlay")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fullScreenCover(item: $playerRequest) { request in
            PlayerView(request: request)
        }
        .sheet(isPresented: $showsDownloads) {
            DownloadedVideosView(downloadManager: downloadManager)
        }
        .alert("Error", isPresented: $showsError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
        .onReceive(downloadManager.$lastError.compactMap { $0 }) { message in
            showError(message)
        }
    }

    private var downloadStatus: some View {
        VStack(spacing: 8) {
            Text(downloadManager.statusMessage ?? "")
                .font(.subheadline)
            if downloadManager.isBusy {
                ProgressView(value: downloadManager.progress)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    private func inputField(
        _ title: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        TextField(title, text: text, axis: .vertical)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(keyboard)
            .lineLimit(1...3)
            .textFieldStyle(.roundedBorder)
            .disabled(downloadManager.isBusy)
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(SampleActionButtonStyle(isPrimary: true))
    }

    private func openPlayer(prefetch: Bool) {
        do {
            let configuration = try makeConfiguration()
            playerRequest = PlayerRequest(source: .online(configuration, prefetch: prefetch))
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func handleDownloadButton() {
        if downloadManager.isBusy {
            downloadManager.cancelDownload()
            return
        }

        do {
            try downloadManager.startDownload(configuration: makeConfiguration())
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func makeConfiguration() throws -> FairPlayConfiguration {
        try FairPlayConfiguration(
            hlsURL: hlsURL,
            certificateURL: certificateURL,
            licenseURL: licenseURL,
            brandGuid: brandGuid,
            userToken: userToken
        )
    }

    private func showError(_ message: String) {
        errorMessage = message
        showsError = true
    }
}

private struct SampleActionButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isPrimary ? Color.white : Color.accentColor)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(isPrimary ? Color.accentColor : Color(.secondarySystemBackground))
            .overlay {
                if !isPrimary {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, lineWidth: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
