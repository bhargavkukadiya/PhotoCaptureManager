# PhotoCaptureManager

[![Swift](https://img.shields.io/badge/Swift-6.0+-orange.svg?style=flat)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platforms-iOS%2013.0+-blue.svg?style=flat)](https://developer.apple.com/ios/)
[![SPM](https://img.shields.io/badge/Swift_Package_Manager-compatible-brightgreen.svg?style=flat)](https://swift.org/package-manager/)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat)](LICENSE)

A production-ready, privacy-first Swift library for taking photos with the camera or picking from the photo library. Handles all permission lifecycles, graceful degradation, iPad popover anchoring, and Settings deep-linking out of the box with zero third-party dependencies.

---

## ✨ Features

- ⚡️ **Modern Concurrency** — Full `async/await` support (with task cancellation) and `@MainActor` / `Sendable` isolation, built in the Swift 6 language mode.
- 🔄 **Completion Handler Support** — Backward-compatible callback APIs for existing projects.
- 🔒 **Privacy-First** — Uses `PHPickerViewController` (iOS 14+) which runs out-of-process and requires **zero photo library permissions**.
- 📱 **Graceful Fallbacks** — Automatic fallback to `UIImagePickerController` on iOS 13, plus simulator detection for camera-less environments.
- 🧭 **Permission Lifecycle & Recovery** — Handles `.notDetermined`, `.denied`, `.restricted`, and `.limited` states with deep-linking to Settings.
- 📲 **iPad Popover Safe** — Supports anchoring to `UIView` and `UIBarButtonItem` without interactive dismissal hangs.
- 🌐 **Fully Localizable** — Customize or translate all action sheet and alert strings easily.
- 📦 **Zero Third-Party Dependencies** — Pure Swift built atop `UIKit`, `AVFoundation`, and `PhotosUI`.

---

## 📋 Requirements

| Item | Requirement |
|:---|:---|
| **iOS** | 13.0+ |
| **Swift** | 6.0+ |
| **Xcode** | 16.0+ |
| **Frameworks** | `UIKit`, `AVFoundation`, `Photos`, `PhotosUI` |

---

## 📦 Installation

### Swift Package Manager (SPM)

In Xcode, select **File → Add Package Dependencies...** and enter the repository URL:

```
https://github.com/bhargavkukadiya/PhotoCaptureManager.git
```

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/bhargavkukadiya/PhotoCaptureManager.git", from: "1.0.0")
]
```

### Manual

Drag and drop `Sources/PhotoCaptureManager/PhotoCaptureManager.swift` into your Xcode project.

> **App extensions:** `PhotoCaptureManager` uses `UIApplication.shared` to open Settings, so it can't be used in app extension targets.

---

## 🛠 Info.plist Keys

Add the required usage descriptions to your app's `Info.plist`:

```xml
<!-- Required for Camera capture -->
<key>NSCameraUsageDescription</key>
<string>We need camera access to capture profile photos.</string>
```

> **Note on `NSPhotoLibraryUsageDescription`:**
> `NSPhotoLibraryUsageDescription` is **not required** on iOS 14+ because `PHPickerViewController` operates out-of-process. Only include this key if your deployment target includes **iOS 13**.

---

## 🚀 Quick Start

### 1. Modern `async/await` (Recommended)

```swift
import UIKit
import PhotoCaptureManager

@MainActor
final class ProfileViewController: UIViewController {

    private let avatarImageView = UIImageView()

    @IBAction func changePhotoTapped(_ sender: UIButton) {
        Task {
            let result = await PhotoCaptureManager.shared.presentPhotoOptions(
                from: self,
                anchor: .view(sender)
            )

            switch result {
            case .success(let image):
                self.avatarImageView.image = image

            case .cancelled:
                break // User dismissed the picker

            case .failure(let error):
                print("Capture failed: \(error.localizedDescription)")
            }
        }
    }
}
```

Cancelling the surrounding `Task` dismisses any picker or alert still on screen and returns `.cancelled` once it is gone, so you can start a new request right away.

### 2. Completion Handlers

```swift
PhotoCaptureManager.shared.presentPhotoOptions(
    from: self,
    anchor: .view(senderButton)
) { result in
    switch result {
    case .success(let image):
        self.avatarImageView.image = image
    case .cancelled:
        break
    case .failure(let error):
        print("Capture failed: \(error.localizedDescription)")
    }
}
```

---

## 📖 Detailed Usage

### Direct Camera Capture

Skip the action sheet and open the camera directly:

```swift
// Async / Await
let result = await PhotoCaptureManager.shared.capturePhoto(from: self)

// Completion Handler
PhotoCaptureManager.shared.capturePhoto(from: self) { result in
    // Handle result
}
```

### Direct Photo Library Picking

Open the photo picker directly:

```swift
// Async / Await
let result = await PhotoCaptureManager.shared.pickPhoto(from: self)

// Completion Handler
PhotoCaptureManager.shared.pickPhoto(from: self) { result in
    // Handle result
}
```

### iPad Popover Anchoring

Avoid iPad popover crashes and misplacement by providing an anchor:

```swift
// Anchor to a UIView
let result = await PhotoCaptureManager.shared.presentPhotoOptions(
    from: self,
    anchor: .view(button, sourceRect: button.bounds)
)

// Anchor to a UIBarButtonItem
let result = await PhotoCaptureManager.shared.presentPhotoOptions(
    from: self,
    anchor: .barButtonItem(navigationItem.rightBarButtonItem!)
)
```

### JPEG Conversion Utility

Convert captured `UIImage` instances to compressed JPEG `Data` using the configured quality:

```swift
case .success(let image):
    if let data = PhotoCaptureManager.shared.jpegData(from: image) {
        uploadAvatar(data)
    }
```

### Loading Indicator

After the user picks a photo, the picker closes before the image finishes loading (it may have to be downloaded from iCloud). Use `imageLoadingHandler` to show progress meanwhile:

```swift
PhotoCaptureManager.shared.imageLoadingHandler = { [weak self] isLoading in
    isLoading ? self?.spinner.startAnimating() : self?.spinner.stopAnimating()
}
```

### Permission Denied

When camera or (on iOS 13) photo library access is denied, an alert offers a Settings deep-link. For the camera it can also offer the photo library instead (see `promptForPhotoLibraryIfCameraDenied`). Tapping **Open Settings** or **Cancel** in that alert finishes with `.failure(.permissionDenied(source:))`.

---

## ⚙️ Configuration & Localization

Customize settings at app launch (e.g., in `AppDelegate` or `@main` App struct):

```swift
var config = PhotoCaptureConfiguration()

// Behavior & Editing
config.promptForPhotoLibraryIfCameraDenied = true
config.allowsEditing = false
config.preferredCameraDevice = .front
config.imageCompressionQuality = 0.85
config.actionTintColor = .systemIndigo

// Localization / Custom Text
config.strings.selectPhotoTitle = NSLocalizedString("select_photo", comment: "")
config.strings.takePhotoAction = NSLocalizedString("take_photo", comment: "")
config.strings.chooseFromLibraryAction = NSLocalizedString("choose_library", comment: "")

PhotoCaptureManager.shared.configuration = config
```

### Configuration Options

| Property | Type | Default | Description |
|:---|:---|:---|:---|
| `promptForPhotoLibraryIfCameraDenied` | `Bool` | `true` | Offers photo library fallback when camera access is denied. |
| `allowsEditing` | `Bool` | `false` | Enables built-in cropping UI for camera & iOS 13 picker. |
| `preferredCameraDevice` | `CameraDevice` | `.rear` | Default camera device (`.rear` or `.front`). |
| `imageCompressionQuality` | `CGFloat` | `0.9` | Compression quality for `jpegData(from:)`. |
| `actionTintColor` | `UIColor` | `.systemBlue` | Tint color for alert and action sheet buttons. |
| `strings` | `PhotoCaptureStrings` | (English) | Struct containing all localizable UI strings. |

---

## 🛡 Error Handling

`PhotoCaptureError` provides localized error descriptions:

```swift
switch error {
case .cameraUnavailable:
    print("Device has no camera (e.g. iOS Simulator)")
case .permissionDenied(let source):
    print("Access denied for \(source)")
case .permissionRestricted:
    print("Device restricted by parental controls / MDM")
case .imageExtractionFailed:
    print("Selected item could not be converted to UIImage")
case .requestAlreadyInProgress:
    print("Another capture request is currently active")
case .presentationFailed:
    print("The presenting view controller is off-screen or already presenting something")
case .unknown(let error):
    print("Underlying system or item provider error: \(error)")
}
```

---

## 🧪 Running Tests

The package depends on UIKit, so `swift test` on macOS won't work. Run the tests on an iOS Simulator instead, replacing the device name with one installed on your Mac (`xcrun simctl list devices available`):

```bash
xcodebuild test -scheme PhotoCaptureManager -destination 'platform=iOS Simulator,name=iPhone 16'
```

---

## 📄 License

`PhotoCaptureManager` is released under the **MIT License**. See [LICENSE](LICENSE) for details.
