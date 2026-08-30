import XCTest
@testable import PhotoCaptureManager

final class PhotoCaptureManagerTests: XCTestCase {

    @MainActor
    func testSingletonInstance() {
        let instance1 = PhotoCaptureManager.shared
        let instance2 = PhotoCaptureManager.shared
        XCTAssertTrue(instance1 === instance2)
    }

    @MainActor
    func testDefaultConfiguration() {
        let config = PhotoCaptureConfiguration()
        XCTAssertTrue(config.promptForPhotoLibraryIfCameraDenied)
        XCTAssertEqual(config.actionTintColor, .systemBlue)
        XCTAssertFalse(config.allowsEditing)
        XCTAssertEqual(config.preferredCameraDevice, .rear)
        XCTAssertEqual(config.imageCompressionQuality, 0.9, accuracy: 0.001)
        XCTAssertEqual(config.strings.selectPhotoTitle, "Select Photo")
        XCTAssertEqual(config.strings.takePhotoAction, "Take Photo")
        XCTAssertEqual(config.strings.chooseFromLibraryAction, "Choose from Library")
    }

    @MainActor
    func testConfigurationMutation() {
        var config = PhotoCaptureConfiguration()
        config.allowsEditing = true
        config.preferredCameraDevice = .front
        config.imageCompressionQuality = 0.75
        config.strings.selectPhotoTitle = "Pick an Avatar"

        PhotoCaptureManager.shared.configuration = config

        XCTAssertTrue(PhotoCaptureManager.shared.configuration.allowsEditing)
        XCTAssertEqual(PhotoCaptureManager.shared.configuration.preferredCameraDevice, .front)
        XCTAssertEqual(PhotoCaptureManager.shared.configuration.imageCompressionQuality, 0.75, accuracy: 0.001)
        XCTAssertEqual(PhotoCaptureManager.shared.configuration.strings.selectPhotoTitle, "Pick an Avatar")
    }

    func testErrorDescriptions() {
        XCTAssertEqual(PhotoCaptureError.cameraUnavailable.errorDescription, "This device does not have a camera.")
        XCTAssertEqual(PhotoCaptureError.permissionDenied(source: .camera).errorDescription, "Camera access was denied.")
        XCTAssertEqual(PhotoCaptureError.permissionDenied(source: .photoLibrary).errorDescription, "Photo Library access was denied.")
        XCTAssertEqual(PhotoCaptureError.permissionRestricted.errorDescription, "Access to media is restricted on this device.")
        XCTAssertEqual(PhotoCaptureError.imageExtractionFailed.errorDescription, "Could not extract an image from the selected item.")
        XCTAssertEqual(PhotoCaptureError.requestAlreadyInProgress.errorDescription, "Another photo capture request is already in progress.")
        let sampleError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Corrupt data"])
        XCTAssertEqual(PhotoCaptureError.unknown(sampleError).errorDescription, "Corrupt data")
    }

    @MainActor
    func testJPEGDataUtility() {
        let size = CGSize(width: 10, height: 10)
        UIGraphicsBeginImageContext(size)
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()

        PhotoCaptureManager.shared.configuration.imageCompressionQuality = 0.8
        let data = PhotoCaptureManager.shared.jpegData(from: image)
        XCTAssertNotNil(data)
    }
}
