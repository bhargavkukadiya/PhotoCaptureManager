import XCTest
import AVFoundation
import PhotosUI
@testable import PhotoCaptureManager

final class PhotoCaptureManagerTests: XCTestCase {

    // MARK: - Configuration

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
        defer { PhotoCaptureManager.shared.configuration = PhotoCaptureConfiguration() }

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
        XCTAssertEqual(PhotoCaptureError.presentationFailed.errorDescription, "The photo picker could not be presented.")
        let sampleError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Corrupt data"])
        XCTAssertEqual(PhotoCaptureError.unknown(sampleError).errorDescription, "Corrupt data")
    }

    @MainActor
    func testJPEGDataUtility() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }

        let manager = PhotoCaptureManager(environment: FakeEnvironment().environment)
        manager.configuration.imageCompressionQuality = 0.8
        XCTAssertNotNil(manager.jpegData(from: image))
    }

    // MARK: - Request Lifecycle

    @MainActor
    func testPhotoOptionsSheetOmitsCameraWhenUnavailable() {
        let fake = FakeEnvironment()
        let manager = PhotoCaptureManager(environment: fake.environment)

        manager.presentPhotoOptions(from: UIViewController()) { _ in }

        let sheet = fake.presented.first as? UIAlertController
        XCTAssertEqual(sheet?.preferredStyle, .actionSheet)
        XCTAssertEqual(sheet?.actions.map(\.title), ["Choose from Library", "Cancel"])
    }

    @MainActor
    func testPhotoOptionsSheetOffersCameraWhenAvailable() {
        let fake = FakeEnvironment()
        fake.cameraAvailable = true
        let manager = PhotoCaptureManager(environment: fake.environment)

        manager.presentPhotoOptions(from: UIViewController()) { _ in }

        let sheet = fake.presented.first as? UIAlertController
        XCTAssertEqual(sheet?.actions.map(\.title), ["Take Photo", "Choose from Library", "Cancel"])
    }

    @MainActor
    func testSecondRequestIsRejectedWhileFirstIsActive() {
        let fake = FakeEnvironment()
        let manager = PhotoCaptureManager(environment: fake.environment)
        var first: [PhotoCaptureResult] = []
        var second: [PhotoCaptureResult] = []

        manager.pickPhoto(from: UIViewController()) { first.append($0) }
        manager.pickPhoto(from: UIViewController()) { second.append($0) }

        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second.count, 1)
        guard case .failure(.requestAlreadyInProgress) = second.first else {
            return XCTFail("Expected .requestAlreadyInProgress, got \(second)")
        }
        XCTAssertEqual(fake.presented.count, 1)
    }

    @MainActor
    func testFailedPresentationFinishesRequestAndFreesManager() {
        let fake = FakeEnvironment()
        fake.presentationSucceeds = false
        let manager = PhotoCaptureManager(environment: fake.environment)
        var results: [PhotoCaptureResult] = []

        manager.pickPhoto(from: UIViewController()) { results.append($0) }

        guard case .failure(.presentationFailed) = results.first else {
            return XCTFail("Expected .presentationFailed, got \(results)")
        }

        fake.presentationSucceeds = true
        manager.pickPhoto(from: UIViewController()) { results.append($0) }

        XCTAssertEqual(results.count, 1, "The second request should be accepted and still pending")
        XCTAssertEqual(fake.presented.count, 1)
    }

    @MainActor
    func testLivePresentationFailsWhenPresenterIsNotInWindow() {
        XCTAssertFalse(PhotoCaptureEnvironment.live.present(UIViewController(), UIViewController()) {})
    }

    @MainActor
    func testDeferredPresentationKeepsRequestActive() {
        let fake = FakeEnvironment()
        fake.completesPresentationsImmediately = false
        let manager = PhotoCaptureManager(environment: fake.environment)
        var results: [PhotoCaptureResult] = []

        manager.pickPhoto(from: UIViewController()) { results.append($0) }
        XCTAssertTrue(results.isEmpty, "A picker that hasn't appeared yet is not a failure")

        fake.completePresentations()
        guard let picker = fake.presented.first as? PHPickerViewController else {
            return XCTFail("Expected a PHPickerViewController, got \(fake.presented)")
        }
        manager.picker(picker, didFinishPicking: [])

        guard case .cancelled = results.first else {
            return XCTFail("Expected .cancelled, got \(results)")
        }
    }

    @MainActor
    func testDeniedCameraOffersLibraryFallback() {
        let fake = FakeEnvironment()
        fake.cameraStatus = .denied
        let manager = PhotoCaptureManager(environment: fake.environment)

        manager.capturePhoto(from: UIViewController()) { _ in }

        let alert = fake.presented.first as? UIAlertController
        XCTAssertEqual(alert?.title, "Camera Access Denied")
        XCTAssertEqual(alert?.actions.map(\.title), ["Choose from Library", "Open Settings", "Cancel"])
    }

    @MainActor
    func testDeniedCameraWithoutLibraryFallback() {
        let fake = FakeEnvironment()
        fake.cameraStatus = .denied
        let manager = PhotoCaptureManager(environment: fake.environment)
        manager.configuration.promptForPhotoLibraryIfCameraDenied = false

        manager.capturePhoto(from: UIViewController()) { _ in }

        let alert = fake.presented.first as? UIAlertController
        XCTAssertEqual(alert?.message, PhotoCaptureStrings().cameraDeniedMessage)
        XCTAssertEqual(alert?.actions.map(\.title), ["Open Settings", "Cancel"])
    }

    @MainActor
    func testRestrictedCameraFinishesImmediately() {
        let fake = FakeEnvironment()
        fake.cameraStatus = .restricted
        let manager = PhotoCaptureManager(environment: fake.environment)
        var results: [PhotoCaptureResult] = []

        manager.capturePhoto(from: UIViewController()) { results.append($0) }

        guard case .failure(.permissionRestricted) = results.first else {
            return XCTFail("Expected .permissionRestricted, got \(results)")
        }
        XCTAssertTrue(fake.presented.isEmpty)
    }

    @MainActor
    func testRefusedCameraPromptShowsDeniedAlert() async {
        let fake = FakeEnvironment()
        fake.cameraStatus = .notDetermined
        fake.grantsCameraAccess = false
        let manager = PhotoCaptureManager(environment: fake.environment)
        // The manager holds its presenter weakly, so keep it alive across the async prompt.
        let presenter = UIViewController()

        manager.capturePhoto(from: presenter) { _ in }
        await waitUntil { !fake.presented.isEmpty }

        XCTAssertEqual((fake.presented.first as? UIAlertController)?.title, "Camera Access Denied")
    }

    @MainActor
    func testPickerCancelFinishesWithCancelled() {
        let fake = FakeEnvironment()
        let manager = PhotoCaptureManager(environment: fake.environment)
        var results: [PhotoCaptureResult] = []

        manager.pickPhoto(from: UIViewController()) { results.append($0) }
        guard let picker = fake.presented.first as? PHPickerViewController else {
            return XCTFail("Expected a PHPickerViewController, got \(fake.presented)")
        }
        manager.picker(picker, didFinishPicking: [])

        guard case .cancelled = results.first else {
            return XCTFail("Expected .cancelled, got \(results)")
        }
        XCTAssertTrue(fake.dismissed.first === picker)
    }

    @MainActor
    func testCallbacksFromInactivePickersAreIgnored() {
        let fake = FakeEnvironment()
        let manager = PhotoCaptureManager(environment: fake.environment)
        var results: [PhotoCaptureResult] = []

        manager.pickPhoto(from: UIViewController()) { results.append($0) }
        manager.picker(PHPickerViewController(configuration: PHPickerConfiguration()), didFinishPicking: [])
        manager.imagePickerControllerDidCancel(UIImagePickerController())

        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(fake.dismissed.isEmpty)
    }

    @MainActor
    func testOnlyDismissalOfActiveUICancelsRequest() {
        let fake = FakeEnvironment()
        let manager = PhotoCaptureManager(environment: fake.environment)
        var results: [PhotoCaptureResult] = []

        manager.presentPhotoOptions(from: UIViewController()) { results.append($0) }
        let unrelated = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        manager.presentationControllerDidDismiss(unrelated.presentationController!)
        XCTAssertTrue(results.isEmpty)

        let sheet = fake.presented[0]
        manager.presentationControllerDidDismiss(sheet.presentationController!)
        guard case .cancelled = results.first else {
            return XCTFail("Expected .cancelled, got \(results)")
        }
    }

    @MainActor
    func testCancellingTaskDismissesUIAndReturnsCancelled() async {
        let fake = FakeEnvironment()
        let manager = PhotoCaptureManager(environment: fake.environment)

        let task = Task { await manager.pickPhoto(from: UIViewController()) }
        await waitUntil { !fake.presented.isEmpty }
        task.cancel()
        let result = await task.value

        guard case .cancelled = result else {
            return XCTFail("Expected .cancelled, got \(result)")
        }
        XCTAssertTrue(fake.dismissed.first === fake.presented.first)

        var next: [PhotoCaptureResult] = []
        manager.pickPhoto(from: UIViewController()) { next.append($0) }
        XCTAssertTrue(next.isEmpty, "The manager should accept a new request")
    }

    @MainActor
    func testSilentlyRefusedPresentationFails() async {
        let fake = FakeEnvironment()
        fake.retainsPresentedControllers = false
        let manager = PhotoCaptureManager(environment: fake.environment)
        let presenter = UIViewController()
        var results: [PhotoCaptureResult] = []

        manager.pickPhoto(from: presenter) { results.append($0) }
        XCTAssertEqual(fake.presentCount, 1)
        await waitUntil { !results.isEmpty }

        guard case .failure(.presentationFailed) = results.first else {
            return XCTFail("Expected .presentationFailed, got \(results)")
        }
        fake.retainsPresentedControllers = true
        manager.pickPhoto(from: presenter) { results.append($0) }
        XCTAssertEqual(results.count, 1, "The manager should accept a new request")
    }

    @MainActor
    func testDeferredPresentationIsNotTreatedAsRefused() async {
        let fake = FakeEnvironment()
        fake.completesPresentationsImmediately = false
        let manager = PhotoCaptureManager(environment: fake.environment)
        var results: [PhotoCaptureResult] = []

        manager.pickPhoto(from: UIViewController()) { results.append($0) }
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(results.isEmpty, "A picker kept alive by a pending presentation is still coming")
    }

    @MainActor
    func testCancellationResumesOnlyAfterDismissalCompletes() async {
        let fake = FakeEnvironment()
        fake.completesDismissalsImmediately = false
        let manager = PhotoCaptureManager(environment: fake.environment)
        let presenter = UIViewController()
        let box = ResultBox()

        let task = Task { box.result = await manager.presentPhotoOptions(from: presenter) }
        await waitUntil { !fake.presented.isEmpty }
        task.cancel()
        await waitUntil { !fake.dismissed.isEmpty }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNil(box.result, "Should not resume while the sheet is still being dismissed")

        fake.completeDismissals()
        await task.value
        guard case .cancelled = box.result else {
            return XCTFail("Expected .cancelled, got \(String(describing: box.result))")
        }

        var next: [PhotoCaptureResult] = []
        manager.presentPhotoOptions(from: presenter) { next.append($0) }
        XCTAssertTrue(next.isEmpty, "A follow-up request should be accepted")
        XCTAssertEqual(fake.presented.count, 2)
    }

    @MainActor
    func testCancellationDuringDeferredPresentationDismissesOnceShown() async {
        let fake = FakeEnvironment()
        fake.completesPresentationsImmediately = false
        let manager = PhotoCaptureManager(environment: fake.environment)
        let presenter = UIViewController()
        let box = ResultBox()

        let task = Task { box.result = await manager.pickPhoto(from: presenter) }
        await waitUntil { !fake.presented.isEmpty }
        task.cancel()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertTrue(fake.dismissed.isEmpty, "Can't dismiss a picker that hasn't appeared yet")
        XCTAssertNil(box.result)

        fake.completePresentations()
        await task.value
        XCTAssertTrue(fake.dismissed.first === fake.presented.first)
        guard case .cancelled = box.result else {
            return XCTFail("Expected .cancelled, got \(String(describing: box.result))")
        }
    }

    @MainActor
    func testCancellationWhilePickerIsDismissingReusesThatDismissal() async {
        let fake = FakeEnvironment()
        fake.completesDismissalsImmediately = false
        let manager = PhotoCaptureManager(environment: fake.environment)
        let presenter = UIViewController()
        let box = ResultBox()

        let task = Task { box.result = await manager.pickPhoto(from: presenter) }
        await waitUntil { !fake.presented.isEmpty }
        guard let picker = fake.presented.first as? PHPickerViewController else {
            return XCTFail("Expected a PHPickerViewController, got \(fake.presented)")
        }
        manager.picker(picker, didFinishPicking: [])
        task.cancel()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(fake.dismissed.count, 1, "Should not dismiss the picker twice")
        XCTAssertNil(box.result)

        fake.completeDismissals()
        await task.value
        guard case .cancelled = box.result else {
            return XCTFail("Expected .cancelled, got \(String(describing: box.result))")
        }
    }

    @MainActor
    func testAlreadyCancelledTaskPresentsNothing() async {
        let fake = FakeEnvironment()
        let manager = PhotoCaptureManager(environment: fake.environment)

        let task = Task { await manager.pickPhoto(from: UIViewController()) }
        task.cancel()
        let result = await task.value

        guard case .cancelled = result else {
            return XCTFail("Expected .cancelled, got \(result)")
        }
        XCTAssertTrue(fake.presented.isEmpty)
    }

    // MARK: - Helpers

    @MainActor
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for condition", file: file, line: line)
    }
}

/// Records presentations instead of showing UI, and stubs camera availability and permissions.
/// Presentations and dismissals complete immediately unless told to wait, like UIKit's
/// deferred picker presentations and animated dismissals.
@MainActor
private final class FakeEnvironment {
    var cameraAvailable = false
    var cameraStatus: AVAuthorizationStatus = .authorized
    var grantsCameraAccess = true
    var presentationSucceeds = true
    var completesPresentationsImmediately = true
    var completesDismissalsImmediately = true
    /// When false, accepted controllers are released instead of kept, like UIKit does
    /// when it refuses a presentation while another deferred one is pending.
    var retainsPresentedControllers = true
    private(set) var presentCount = 0
    private(set) var presented: [UIViewController] = []
    private(set) var dismissed: [UIViewController] = []
    private var pendingPresentations: [() -> Void] = []
    private var pendingDismissals: [() -> Void] = []

    var environment: PhotoCaptureEnvironment {
        PhotoCaptureEnvironment(
            isCameraAvailable: { self.cameraAvailable },
            isCameraDeviceAvailable: { _ in true },
            cameraAuthorizationStatus: { self.cameraStatus },
            requestCameraAccess: { self.grantsCameraAccess },
            present: { controller, _, onPresented in
                guard self.presentationSucceeds else { return false }
                self.presentCount += 1
                guard self.retainsPresentedControllers else { return true }
                self.presented.append(controller)
                if self.completesPresentationsImmediately {
                    onPresented()
                } else {
                    self.pendingPresentations.append(onPresented)
                }
                return true
            },
            dismiss: { controller, completion in
                self.dismissed.append(controller)
                if self.completesDismissalsImmediately {
                    completion()
                } else {
                    self.pendingDismissals.append(completion)
                }
            },
            openSettings: {}
        )
    }

    func completePresentations() {
        let pending = pendingPresentations
        pendingPresentations = []
        pending.forEach { $0() }
    }

    func completeDismissals() {
        let pending = pendingDismissals
        pendingDismissals = []
        pending.forEach { $0() }
    }
}

/// Holds an async request's result so a test can check whether it has resumed yet.
@MainActor
private final class ResultBox {
    var result: PhotoCaptureResult?
}
