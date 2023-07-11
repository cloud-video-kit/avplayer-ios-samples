//
//  PlayerViewController.swift
//  DRMPlaybackSwiftUI
//
//  Created by Insys on 22/06/2023.
//

import AVKit
import SwiftUI

class PlayerViewController: AVPlayerViewController, AVContentKeySessionDelegate {

    // URL for the video to be played
    let videoUrl: String = "https://dtkya1w875897.cloudfront.net/da6dc30a-e52f-4af2-9751-000b89416a4e/assets/357577a1-3b61-43ae-9af5-82b9727e2f22/videokit-720p-dash-hls-drm/hls/index.m3u8"
    
    // URL for the FairPlay Streaming certificate
    let fpsCertificateUrl: String = "https://insys-marketing.la.drm.cloud/certificate/fairplay?BrandGuid=da6dc30a-e52f-4af2-9751-000b89416a4e"
    
    // VideoKit TenantId 
    let brandGuid = "da6dc30a-e52f-4af2-9751-000b89416a4e"
    
    // DRM token
    let userToken = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE4OTM0NTYwMDAsImRybVRva2VuSW5mbyI6eyJleHAiOiIyMDMwLTAxLTAxVDAwOjAwOjAwKzAwOjAwIiwia2lkIjpbImM3OTYyNTYyLTE1MTctNDRjMi04OTM3LWExZjJjNmI4NDlmYyJdLCJwIjp7InBlcnMiOmZhbHNlfX19.Yp17bc9YEbicVxffOoFJ-OW3BMtD-5yRTrf0QcHPOns"
    
    // AVContentKeySession for handling content key requests
    var contentKeySession: AVContentKeySession!
    
    // URLSession for network requests
    let urlSession = URLSession(configuration: .default)
 
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Create Content Key Session.
        setupContentKeySession()
        
        // Prepare and play the video.
        prepareAndPlay()
    }

    // Set up the AVContentKeySession for handling content key requests
    private func setupContentKeySession() {
        // Create the Content Key Session using the FairPlay Streaming key system.
        contentKeySession = AVContentKeySession(keySystem: .fairPlayStreaming)
        
        /*
        Set PlayerViewController as the delegate of the Content Key Session.
        The delegate methods will be called when the session needs to handle key requests.
        Use a dedicated queue for delegate callbacks.
        */
        contentKeySession.setDelegate(self, queue: DispatchQueue(label: "\(Bundle.main.bundleIdentifier!).ContentKeyDelegateQueue"))
    }

    // Create the Content Key Session using the FairPlay Streaming key system
    private func prepareAndPlay() {
        // Create a URL instance from the video URL string.
        guard let assetUrl = URL(string: self.videoUrl) else {
            return
        }
        
        /*
        Initialize an AVURLAsset with the asset URL.
        AVURLAsset represents the media resource that will be played.
        */
        let asset = AVURLAsset(url: assetUrl)
        
        /*
        Associate the AVURLAsset with the Content Key Session.
        The Content Key Session will handle key requests for this asset.
        */
        contentKeySession.addContentKeyRecipient(asset)
        
        /*
        Initialize an AVPlayerItem with the AVURLAsset.
        AVPlayerItem represents a single media item that can be played by AVPlayer.
        */
        let playerItem = AVPlayerItem(asset: asset)
        
        /*
        Initialize an AVPlayer with the AVPlayerItem.
        AVPlayer handles the playback of the media content.
        */
        let player = AVPlayer(playerItem: playerItem)
        
        /*
        Set the AVPlayer instance as a reference to the PlayerViewController.
        The PlayerViewController will manage the display and control of the player.
        */
        self.player = player
        
        // Start playback.
        player.play()
    }

    /*
     This delegate callback is called when the client initiates a key request.
     It is also triggered when AVFoundation determines that the content is encrypted based on the playlist provided by the client during playback request.
    */
    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        // Extract content identifier and license service URL from the key request
        guard let contentKeyIdentifierString = keyRequest.identifier as? String,
            let contentIdentifier = contentKeyIdentifierString.replacingOccurrences(of: "skd://", with: "") as String?,
            let licenseServiceUrl = contentKeyIdentifierString.replacingOccurrences(of: "skd://", with: "https://") as String?,
            let contentIdentifierData = contentIdentifier.data(using: .utf8)
        else {
            print("ERROR: Failed to retrieve the content identifier from the key request!")
            return
        }
        
        // Completion handler for making streaming content key request
        let handleCkcAndMakeContentAvailable = { [weak self] (spcData: Data?, error: Error?) in
            guard let strongSelf = self else { return }
            
            if let error = error {
                print("ERROR: Failed to prepare SPC: \(error.localizedDescription)")
                // Report SPC preparation error to AVFoundation
                keyRequest.processContentKeyResponseError(error)
                return
            }
            
            guard let spcData = spcData else { return }
            
            // Send SPC to the license service to obtain CKC
            guard let url = URL(string: licenseServiceUrl) else {
                print("ERROR: Missing license service URL!")
                return
            }
            
            var licenseRequest = URLRequest(url: url)
            licenseRequest.httpMethod = "POST"

            // Set additional headers for the license service request
            licenseRequest.setValue(strongSelf.brandGuid, forHTTPHeaderField: "x-drm-brandGuid")
            licenseRequest.setValue(strongSelf.userToken, forHTTPHeaderField: "x-drm-usertoken")
            licenseRequest.httpBody = spcData
            
            var dataTask: URLSessionDataTask?
            
            dataTask = self!.urlSession.dataTask(with: licenseRequest, completionHandler: { (data, response, error) in
                defer {
                    dataTask = nil
                }
                
                if let error = error {
                    print("ERROR: Failed to get CKC: \(error.localizedDescription)")
                } else if
                    let ckcData = data,
                    let response = response as? HTTPURLResponse,
                    response.statusCode == 200 {
                    // Create AVContentKeyResponse from CKC data
                    let keyResponse = AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckcData)
                    // Provide the content key response to make protected content available for processing
                    keyRequest.processContentKeyResponse(keyResponse)
                }
            })
            
            dataTask?.resume()
        }
        
        do {
            // Request the application certificate for the content key request
            let applicationCertificate = try requestApplicationCertificate()
            
            // Make the streaming content key request with the specified options
            keyRequest.makeStreamingContentKeyRequestData(
                forApp: applicationCertificate,
                contentIdentifier: contentIdentifierData,
                options: [AVContentKeyRequestProtocolVersionsKey: [1]],
                completionHandler: handleCkcAndMakeContentAvailable
            )
        } catch {
            // Report error in processing content key response
            keyRequest.processContentKeyResponseError(error)
        }
    }
    
    /*
     Requests the Application Certificate.
    */
    func requestApplicationCertificate() throws -> Data {
        var applicationCertificate: Data? = nil
        
        do {
            // Load the FairPlay application certificate from the specified URL.
            applicationCertificate = try Data(contentsOf: URL(string: fpsCertificateUrl)!)
        } catch {
            // Handle any errors that occur while loading the certificate.
            let errorMessage = "Failed to load the FairPlay application certificate. Error: \(error)"
            print(errorMessage)
            throw error
        }
        
        // Return the loaded application certificate.
        return applicationCertificate!
    }
}

struct PlayerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        return PlayerViewController()
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}
