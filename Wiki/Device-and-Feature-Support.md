# Device and Feature Support

Last reviewed: 11 October 2026.

## Three separate checks

1. **Installable:** The App Store or Mac App Store checks the declared operating-system and coarse hardware requirements.
2. **App supported:** At launch, Encrypted Memories checks the active Metal device with `supportsFamily(.metal3)`.
3. **Feature supported:** Apple Vision and Core ML can report narrower capability limits for individual analysis requests.

Passing the first check does not guarantee the second. Apple does not provide an exact Metal 3 App Store capability key.

## Supported app baseline

| Platform | Minimum OS | Supported hardware baseline |
|---|---:|---|
| iPhone | iOS 26.0 | A14-class or later hardware whose GPU reports Metal 3. |
| iPad | iPadOS 26.0 | A14 or later, or M1 or later, when the GPU reports Metal 3. |
| Mac | macOS 26.0 | Apple silicon M1 or later, plus selected Intel/AMD Macs whose active GPU reports Metal 3. |

The runtime check is authoritative. A Mac model name alone is not sufficient because some Macs support different GPUs.

## Known gaps in store filtering

- iOS and iPadOS declare `arm64`, general `metal`, and Apple’s A12 minimum-performance capability. None means Metal 3 exactly.
- A device can therefore pass the store checks but fail the exact Metal 3 runtime check.
- The Mac App Store has an operating-system floor and architecture selection, but no GPU-family filter.
- Making the Mac app Apple-silicon-only would exclude Metal 3-capable Intel Macs, so Encrypted Memories remains universal.
- The iPhone/iPad app is not offered as an iOS-on-Mac, Mac Catalyst, or Apple Vision app. The native Mac app is used on macOS.

Unsupported hardware receives a localized in-app explanation before the main library interface appears.

## Feature matrix

| Feature | Every supported app device | Additional requirement or behavior |
|---|:---:|---|
| Library, Metal timeline, albums, viewer, map, trash, cache | Yes | Requires the app baseline above. |
| Apple Photos library backup | Yes | Requires Photos permission. Background execution is scheduled by the operating system and is not continuous. Backups use cellular data only when **Use Cellular Data** is on. |
| Folder backup | Mac only | Requires access to a user-selected folder. |
| Album sync | Yes | Requires Photos permission and selected local albums. |
| Duplicates and Merge All | Yes | Merged copies move to Recently Deleted. |
| Map and Places, Remove location when sharing | Yes | Switches in Settings under **Privacy**. |
| Blur App Preview | iPhone and iPad | The switch exists only on iPhone and iPad. |
| OCR and document-text indexing | Usually | Apple Vision support is checked at runtime. The visible Text scope appears only when its local index is available. |
| Smart Search model | Model-dependent | Core ML can use CPU, GPU, or Neural Engine. A compatible signed catalog model and enough free space for its download must be available. |
| Neural Engine | No | It is not a requirement for the app or generic Apple Vision search requests. |

Encrypted Memories does not use VisionKit’s live Data Scanner as an app requirement. Apple documents a Neural Engine requirement for that separate component, not for Apple Vision as a whole.

## Apple references

- [Metal 3 GPU family](https://developer.apple.com/documentation/metal/mtlgpufamily/metal3)
- [Detecting Metal features](https://developer.apple.com/documentation/metal/detecting-gpu-features-and-metal-software-versions)
- [Required device capabilities](https://developer.apple.com/documentation/bundleresources/information-property-list/uirequireddevicecapabilities)
- [Vision request compute devices](https://developer.apple.com/documentation/vision/visionrequest/supportedcomputestagedevices)
- [Core ML compute units](https://developer.apple.com/documentation/coreml/mlcomputeunits)
- [Mac models compatible with macOS Tahoe 26](https://support.apple.com/en-gb/122867)

If the app shows the unsupported-device screen on hardware that you believe meets this table, file a reproducible bug with the exact Mac model or iPhone/iPad model and OS version. Do not include account data.
