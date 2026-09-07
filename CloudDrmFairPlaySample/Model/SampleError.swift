import Foundation

enum SampleError: LocalizedError {
    case invalidURL(String)
    case invalidBrandGuid
    case missingToken
    case invalidPlaylist
    case fairPlayKeyNotFound
    case invalidKeyIdentifier
    case invalidCertificate
    case invalidCKC
    case httpFailure(operation: String, statusCode: Int)
    case contentKeyRequestFailed
    case downloadAlreadyExists
    case downloadInProgress
    case downloadTaskCreationFailed
    case persistentKeyCreationFailed
    case downloadedAssetMissing
    case persistentKeyMissing

    var errorDescription: String? {
        switch self {
        case .invalidURL(let field):
            return "Enter a valid HTTP or HTTPS URL for \(field)."
        case .invalidBrandGuid:
            return "Brand GUID must be a valid UUID."
        case .missingToken:
            return "User Token is required."
        case .invalidPlaylist:
            return "The HLS playlist is empty or is not valid UTF-8."
        case .fairPlayKeyNotFound:
            return "No FairPlay skd:// key URI was found in the HLS playlist."
        case .invalidKeyIdentifier:
            return "AVFoundation returned an invalid FairPlay key identifier."
        case .invalidCertificate:
            return "The certificate response is not a valid DER, base64, or PEM certificate."
        case .invalidCKC:
            return "The license response does not contain valid CKC data."
        case .httpFailure(let operation, let statusCode):
            return "\(operation) failed with HTTP \(statusCode)."
        case .contentKeyRequestFailed:
            return "AVFoundation could not create the FairPlay content key request."
        case .downloadAlreadyExists:
            return "This HLS asset has already been downloaded."
        case .downloadInProgress:
            return "Another download is already in progress."
        case .downloadTaskCreationFailed:
            return "AVFoundation could not create the HLS download task."
        case .persistentKeyCreationFailed:
            return "AVFoundation could not create the persistent FairPlay key."
        case .downloadedAssetMissing:
            return "The downloaded HLS package is missing."
        case .persistentKeyMissing:
            return "The persistent FairPlay key is missing."
        }
    }
}
