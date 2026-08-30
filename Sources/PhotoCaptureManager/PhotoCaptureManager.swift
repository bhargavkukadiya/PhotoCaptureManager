// PhotoCaptureManager.swift
// Production-ready singleton for camera capture and photo library access.
//
// REQUIRED Info.plist keys:
//   NSCameraUsageDescription
//   NSPhotoLibraryAddUsageDescription   (iOS 11+, needed only if you save photos back to the library)
//
// NSPhotoLibraryUsageDescription is only needed if you support iOS 13.
// On iOS 14+, photo picking uses PHPickerViewController, which runs out-of-process
// and requires NO library permission at all — do not request PHPhotoLibrary
// authorization before presenting it, or you defeat its entire privacy benefit.
//
// Minimum deployment target: iOS 13.0
// (PHPickerViewController is used automatically on iOS 14+; UIImagePickerController
// is used as the photo-library fallback on iOS 13.)

import UIKit
import AVFoundation
import Photos
import PhotosUI

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

// MARK: - PhotoCaptureManager

/// A production-ready singleton that handles camera capture and photo library
/// picking, including permission requests, graceful degradation, and Settings
/// deep-linking.
@MainActor
public final class PhotoCaptureManager: NSObject {

    // MARK: - Singleton

    public static let shared = PhotoCaptureManager()
    private override init() { super.init() }

    // MARK: - Public Configuration

    public var configuration = PhotoCaptureConfiguration()

    // MARK: - Private State

    private weak var presentingViewController: UIViewController?
    private var completion: ((PhotoCaptureResult) -> Void)?

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
        guard self.completion == nil else {
            completion(.failure(.requestAlreadyInProgress))
            return
        }
        self.presentingViewController = viewController
        self.completion = completion

        let cameraAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)

        let sheet = UIAlertController(
            title: configuration.strings.selectPhotoTitle,
            message: nil,
            preferredStyle: .actionSheet
        )
        sheet.view.tintColor = configuration.actionTintColor

        if cameraAvailable {
            sheet.addAction(UIAlertAction(title: configuration.strings.takePhotoAction, style: .default) { [weak self] _ in
                self?.requestCameraAccess()
            })
        }

        sheet.addAction(UIAlertAction(title: configuration.strings.chooseFromLibraryAction, style: .default) { [weak self] _ in
            self?.requestPhotoLibraryAccess()
        })

        sheet.addAction(UIAlertAction(title: configuration.strings.cancelAction, style: .cancel) { [weak self] _ in
            self?.finish(.cancelled)
        })

        // iPad popover anchor
        if let popover = sheet.popoverPresentationController {
            configurePopover(popover, anchor: anchor, fallbackIn: viewController.view)
        }

        // Catch interactive dismissal on iPad popover
        sheet.presentationController?.delegate = self

        viewController.present(sheet, animated: true)
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
        guard self.completion == nil else {
            completion(.failure(.requestAlreadyInProgress))
            return
        }
        self.presentingViewController = viewController
        self.completion = completion
        requestCameraAccess()
    }

    /// Directly launches the photo library picker, requesting permission first.
    public func pickPhoto(
        from viewController: UIViewController,
        completion: @escaping (PhotoCaptureResult) -> Void
    ) {
        guard self.completion == nil else {
            completion(.failure(.requestAlreadyInProgress))
            return
        }
        self.presentingViewController = viewController
        self.completion = completion
        requestPhotoLibraryAccess()
    }

    // MARK: - Modern Async / Await API

    /// Presents a source-selection action sheet asynchronously.
    public func presentPhotoOptions(
        from viewController: UIViewController,
        anchor: PopoverAnchor? = nil
    ) async -> PhotoCaptureResult {
        await withCheckedContinuation { continuation in
            presentPhotoOptions(from: viewController, anchor: anchor) { result in
                continuation.resume(returning: result)
            }
        }
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
        await withCheckedContinuation { continuation in
            capturePhoto(from: viewController) { result in
                continuation.resume(returning: result)
            }
        }
    }

    /// Directly launches the photo library picker asynchronously.
    public func pickPhoto(from viewController: UIViewController) async -> PhotoCaptureResult {
        await withCheckedContinuation { continuation in
            pickPhoto(from: viewController) { result in
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Camera Permission Flow

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            presentCamera()

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted {
                        self?.presentCamera()
                    } else {
                        self?.handleCameraPermissionDenied()
                    }
                }
            }

        case .denied:
            handleCameraPermissionDenied()

        case .restricted:
            finish(.failure(.permissionRestricted))

        @unknown default:
            finish(.failure(.cameraUnavailable))
        }
    }

    private func handleCameraPermissionDenied() {
        guard let vc = presentingViewController else {
            finish(.failure(.permissionDenied(source: .camera)))
            return
        }

        if configuration.promptForPhotoLibraryIfCameraDenied {
            // Offer photo library as fallback, plus Settings deep-link.
            let alert = UIAlertController(
                title: configuration.strings.cameraDeniedTitle,
                message: configuration.strings.cameraDeniedWithLibraryFallbackMessage,
                preferredStyle: .alert
            )
            alert.view.tintColor = configuration.actionTintColor

            alert.addAction(UIAlertAction(title: configuration.strings.chooseFromLibraryAction, style: .default) { [weak self] _ in
                self?.requestPhotoLibraryAccess()
            })
            alert.addAction(UIAlertAction(title: configuration.strings.openSettingsAction, style: .default) { [weak self] _ in
                Self.openAppSettings()
                self?.finish(.failure(.permissionDenied(source: .camera)))
            })
            alert.addAction(UIAlertAction(title: configuration.strings.cancelAction, style: .cancel) { [weak self] _ in
                self?.finish(.cancelled)
            })

            vc.present(alert, animated: true)
        } else {
            // Just offer Settings deep-link.
            let alert = UIAlertController(
                title: configuration.strings.cameraDeniedTitle,
                message: configuration.strings.cameraDeniedMessage,
                preferredStyle: .alert
            )
            alert.view.tintColor = configuration.actionTintColor

            alert.addAction(UIAlertAction(title: configuration.strings.openSettingsAction, style: .default) { [weak self] _ in
                Self.openAppSettings()
                self?.finish(.failure(.permissionDenied(source: .camera)))
            })
            alert.addAction(UIAlertAction(title: configuration.strings.cancelAction, style: .cancel) { [weak self] _ in
                self?.finish(.failure(.permissionDenied(source: .camera)))
            })

            vc.present(alert, animated: true)
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
            PHPhotoLibrary.requestAuthorization { [weak self] newStatus in
                Task { @MainActor [weak self] in
                    switch newStatus {
                    case .authorized, .limited:
                        self?.presentPhotoLibraryPicker()
                    default:
                        self?.handlePhotoLibraryPermissionDenied()
                    }
                }
            }

        case .denied:
            handlePhotoLibraryPermissionDenied()

        case .restricted:
            finish(.failure(.permissionRestricted))

        @unknown default:
            finish(.failure(.permissionDenied(source: .photoLibrary)))
        }
    }

    private func handlePhotoLibraryPermissionDenied() {
        guard let vc = presentingViewController else {
            finish(.failure(.permissionDenied(source: .photoLibrary)))
            return
        }

        let alert = UIAlertController(
            title: configuration.strings.libraryDeniedTitle,
            message: configuration.strings.libraryDeniedMessage,
            preferredStyle: .alert
        )
        alert.view.tintColor = configuration.actionTintColor

        alert.addAction(UIAlertAction(title: configuration.strings.openSettingsAction, style: .default) { [weak self] _ in
            Self.openAppSettings()
            self?.finish(.failure(.permissionDenied(source: .photoLibrary)))
        })
        alert.addAction(UIAlertAction(title: configuration.strings.cancelAction, style: .cancel) { [weak self] _ in
            self?.finish(.failure(.permissionDenied(source: .photoLibrary)))
        })

        vc.present(alert, animated: true)
    }

    // MARK: - Presenting Pickers

    private func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            finish(.failure(.cameraUnavailable))
            return
        }
        guard let vc = presentingViewController else {
            finish(.cancelled)
            return
        }

        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = configuration.allowsEditing
        if UIImagePickerController.isCameraDeviceAvailable(configuration.preferredCameraDevice) {
            picker.cameraDevice = configuration.preferredCameraDevice
        }
        picker.delegate = self
        picker.modalPresentationStyle = .fullScreen
        vc.present(picker, animated: true)
    }

    private func presentPhotoLibraryPicker() {
        guard let vc = presentingViewController else {
            finish(.cancelled)
            return
        }

        if #available(iOS 14, *) {
            var config = PHPickerConfiguration()
            config.selectionLimit = 1
            config.filter = .images
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = self
            vc.present(picker, animated: true)
        } else {
            let picker = UIImagePickerController()
            picker.sourceType = .photoLibrary
            picker.allowsEditing = configuration.allowsEditing
            picker.delegate = self
            picker.presentationController?.delegate = self
            vc.present(picker, animated: true)
        }
    }

    // MARK: - Helpers

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

    private static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    private func finish(_ result: PhotoCaptureResult) {
        let callback = self.completion
        self.completion = nil
        self.presentingViewController = nil
        callback?(result)
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
        picker.dismiss(animated: true) { [weak self] in
            let image = (self?.configuration.allowsEditing == true ? info[.editedImage] as? UIImage : nil)
                ?? (info[.originalImage] as? UIImage)

            if let image {
                self?.finish(.success(image))
            } else {
                self?.finish(.failure(.imageExtractionFailed))
            }
        }
    }

    public func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true) { [weak self] in
            self?.finish(.cancelled)
        }
    }
}

// MARK: - PHPickerViewControllerDelegate (iOS 14+)

@available(iOS 14, *)
extension PhotoCaptureManager: PHPickerViewControllerDelegate {

    public func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true) { [weak self] in
            guard let self else { return }

            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                // User tapped Done without selecting anything → treat as cancel
                if results.isEmpty {
                    self.finish(.cancelled)
                } else {
                    self.finish(.failure(.imageExtractionFailed))
                }
                return
            }

            provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
                let image = object as? UIImage
                let sendableError = error
                Task { @MainActor [weak self] in
                    if let sendableError {
                        self?.finish(.failure(.unknown(sendableError)))
                    } else if let image {
                        self?.finish(.success(image))
                    } else {
                        self?.finish(.failure(.imageExtractionFailed))
                    }
                }
            }
        }
    }
}

// MARK: - UIAdaptivePresentationControllerDelegate

/// Catches interactive dismissals (swipe-down on a sheet, or tapping outside
/// an iPad popover) that bypass the normal completion-handler paths above.
extension PhotoCaptureManager: UIAdaptivePresentationControllerDelegate {
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finish(.cancelled)
    }
}
