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
public enum PhotoCaptureResult {
    case success(UIImage)
    case cancelled
    case failure(PhotoCaptureError)
}

// MARK: - Error Type

public enum PhotoCaptureError: LocalizedError {
    case cameraUnavailable
    case permissionDenied(source: PhotoSource)
    case permissionRestricted
    case imageExtractionFailed
    case requestAlreadyInProgress
    case unknown(Error)

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

// MARK: - Source Enum

public enum PhotoSource {
    case camera
    case photoLibrary
}

// MARK: - Configuration

public struct PhotoCaptureConfiguration {
    /// When camera permission is denied, automatically prompt the user to pick
    /// from the photo library before offering the Settings deep-link.
    public var promptForPhotoLibraryIfCameraDenied: Bool

    /// Tint color used on action sheet / alert buttons.
    public var actionTintColor: UIColor

    /// Whether to allow editing after capture / selection.
    public var allowsEditing: Bool

    /// Compression quality (0.0 – 1.0) used by `jpegData(from:)` when a
    /// caller needs to convert the resulting UIImage to Data for upload
    /// or storage. Not applied automatically to the returned UIImage.
    public var imageCompressionQuality: CGFloat

    public init(
        promptForPhotoLibraryIfCameraDenied: Bool = true,
        actionTintColor: UIColor = .systemBlue,
        allowsEditing: Bool = false,
        imageCompressionQuality: CGFloat = 0.9
    ) {
        self.promptForPhotoLibraryIfCameraDenied = promptForPhotoLibraryIfCameraDenied
        self.actionTintColor = actionTintColor
        self.allowsEditing = allowsEditing
        self.imageCompressionQuality = imageCompressionQuality
    }
}

// MARK: - PhotoCaptureManager

/// A production-ready singleton that handles camera capture and photo library
/// picking, including permission requests, graceful degradation, and Settings
/// deep-linking.
///
/// Usage:
/// ```swift
/// PhotoCaptureManager.shared.presentPhotoOptions(from: self) { result in
///     switch result {
///     case .success(let image): // use image
///     case .cancelled: break
///     case .failure(let error): print(error.localizedDescription)
///     }
/// }
/// ```
public final class PhotoCaptureManager: NSObject {

    // MARK: - Singleton

    public static let shared = PhotoCaptureManager()
    private override init() { super.init() }

    // MARK: - Public Configuration

    public var configuration = PhotoCaptureConfiguration()

    // MARK: - Private State

    private weak var presentingViewController: UIViewController?
    private var completion: ((PhotoCaptureResult) -> Void)?

    // MARK: - Public API

    /// Presents a source-selection action sheet (Camera / Photo Library / Cancel).
    /// Falls back gracefully when the camera is unavailable (e.g., simulator).
    ///
    /// - Parameters:
    ///   - viewController: The view controller from which to present UI.
    ///   - sourceView:     Optional anchor view for iPad popovers.
    ///   - completion:     Called on the **main thread** with the capture result.
    public func presentPhotoOptions(
        from viewController: UIViewController,
        sourceView: UIView? = nil,
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
            title: "Select Photo",
            message: nil,
            preferredStyle: .actionSheet
        )
        sheet.view.tintColor = configuration.actionTintColor

        if cameraAvailable {
            sheet.addAction(UIAlertAction(title: "Take Photo", style: .default) { [weak self] _ in
                self?.requestCameraAccess()
            })
        }

        sheet.addAction(UIAlertAction(title: "Choose from Library", style: .default) { [weak self] _ in
            self?.requestPhotoLibraryAccess()
        })

        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.finish(.cancelled)
        })

        // iPad popover anchor
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = sourceView ?? viewController.view
            popover.sourceRect = sourceView?.bounds ?? CGRect(
                x: viewController.view.bounds.midX,
                y: viewController.view.bounds.midY,
                width: 0, height: 0
            )
            popover.permittedArrowDirections = sourceView != nil ? .any : []
        }

        // On iPad this sheet renders as a popover, which the user can dismiss
        // by tapping outside it without picking an action. That bypasses every
        // UIAlertAction handler above, so without this delegate hook the
        // completion would never fire.
        sheet.presentationController?.delegate = self

        viewController.present(sheet, animated: true)
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

    // MARK: - Camera Permission Flow

    private func requestCameraAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            presentCamera()

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.presentCamera() : self?.handleCameraPermissionDenied()
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
                title: "Camera Access Denied",
                message: "Camera permission is required to take photos. You can choose a photo from your library instead, or enable camera access in Settings.",
                preferredStyle: .alert
            )
            alert.view.tintColor = configuration.actionTintColor

            alert.addAction(UIAlertAction(title: "Choose from Library", style: .default) { [weak self] _ in
                self?.requestPhotoLibraryAccess()
            })
            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                Self.openAppSettings()
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                self?.finish(.cancelled)
            })

            vc.present(alert, animated: true)
        } else {
            // Just offer Settings deep-link.
            let alert = UIAlertController(
                title: "Camera Access Denied",
                message: "Please enable camera access in Settings to take photos.",
                preferredStyle: .alert
            )
            alert.view.tintColor = configuration.actionTintColor

            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                Self.openAppSettings()
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
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
                DispatchQueue.main.async {
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
            title: "Photo Library Access Denied",
            message: "Please enable photo library access in Settings to choose a photo.",
            preferredStyle: .alert
        )
        alert.view.tintColor = configuration.actionTintColor

        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            Self.openAppSettings()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
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
            // Plain init(): this class never reads `PHPickerResult.assetIdentifier`,
            // so there's no need to associate the picker with PHPhotoLibrary.shared().
            // (Doing so wouldn't cost you a permission prompt either way — the
            // picker always runs out-of-process regardless of which initializer
            // is used — but there's no reason to imply a library association
            // this class doesn't use.)
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
            // Default modalPresentationStyle here is interactively dismissible
            // (swipe-down). UIImagePickerController does NOT call
            // imagePickerControllerDidCancel for that gesture — only for its
            // own in-UI Cancel button — so without this delegate hook the
            // completion would never fire and the manager's state would be
            // stuck until the app is relaunched.
            picker.presentationController?.delegate = self
            vc.present(picker, animated: true)
        }
    }

    // MARK: - Helpers

    private static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    // Always hops to main, even though most callers are already there. This is
    // a deliberate safety net, not an oversight: NSItemProvider.loadObject's
    // completion handler and AVCaptureDevice.requestAccess's completion handler
    // are NOT documented to run on the main thread, so a caller-agnostic method
    // like this one can't assume its starting thread. The extra hop for
    // already-on-main callers is a negligible, harmless runloop turn.
    private func finish(_ result: PhotoCaptureResult) {
        DispatchQueue.main.async { [weak self] in
            self?.completion?(result)
            self?.completion = nil
            self?.presentingViewController = nil
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
        picker.dismiss(animated: true) { [weak self] in
            let key: UIImagePickerController.InfoKey = self?.configuration.allowsEditing == true
                ? .editedImage
                : .originalImage

            if let image = info[key] as? UIImage {
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
                DispatchQueue.main.async {
                    if let error {
                        self?.finish(.failure(.unknown(error)))
                    } else if let image = object as? UIImage {
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
/// `PHPickerViewController` doesn't need this — Apple guarantees its delegate
/// is always called exactly once, even on cancel — but the action sheet
/// (iPad popover) and the iOS 13 `UIImagePickerController` fallback both need
/// it explicitly.
extension PhotoCaptureManager: UIAdaptivePresentationControllerDelegate {
    public func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finish(.cancelled)
    }
}
