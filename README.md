# PhotoCaptureManager

A production-ready Swift singleton for taking photos with the camera or picking from the photo library. Handles all permission states, graceful degradation, and Settings deep-linking out of the box.

---

## Features

- **Single entry point** — one call presents a Camera / Library action sheet
- **Full permission lifecycle** — handles `.notDetermined`, `.denied`, `.restricted`, and `.limited` (iOS 14+)
- **Graceful camera fallback** — when camera permission is denied, optionally prompts users to pick from the photo library before offering a Settings deep-link
- **PHPickerViewController** on iOS 14+ (no library permission needed for picking)
- **UIImagePickerController** fallback for iOS 13
- **Configurable** — editing, tint colour, compression quality, fallback behaviour
- **Completion on main thread** — safe to update UI directly in the callback
- **iPad safe** — handles popover anchor correctly
- **Interactive-dismiss safe** — swipe-to-dismiss (iOS 13 library fallback) and tap-outside-popover (iPad action sheet) both resolve the completion instead of hanging
- **Concurrency guard** — a second request while one is in flight fails fast instead of silently stranding the first caller
- **Zero third-party dependencies**

---

## Requirements

| Item | Requirement |
|------|-------------|
| iOS | 13.0+ (uses `PHPickerViewController` automatically on iOS 14+; falls back to `UIImagePickerController` for library picking on iOS 13) |
| Swift | 5.7+ |
| Xcode | 14+ |
| Frameworks | `UIKit`, `AVFoundation`, `Photos`, `PhotosUI` |

---

## Installation

### Manual

Copy `PhotoCaptureManager.swift` into your Xcode project. No additional setup needed.

### Swift Package Manager

Not yet published as a package. Copy the file directly until a package manifest is added.

---

## Info.plist — Required Keys

```xml
<!-- Required for camera capture -->
<key>NSCameraUsageDescription</key>
<string>We need camera access to let you take profile photos.</string>

<!-- Required only if you save captured photos back to the camera roll,
     e.g. via UIImageWriteToSavedPhotosAlbum -->
<key>NSPhotoLibraryAddUsageDescription</key>
<string>We need permission to save your captured photo to your photo library.</string>
```

`NSPhotoLibraryUsageDescription` is **not required** for the default iOS 14+ flow. `PHPickerViewController` runs out-of-process in a system extension and never grants the host app read access to the library — the user just hands over the one photo they picked. Only add this key if you need to support **iOS 13**, where the fallback `UIImagePickerController` does require classic library read permission:

```xml
<!-- Only needed if your app supports iOS 13 -->
<key>NSPhotoLibraryUsageDescription</key>
<string>We need photo library access so you can choose an existing photo.</string>
```

> **Tip:** Write user-facing descriptions that clearly explain the benefit. Apple rejects apps with vague strings like "We need access." Also avoid requesting `NSPhotoLibraryUsageDescription` if you don't support iOS 13 — asking for permission you never actually check is itself a red flag in App Review and unnecessarily alarms privacy-conscious users.

---

## Quick Start

```swift
import UIKit

class ProfileViewController: UIViewController {

    @IBAction func changePhotoTapped(_ sender: UIButton) {
        PhotoCaptureManager.shared.presentPhotoOptions(from: self, sourceView: sender) { result in
            switch result {
            case .success(let image):
                self.profileImageView.image = image

            case .cancelled:
                break   // user dismissed — do nothing

            case .failure(let error):
                self.showError(error.localizedDescription)
            }
        }
    }
}
```

The completion block is **always called on the main thread**, so you can update UI directly.

---

## API Reference

### `presentPhotoOptions(from:sourceView:completion:)`

Presents an action sheet with **Take Photo**, **Choose from Library**, and **Cancel**. If the camera is unavailable (e.g., simulator), the Camera option is hidden automatically.

```swift
PhotoCaptureManager.shared.presentPhotoOptions(
    from: viewController,       // UIViewController to present from
    sourceView: senderButton,   // Optional: UIView anchor for iPad popovers
    completion: { result in … }
)
```

### `capturePhoto(from:completion:)`

Skips the action sheet and goes straight to the camera, requesting permission first.

```swift
PhotoCaptureManager.shared.capturePhoto(from: self) { result in … }
```

### `pickPhoto(from:completion:)`

Skips the action sheet and opens the photo library picker directly.

```swift
PhotoCaptureManager.shared.pickPhoto(from: self) { result in … }
```

### `jpegData(from:)`

The manager always hands back a `UIImage`. If you need `Data` — for an upload or writing to disk — convert it using the configured compression quality:

```swift
case .success(let image):
    guard let data = PhotoCaptureManager.shared.jpegData(from: image) else { return }
    uploadPhoto(data)
```

---

## Configuration

Mutate `PhotoCaptureManager.shared.configuration` (ideally once, in `AppDelegate` or app startup):

```swift
var config = PhotoCaptureConfiguration()
config.promptForPhotoLibraryIfCameraDenied = true   // default: true
config.allowsEditing                        = false  // default: false
config.imageCompressionQuality             = 0.9    // default: 0.9
config.actionTintColor                      = .systemPurple

PhotoCaptureManager.shared.configuration = config
```

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `promptForPhotoLibraryIfCameraDenied` | `Bool` | `true` | When camera is denied, show a "Choose from Library" option before Settings link |
| `allowsEditing` | `Bool` | `false` | Allow crop/edit after capture. Applies to the camera and the iOS 13 library fallback (both `UIImagePickerController`). Has no effect on the iOS 14+ `PHPickerViewController` library flow, which has no built-in crop UI. |
| `imageCompressionQuality` | `CGFloat` | `0.9` | JPEG quality used by `jpegData(from:)`; not applied automatically |
| `actionTintColor` | `UIColor` | `.systemBlue` | Tint colour for all alert/action-sheet buttons |

---

## Permission Flow Diagrams

### Camera Flow

```
capturePhoto() / "Take Photo" tapped
        │
        ▼
 AVCaptureDevice.authorizationStatus
        │
   ┌────┴────────────────────────────────────────┐
   │                                             │
.authorized                              .notDetermined
   │                                             │
presentCamera()               requestAccess(for: .video)
                                        │
                              ┌─────────┴─────────┐
                           granted             denied
                              │                   │
                         presentCamera()  handleCameraPermissionDenied()
                                                  │
                              ┌───────────────────┤
                              │                   │
               promptForPhotoLibrary=true   promptForPhotoLibrary=false
                              │                   │
               Alert: Choose Library      Alert: Open Settings
                   | Open Settings            | Cancel → .failure
                   | Cancel → .cancelled
```

### Photo Library Flow

**iOS 14+ (default path)** — no permission check at all:

```
pickPhoto() / "Choose from Library" tapped
        │
        ▼
presentPhotoLibraryPicker()  →  PHPickerViewController presented directly
```

`PHPickerViewController` runs out-of-process, so the app never needs — and never requests — read access to the library. There is no permission alert in this path.

**iOS 13 fallback only** — classic permission flow, since `UIImagePickerController` does require library read access:

```
pickPhoto() / "Choose from Library" tapped  (iOS 13 device)
        │
        ▼
 PHPhotoLibrary.authorizationStatus()
        │
   ┌────┴──────────────────┐────────────────────┐
   │                       │                    │
.authorized / .limited  .notDetermined        .denied
   │                       │                    │
presentPicker()     requestAuthorization()  handlePhotoLibraryDenied()
                           │                    │
                   ┌───────┴───────┐        Alert: Open Settings | Cancel
              granted            denied
                   │                │
            presentPicker()  handlePhotoLibraryDenied()
```

---

## Alert Scenarios

### 1. Camera Permission Denied — Library Fallback Enabled (default)

> **"Camera Access Denied"**
> Camera permission is required to take photos. You can choose a photo from your library instead, or enable camera access in Settings.
>
> [Choose from Library]   [Open Settings]   [Cancel]

### 2. Camera Permission Denied — Library Fallback Disabled

> **"Camera Access Denied"**
> Please enable camera access in Settings to take photos.
>
> [Open Settings]   [Cancel]

### 3. Photo Library Permission Denied (iOS 13 only)

On iOS 14+, `PHPickerViewController` never needs permission, so this alert can't occur there. It only appears on iOS 13 devices using the `UIImagePickerController` fallback:

> **"Photo Library Access Denied"**
> Please enable photo library access in Settings to choose a photo.
>
> [Open Settings]   [Cancel]

---

## Handling Results

```swift
PhotoCaptureManager.shared.presentPhotoOptions(from: self) { result in
    switch result {
    case .success(let image):
        // `image` is a UIImage — update your UI
        self.imageView.image = image

    case .cancelled:
        // User tapped Cancel or dismissed — no action needed
        break

    case .failure(let error):
        switch error {
        case .cameraUnavailable:
            print("No camera on this device")
        case .permissionDenied(let source):
            print("\(source) permission denied")
        case .permissionRestricted:
            print("Media access restricted (parental controls?)")
        case .imageExtractionFailed:
            print("Could not decode the selected image")
        case .requestAlreadyInProgress:
            print("Another capture request is already running — wait for it to finish")
        case .unknown(let underlying):
            print("Unexpected error: \(underlying)")
        }
    }
}
```

---

## Notes & Edge Cases

### Simulator
`UIImagePickerController.isSourceTypeAvailable(.camera)` returns `false` in the simulator. The **Take Photo** option is hidden automatically; only **Choose from Library** appears.

### iPad Popovers
Pass `sourceView` to `presentPhotoOptions(from:sourceView:)` so the action sheet anchors correctly. Without it, the manager centres the popover over the presenting view — valid but less polished.

### iOS 14 Limited Photo Access
`PHPickerViewController` does not require library permission; the user is always shown the picker. If `PHAuthorizationStatus` is `.limited`, the picker still works — the user simply sees only their selected photos.

### Thread Safety
All completion callbacks are dispatched on the **main queue**.

### Concurrent Requests
If `presentPhotoOptions`, `capturePhoto`, or `pickPhoto` is called while a previous request from the same manager is still in flight, the **new** call's completion fires immediately with `.failure(.requestAlreadyInProgress)` and the original request is left untouched. This prevents the older failure mode where a second call would silently overwrite the first call's completion handler, leaving the original caller waiting forever.

### Interactive Dismissal (Swipe / Tap-Outside)
Two UI surfaces in this manager can be dismissed by the user without tapping any button, and both are handled so the completion still fires with `.cancelled`:
- **iPad action sheet** — renders as a popover; tapping outside it dismisses without picking an option.
- **iOS 13 photo library fallback** — `UIImagePickerController` presented as a sheet supports swipe-down-to-dismiss, which does **not** invoke `imagePickerControllerDidCancel`.

`PHPickerViewController` (iOS 14+) doesn't need this handling — Apple guarantees its delegate method fires exactly once, with an empty result array, even when the user swipes it away.

### PHPickerConfiguration and Permissions
This manager initializes `PHPickerConfiguration()` with no `photoLibrary:` argument, since it never reads `PHPickerResult.assetIdentifier`. Note that passing `PHPickerConfiguration(photoLibrary: .shared())` instead would **not** introduce a permission prompt — that parameter only affects whether `assetIdentifier` comes back non-nil for later `PHAsset` lookups. `PHPickerViewController` runs out-of-process and shows the user's library regardless of which initializer is used or what the host app's own authorization status is.

### Saving Captured Photos to Camera Roll
`PhotoCaptureManager` returns the captured `UIImage`; it does **not** save it to the camera roll automatically. To save:

```swift
case .success(let image):
    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
```

This requires `NSPhotoLibraryAddUsageDescription` in `Info.plist`.

---

## License

MIT — free to use, modify, and distribute.
