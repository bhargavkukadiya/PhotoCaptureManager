// PhotoCaptureManager.swift
// Production-ready singleton for camera capture and photo library access.
//
// REQUIRED Info.plist keys:
//   NSCameraUsageDescription
//   NSPhotoLibraryUsageDescription   (only if your deployment target includes iOS 13)
//
// On iOS 14+, photo picking uses PHPickerViewController, which runs out-of-process
// and requires NO library permission at all — do not request PHPhotoLibrary
// authorization before presenting it, or you defeat its entire privacy benefit.
//
// Minimum deployment target: iOS 13.0
// (PHPickerViewController is used automatically on iOS 14+; UIImagePickerController
// is used as the photo-library fallback on iOS 13.)
//
// Not available in app extensions: opening Settings uses `UIApplication.shared`.

import UIKit
import AVFoundation
import Photos
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Result Type

/// Encapsulates the outcome of a photo capture or pick operation.
public enum PhotoCaptureResult: Sendable {
    case success(UIImage)
    case cancelled
    case failure(PhotoCaptureError)
}

// MARK: - Error Type

public enum PhotoCaptureError: LocalizedError, Sendable {
    case cameraUnavailable
    case permissionDenied(source: PhotoSource)
    case permissionRestricted
    case imageExtractionFailed
    case requestAlreadyInProgress
    /// UIKit refused to present the picker or alert, e.g. because the presenting view
    /// controller is not in a window or is already presenting something else.
    case presentationFailed
    case unknown(any Error & Sendable)

    public var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            return "This device does not have a camera."
        case .permissionDenied(let source):
            return "\(source == .camera ? "Camera" : "Photo Library") access was denied."
        case .permissionRestricted:
            return "Access to media is restricted on this device."
        case .imageExtractionFailed:
            return "Could not extract an image from the selected item."
        case .requestAlreadyInProgress:
            return "Another photo capture request is already in progress."
        case .presentationFailed:
            return "The photo picker could not be presented."
        case .unknown(let error):
            return error.localizedDescription
        }
    }
}

// MARK: - Source & Anchor Types

public enum PhotoSource: Sendable {
    case camera
    case photoLibrary
}

/// Anchor for iPad popovers, supporting both `UIView` and `UIBarButtonItem`.
public enum PopoverAnchor: Sendable {
    case view(UIView, sourceRect: CGRect? = nil)
    case barButtonItem(UIBarButtonItem)
}

// MARK: - Localizable Strings

/// Localizable user-facing strings used throughout alerts and sheets.
public struct PhotoCaptureStrings: Sendable {
    public var selectPhotoTitle: String
    public var takePhotoAction: String
    public var chooseFromLibraryAction: String
    public var cancelAction: String
    public var openSettingsAction: String
    public var cameraDeniedTitle: String
    public var cameraDeniedWithLibraryFallbackMessage: String
    public var cameraDeniedMessage: String
    public var libraryDeniedTitle: String
    public var libraryDeniedMessage: String

    public init(
        selectPhotoTitle: String = "Select Photo",
        takePhotoAction: String = "Take Photo",
        chooseFromLibraryAction: String = "Choose from Library",
        cancelAction: String = "Cancel",
        openSettingsAction: String = "Open Settings",
        cameraDeniedTitle: String = "Camera Access Denied",
        cameraDeniedWithLibraryFallbackMessage: String = "Camera permission is required to take photos. You can choose a photo from your library instead, or enable camera access in Settings.",
        cameraDeniedMessage: String = "Please enable camera access in Settings to take photos.",
        libraryDeniedTitle: String = "Photo Library Access Denied",
        libraryDeniedMessage: String = "Please enable photo library access in Settings to choose a photo."
    ) {
        self.selectPhotoTitle = selectPhotoTitle
        self.takePhotoAction = takePhotoAction
        self.chooseFromLibraryAction = chooseFromLibraryAction
        self.cancelAction = cancelAction
        self.openSettingsAction = openSettingsAction
        self.cameraDeniedTitle = cameraDeniedTitle
        self.cameraDeniedWithLibraryFallbackMessage = cameraDeniedWithLibraryFallbackMessage
        self.cameraDeniedMessage = cameraDeniedMessage
        self.libraryDeniedTitle = libraryDeniedTitle
        self.libraryDeniedMessage = libraryDeniedMessage
    }
}

// MARK: - Configuration

public struct PhotoCaptureConfiguration: Sendable {
    /// When camera permission is denied, automatically prompt the user to pick
    /// from the photo library before offering the Settings deep-link.
    public var promptForPhotoLibraryIfCameraDenied: Bool

    /// Tint color used on action sheet / alert buttons.
    public var actionTintColor: UIColor

    /// Whether to allow editing after capture / selection (applies to camera & iOS 13 picker).
    public var allowsEditing: Bool

    /// Preferred camera device (e.g. .rear or .front).
    public var preferredCameraDevice: UIImagePickerController.CameraDevice

    /// Compression quality (0.0 – 1.0) used by `jpegData(from:)` when a
    /// caller needs to convert the resulting UIImage to Data for upload
    /// or storage. Not applied automatically to the returned UIImage.
    public var imageCompressionQuality: CGFloat

    /// User-facing strings for localization.
    public var strings: PhotoCaptureStrings

    public init(
        promptForPhotoLibraryIfCameraDenied: Bool = true,
        actionTintColor: UIColor = .systemBlue,
        allowsEditing: Bool = false,
        preferredCameraDevice: UIImagePickerController.CameraDevice = .rear,
        imageCompressionQuality: CGFloat = 0.9,
        strings: PhotoCaptureStrings = PhotoCaptureStrings()
    ) {
        self.promptForPhotoLibraryIfCameraDenied = promptForPhotoLibraryIfCameraDenied
        self.actionTintColor = actionTintColor
        self.allowsEditing = allowsEditing
        self.preferredCameraDevice = preferredCameraDevice
        self.imageCompressionQuality = imageCompressionQuality
        self.strings = strings
    }
}

// MARK: - Environment

/// The UIKit / AVFoundation side effects the manager depends on, so the request
/// lifecycle can be unit tested.
@MainActor
struct PhotoCaptureEnvironment {
    var isCameraAvailable: () -> Bool
    var isCameraDeviceAvailable: (UIImagePickerController.CameraDevice) -> Bool
    var cameraAuthorizationStatus: () -> AVAuthorizationStatus
    var requestCameraAccess: @MainActor () async -> Bool
    /// Presents `controller` from `presenter`, calling `onPresented` once it is on
    /// screen. Returns `false` if the presentation can't happen.
    var present: (
        _ controller: UIViewController,
        _ presenter: UIViewController,
        _ onPresented: @escaping () -> Void
    ) -> Bool
    var dismiss: (_ controller: UIViewController, _ completion: @escaping () -> Void) -> Void
    var openSettings: () -> Void

    static var live: PhotoCaptureEnvironment {
        PhotoCaptureEnvironment(
            isCameraAvailable: { UIImagePickerController.isSourceTypeAvailable(.camera) },
            isCameraDeviceAvailable: { UIImagePickerController.isCameraDeviceAvailable($0) },
            cameraAuthorizationStatus: { AVCaptureDevice.authorizationStatus(for: .video) },
            requestCameraAccess: { await AVCaptureDevice.requestAccess(for: .video) },
            present: { controller, presenter, onPresented in
                // UIKit only logs a warning when it refuses a presentation, so check its
                // preconditions up front. `controller.presentingViewController` can't be
                // checked afterwards: the pickers defer presentation until their UI is
                // ready, leaving it nil when `present` returns.
                guard presenter.viewIfLoaded?.window != nil,
                      presenter.presentedViewController == nil,
                      !presenter.isBeingDismissed else { return false }
                presenter.present(controller, animated: true, completion: onPresented)
                return true
            },
            dismiss: { controller, completion in
                controller.dismiss(animated: true, completion: completion)
            },
            openSettings: {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
        )
    }
}

/// Lets a task-cancellation handler find the request it belongs to.
@MainActor
private final class RequestHandle {
    var id: Int?
}

// MARK: - PhotoCaptureManager

/// A production-ready singleton that handles camera capture and photo library
/// picking, including permission requests, graceful degradation, and Settings
/// deep-linking.
@MainActor
public final class PhotoCaptureManager: NSObject {

    // MARK: - Singleton

    public static let shared = PhotoCaptureManager()

    init(environment: PhotoCaptureEnvironment = .live) {
        self.environment = environment
        super.init()
    }

    // MARK: - Public Configuration

    public var configuration = PhotoCaptureConfiguration()

    /// Called with `true` when a picked photo starts loading after the picker has
    /// closed (it may have to be downloaded from iCloud), and with `false` when
    /// loading ends. Use it to show a progress indicator.
    public var imageLoadingHandler: ((_ isLoading: Bool) -> Void)?

    // MARK: - Private State

    private let environment: PhotoCaptureEnvironment
    private weak var presentingViewController: UIViewController?
    /// The alert or picker presented for the active request, possibly still appearing.
    private weak var activeController: UIViewController?
    /// Whether `activeController` has finished appearing.
    private var isActiveControllerPresented = false
    /// Whether `activeController` is being dismissed.
    private var isDismissingActiveController = false
    /// Incremented per presentation, so a refusal check can tell whether it is still current.
    private var presentationID = 0
    private var completion: ((PhotoCaptureResult) -> Void)?
    /// Incremented per request, so late callbacks can tell whether their request is still active.
    private var requestID = 0
    /// Set while a cancelled request waits for its UI to be dismissed.
    private var isCancelling = false
    private var isLoadingImage = false

    // MARK: - Public Completion-Handler API

    /// Presents a source-selection action sheet (Camera / Photo Library / Cancel).
    /// Falls back gracefully when the camera is unavailable (e.g., simulator).
    ///
    /// - Parameters:
    ///   - viewController: The view controller from which to present UI.
    ///   - anchor:         Optional anchor (UIView or UIBarButtonItem) for iPad popovers.
    ///   - completion:     Called on the **main thread** with the capture result.
    public func presentPhotoOptions(
        from viewController: UIViewController,
        anchor: PopoverAnchor? = nil,
        completion: @escaping (PhotoCaptureResult) -> Void
    ) {
        guard beginRequest(from: viewController, completion: completion) != nil else { return }
        showSourceOptions(anchor: anchor)
    }

    /// Convenience overload supporting `sourceView` directly for backward compatibility.
    public func presentPhotoOptions(
        from viewController: UIViewController,
        sourceView: UIView?,
        completion: @escaping (PhotoCaptureResult) -> Void
    ) {
        let anchor = sourceView.map { PopoverAnchor.view($0) }
        presentPhotoOptions(from: viewController, anchor: anchor, completion: completion)
    }

    /// Directly launches the camera, requesting permission first.
    public func capturePhoto(
        from viewController: UIViewController,
        completion: @escaping (PhotoCaptureResult) -> Void
    ) {
        guard beginRequest(from: viewController, completion: completion) != nil else { return }
        requestCameraAccess()
    }

    /// Directly launches the photo library picker, requesting permission first.
    public func pickPhoto(
        from viewController: UIViewController,
        completion: @escaping (PhotoCaptureResult) -> Void
    ) {
        guard beginRequest(from: viewController, completion: completion) != nil else { return }
        requestPhotoLibraryAccess()
    }

    // MARK: - Modern Async / Await API
    //
    // Cancelling the calling task dismisses any UI the request has on screen and
    // returns `.cancelled` once that dismissal has finished.

    /// Presents a source-selection action sheet asynchronously.
    public func presentPhotoOptions(
        from viewController: UIViewController,
        anchor: PopoverAnchor? = nil
    ) async -> PhotoCaptureResult {
        await performRequest(from: viewController) { showSourceOptions(anchor: anchor) }
    }

    /// Convenience async overload supporting `sourceView`.
    public func presentPhotoOptions(
        from viewController: UIViewController,
        sourceView: UIView?
    ) async -> PhotoCaptureResult {
        let anchor = sourceView.map { PopoverAnchor.view($0) }
        return await presentPhotoOptions(from: viewController, anchor: anchor)
    }

    /// Directly launches the camera asynchronously.
    public func capturePhoto(from viewController: UIViewController) async -> PhotoCaptureResult {
        await performRequest(from: viewController) { requestCameraAccess() }
    }

    /// Directly launches the photo library picker asynchronously.
    public func pickPhoto(from viewController: UIViewController) async -> PhotoCaptureResult {
        await performRequest(from: viewController) { requestPhotoLibraryAccess() }
    }

    // MARK: - Request Lifecycle

    /// Starts a request and returns its ID, or reports `.requestAlreadyInProgress`
    /// and returns `nil`.
    private func beginRequest(
        from viewController: UIViewController,
        completion: @escaping (PhotoCaptureResult) -> Void
    ) -> Int? {
        guard self.completion == nil else {
            completion(.failure(.requestAlreadyInProgress))
            return nil
        }
        requestID += 1
        presentingViewController = viewController
        self.completion = completion
        return requestID
    }

    /// Bridges a request to async/await, cancelling it if the calling task is cancelled.
    private func performRequest(
        from viewController: UIViewController,
        start: () -> Void
    ) async -> PhotoCaptureResult {
        let handle = RequestHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                handle.id = beginRequest(from: viewController) { continuation.resume(returning: $0) }
                if handle.id != nil { start() }
            }
        } onCancel: {
            Task { @MainActor in
                if let id = handle.id { self.cancelRequest(id) }
            }
        }
    }

    private func isActive(_ id: Int) -> Bool {
        completion != nil && id == requestID && !isCancelling
    }

    /// Dismisses the request's UI before finishing with `.cancelled`, so the caller
    /// can start a new request as soon as it resumes.
    private func cancelRequest(_ id: Int) {
        guard isActive(id) else { return }
        isCancelling = true

        if isDismissingActiveController {
            // That dismissal's completion finishes the request.
        } else if activeController == nil {
            finish(.cancelled)
        } else if isActiveControllerPresented {
            dismissActiveController {}
        }
        // Otherwise it is still appearing; `didPresent(_:)` dismisses it, or the
        // refusal check in `present(_:observingDismissal:)` finishes the request.
    }

    private func finish(_ result: PhotoCaptureResult) {
        setImageLoading(false)
        let callback = completion
        completion = nil
        presentingViewController = nil
        activeController = nil
        isActiveControllerPresented = false
        isDismissingActiveController = false
        isCancelling = false
        callback?(result)
    }

    private func setImageLoading(_ isLoading: Bool) {
        guard isLoadingImage != isLoading else { return }
        isLoadingImage = isLoading
        imageLoadingHandler?(isLoading)
    }

    // MARK: - Source Selection

    private func showSourceOptions(anchor: PopoverAnchor?) {
        guard let viewController = presentingViewController else {
            finish(.cancelled)
            return
        }

        let strings = configuration.strings
        let sheet = UIAlertController(title: strings.selectPhotoTitle, message: nil, preferredStyle: .actionSheet)
        sheet.view.tintColor = configuration.actionTintColor

        if environment.isCameraAvailable() {
            sheet.addAction(action(strings.takePhotoAction) { self.requestCameraAccess() })
        }
        sheet.addAction(action(strings.chooseFromLibraryAction) { self.requestPhotoLibraryAccess() })
        sheet.addAction(action(strings.cancelAction, style: .cancel) { self.finish(.cancelled) })

        // iPad popover anchor
        if let popover = sheet.popoverPresentationController {
            configurePopover(popover, anchor: anchor, fallbackIn: viewController.view)
        }

        // Observe dismissal to catch taps outside the iPad popover.
        present(sheet, observingDismissal: true)
    }

    // MARK: - Camera Permission Flow

    private func requestCameraAccess() {
        switch environment.cameraAuthorizationStatus() {
        case .authorized:
            presentCamera()

        case .notDetermined:
            let id = requestID
            Task {
                let granted = await environment.requestCameraAccess()
                guard isActive(id) else { return }
                if granted {
                    presentCamera()
                } else {
                    showPermissionDeniedAlert(for: .camera)
                }
            }

        case .denied:
            showPermissionDeniedAlert(for: .camera)

        case .restricted:
            finish(.failure(.permissionRestricted))

        @unknown default:
            finish(.failure(.permissionDenied(source: .camera)))
        }
    }

    // MARK: - Photo Library Permission Flow

    private func requestPhotoLibraryAccess() {
        // iOS 14+: PHPickerViewController runs out-of-process in a separate
        // extension and never gives the host app access to the library it
        // didn't pick from. Apple's guidance is explicit that no permission
        // request is required — or even appropriate — before presenting it.
        if #available(iOS 14, *) {
            presentPhotoLibraryPicker()
            return
        }

        // iOS 13 fallback: UIImagePickerController with sourceType .photoLibrary
        // DOES require classic PHPhotoLibrary read permission.
        switch PHPhotoLibrary.authorizationStatus() {
        case .authorized, .limited:
            presentPhotoLibraryPicker()

        case .notDetermined:
            let id = requestID
            Task {
                let status = await Self.requestLegacyPhotoLibraryAuthorization()
                guard isActive(id) else { return }
                switch status {
                case .authorized, .limited:
                    presentPhotoLibraryPicker()
                default:
                    showPermissionDeniedAlert(for: .photoLibrary)
                }
            }

        case .denied:
            showPermissionDeniedAlert(for: .photoLibrary)

        case .restricted:
            finish(.failure(.permissionRestricted))

        @unknown default:
            finish(.failure(.permissionDenied(source: .photoLibrary)))
        }
    }

    /// iOS 13 only. The handler runs on an arbitrary queue, so it is explicitly
    /// `@Sendable` to keep it from inheriting main-actor isolation (which traps
    /// at runtime in Swift 6).
    private static func requestLegacyPhotoLibraryAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Permission Denied

    /// Offers a Settings deep-link (and, for the camera, optionally the photo
    /// library). Both Settings and Cancel finish with `.permissionDenied`.
    private func showPermissionDeniedAlert(for source: PhotoSource) {
        let strings = configuration.strings
        let offersLibrary = source == .camera && configuration.promptForPhotoLibraryIfCameraDenied
        let title: String
        let message: String
        switch source {
        case .camera:
            title = strings.cameraDeniedTitle
            message = offersLibrary ? strings.cameraDeniedWithLibraryFallbackMessage : strings.cameraDeniedMessage
        case .photoLibrary:
            title = strings.libraryDeniedTitle
            message = strings.libraryDeniedMessage
        }
        let denied = PhotoCaptureResult.failure(.permissionDenied(source: source))

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.view.tintColor = configuration.actionTintColor

        if offersLibrary {
            alert.addAction(action(strings.chooseFromLibraryAction) { self.requestPhotoLibraryAccess() })
        }
        alert.addAction(action(strings.openSettingsAction) {
            self.environment.openSettings()
            self.finish(denied)
        })
        alert.addAction(action(strings.cancelAction, style: .cancel) { self.finish(denied) })

        present(alert)
    }

    // MARK: - Presenting Pickers

    private func presentCamera() {
        guard environment.isCameraAvailable() else {
            finish(.failure(.cameraUnavailable))
            return
        }

        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = configuration.allowsEditing
        if environment.isCameraDeviceAvailable(configuration.preferredCameraDevice) {
            picker.cameraDevice = configuration.preferredCameraDevice
        }
        picker.delegate = self
        picker.modalPresentationStyle = .fullScreen
        present(picker)
    }

    private func presentPhotoLibraryPicker() {
        if #available(iOS 14, *) {
            var config = PHPickerConfiguration()
            config.selectionLimit = 1
            config.filter = .images
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            present(picker, observingDismissal: true)
        } else {
            let picker = UIImagePickerController()
            picker.sourceType = .photoLibrary
            picker.allowsEditing = configuration.allowsEditing
            picker.delegate = self
            present(picker, observingDismissal: true)
        }
    }

    // MARK: - Helpers

    /// Presents `controller` for the active request. Finishes the request if the
    /// presenter is gone or can't present right now, so it can never hang.
    private func present(_ controller: UIViewController, observingDismissal: Bool = false) {
        guard let presenter = presentingViewController else {
            finish(.cancelled)
            return
        }
        if observingDismissal {
            controller.presentationController?.delegate = self
        }

        activeController = controller
        isActiveControllerPresented = false
        presentationID += 1
        let id = presentationID
        let accepted = environment.present(controller, presenter) { [weak self, weak controller] in
            guard let self, let controller else { return }
            didPresent(controller)
        }
        guard accepted else {
            activeController = nil
            finish(.failure(.presentationFailed))
            return
        }

        // UIKit also refuses, with only a log message, while the presenter is waiting
        // for another deferred presentation. It then releases the controller, so the
        // weakly held `activeController` goes nil before it ever appears; a deferred
        // presentation that will still happen keeps it alive.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self, presentationID == id, completion != nil,
                  activeController == nil, !isActiveControllerPresented else { return }
            finish(isCancelling ? .cancelled : .failure(.presentationFailed))
        }
    }

    private func didPresent(_ controller: UIViewController) {
        guard controller === activeController else { return }
        isActiveControllerPresented = true
        if isCancelling {
            // Cancelled while it was still appearing.
            dismissActiveController {}
        }
    }

    /// Dismisses `activeController`, then runs `next` if the request is still active.
    /// If the request was cancelled meanwhile, finishes it with `.cancelled` instead.
    private func dismissActiveController(then next: @escaping () -> Void) {
        guard let controller = activeController else {
            isCancelling ? finish(.cancelled) : next()
            return
        }
        let id = requestID
        isDismissingActiveController = true
        environment.dismiss(controller) { [self] in
            guard completion != nil, requestID == id else { return }
            activeController = nil
            isActiveControllerPresented = false
            isDismissingActiveController = false
            if isCancelling {
                finish(.cancelled)
            } else {
                next()
            }
        }
    }

    /// Whether a delegate callback comes from the active picker and should be handled.
    private func isActivePicker(_ picker: UIViewController) -> Bool {
        picker === activeController && isActive(requestID) && !isDismissingActiveController
    }

    /// An alert action whose handler runs only if its request is still active.
    private func action(
        _ title: String,
        style: UIAlertAction.Style = .default,
        handler: @escaping () -> Void
    ) -> UIAlertAction {
        let id = requestID
        return UIAlertAction(title: title, style: style) { [self] _ in
            guard isActive(id) else { return }
            handler()
        }
    }

    private func configurePopover(
        _ popover: UIPopoverPresentationController,
        anchor: PopoverAnchor?,
        fallbackIn fallbackView: UIView
    ) {
        switch anchor {
        case .barButtonItem(let item):
            popover.barButtonItem = item
        case .view(let view, let customRect):
            popover.sourceView = view
            popover.sourceRect = customRect ?? view.bounds
            popover.permittedArrowDirections = .any
        case .none:
            popover.sourceView = fallbackView
            popover.sourceRect = CGRect(
                x: fallbackView.bounds.midX,
                y: fallbackView.bounds.midY,
                width: 0, height: 0
            )
            popover.permittedArrowDirections = []
        }
    }

    // MARK: - Public Utilities

    /// Converts a captured/picked `UIImage` to JPEG `Data` using
    /// `configuration.imageCompressionQuality`. Useful when uploading the
    /// result or writing it to disk.
    public func jpegData(from image: UIImage) -> Data? {
        image.jpegData(compressionQuality: configuration.imageCompressionQuality)
    }
}

// MARK: - UIImagePickerControllerDelegate

extension PhotoCaptureManager: UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    public func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        guard isActivePicker(picker) else { return }
        let image = (configuration.allowsEditing ? info[.editedImage] as? UIImage : nil)
            ?? (info[.originalImage] as? UIImage)

        dismissActiveController { [self] in
            finish(image.map { .success($0) } ?? .failure(.imageExtractionFailed))
        }
    }

    public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        guard isActivePicker(picker) else { return }
        dismissActiveController { [self] in
            finish(.cancelled)
        }
    }
}

// MARK: - PHPickerViewControllerDelegate (iOS 14+)

@available(iOS 14, *)
extension PhotoCaptureManager: PHPickerViewControllerDelegate {

    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        guard isActivePicker(picker) else { return }

        dismissActiveController { [self] in
            // User tapped Cancel, or Done without selecting anything.
            guard let provider = results.first?.itemProvider else {
                finish(.cancelled)
                return
            }
            loadImage(from: provider, request: requestID)
        }
    }

    private func loadImage(from provider: NSItemProvider, request id: Int) {
        let complete: @Sendable (UIImage?, (any Error)?) -> Void = { [self] image, error in
            Task { @MainActor in
                guard isActive(id) else { return }
                if let image {
                    finish(.success(image))
                } else if let error {
                    finish(.failure(.unknown(error)))
                } else {
                    finish(.failure(.imageExtractionFailed))
                }
            }
        }

        if provider.canLoadObject(ofClass: UIImage.self) {
            setImageLoading(true)
            provider.loadObject(ofClass: UIImage.self) { @Sendable object, error in
                complete(object as? UIImage, error)
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            // Formats UIImage can't load as an object (e.g. RAW): decode a file copy,
            // which is deleted once this handler returns.
            setImageLoading(true)
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { @Sendable url, error in
                let image = url.flatMap { try? Data(contentsOf: $0) }.flatMap(UIImage.init(data:))
                complete(image, error)
            }
        } else {
            finish(.failure(.imageExtractionFailed))
        }
    }
}

// MARK: - UIAdaptivePresentationControllerDelegate

/// Catches interactive dismissals (swipe-down on a sheet, or tapping outside
/// an iPad popover) that bypass the normal completion-handler paths above.
extension PhotoCaptureManager: UIAdaptivePresentationControllerDelegate {
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        // Ignore anything but the active request's UI, e.g. a popover whose Cancel
        // action already finished its request (and maybe started a new one).
        // This also finishes a cancelled request whose UI the user swiped away.
        guard completion != nil,
              presentationController.presentedViewController === activeController else { return }
        finish(.cancelled)
    }
}
