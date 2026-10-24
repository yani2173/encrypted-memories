import XCTest

final class ProjectHygieneTests: XCTestCase {
    /// Returns the repository root, five levels above this test file.
    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private var appDir: URL { repoRoot.appendingPathComponent("App") }
    private var uploadCoreDir: URL {
        repoRoot.appendingPathComponent("Packages/EncryptedMemoriesKit/Sources/UploadCore")
    }

    private func appSourceFiles() -> [URL] {
        sourceFiles(in: appDir)
    }

    private func sourceFiles(in directory: URL) -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { ["swift", "m", "h", "mm"].contains($0.pathExtension.lowercased()) }
    }

    private func targetBlock(named target: String, in projectYML: String) -> String {
        guard let start = projectYML.range(of: "  \(target):")?.lowerBound else { return "" }
        let tail = projectYML[start...]
        guard let next = tail.range(of: "\n  [A-Za-z0-9_]+:", options: .regularExpression)?.lowerBound,
            next != tail.startIndex
        else {
            return String(tail)
        }
        return String(tail[..<next])
    }

    /// The offline account must never enter the distributed archive.
    func testUpgradeFixtureFlagIsAbsentFromArchiveConfiguration() throws {
        let marker = "ENCRYPTED_MEMORIES_UPGRADE_TEST"
        for path in ["project.yml", "Packages/EncryptedMemoriesKit/Package.swift"] {
            let contents = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(contents.contains(marker), "\(path) enables an offline entry in the shipping build")
        }
        let workflow = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/workflows/testflight-internal.yml"), encoding: .utf8)
        // The isolated builder supplies the flag. Workflow, job, and step environments must not inherit it.
        XCTAssertFalse(workflow.contains(marker), "The release workflow enables an offline entry in the shipping build")
    }

    // Production app target uses no known private Apple API or framework.
    func testNoPrivateAppleAPIInProductionTarget() {
        let banned = ["PPApplePrivate", "loadPrivateFrameworks", "filterWithType:", "CAFilterClassNames"]
        for url in appSourceFiles() {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for marker in banned {
                XCTAssertFalse(
                    text.contains(marker),
                    "\(url.lastPathComponent) contains private-API marker “\(marker)”")
            }
        }
    }

    func testEncryptedMemoriesBundleIdentifiersMatchReleaseConfiguration() throws {
        let project = try String(
            contentsOf: repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        XCTAssertEqual(
            project.components(separatedBy: "PRODUCT_BUNDLE_IDENTIFIER: at.oncloud.encryptedmemories\n").count - 1,
            2,
            "iOS/iPadOS and macOS must use the same universal-purchase bundle identifier"
        )
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER: at.oncloud.encryptedmemories.tests"))
        XCTAssertFalse(
            project.contains("PRODUCT_BUNDLE_IDENTIFIER: at.oncloud.encryptedmemories.marketing-ui-tests"),
            "The private marketing UI test target must not be present in the public project"
        )

        let macTarget = targetBlock(named: "EncryptedMemories", in: project)
        XCTAssertTrue(macTarget.contains("INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO"))

        let mobileInfoData = try Data(
            contentsOf: repoRoot.appendingPathComponent("iOSApp/Info.plist")
        )
        let mobileInfo = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: mobileInfoData, format: nil) as? [String: Any]
        )
        XCTAssertEqual(mobileInfo["ITSAppUsesNonExemptEncryption"] as? Bool, false)
    }

    func testAppleTargetsRequireOS26OrNewer() throws {
        let projectYML = try String(
            contentsOf: repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        for target in [
            "EncryptedMemories",
            "EncryptedMemoriesMobile",
            "EncryptedMemoriesMobileTests",
            "EncryptedMemoriesMobileUITests",
        ] {
            let block = targetBlock(named: target, in: projectYML)
            XCTAssertFalse(block.isEmpty, "project.yml must define \(target)")
            XCTAssertTrue(block.contains("deploymentTarget: \"26.0\""), "\(target) must require OS 26.0+")
        }

        let manifest = try String(
            contentsOf: repoRoot.appendingPathComponent("Packages/EncryptedMemoriesKit/Package.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(manifest.contains("platforms: [.macOS(\"26.0\"), .iOS(\"26.0\")]"))
    }

    /// The Mac grid adds this type to dragged photos (`PhotoDragReference.typeIdentifier`); the sidebar accepts it
    /// only when the app exports it, so a missing declaration silently disables dropping photos on albums.
    func testMacAppExportsThePhotoDragReferenceType() throws {
        let plist = try String(contentsOf: repoRoot.appendingPathComponent("App/Info.plist"), encoding: .utf8)
        XCTAssertTrue(plist.contains("<key>UTExportedTypeDeclarations</key>"))
        XCTAssertTrue(plist.contains("<string>at.oncloud.encryptedmemories.photo-reference</string>"))
    }

    /// The package gates use only the pinned package versions, and CI stops on an unexpected Xcode.
    func testBuildGatesStopOnPackageDriftAndOnAnotherXcode() throws {
        func read(_ path: String) throws -> String {
            try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
        }
        for script in ["scripts/verify-tests.sh", "scripts/verify-universal-core.sh"] {
            let invocations = try read(script).components(separatedBy: "xcrun swift test").dropFirst()
            XCTAssertFalse(invocations.isEmpty, script)
            for invocation in invocations {
                // The command ends at the first line without a continuation backslash.
                var lines: [String] = []
                for line in invocation.components(separatedBy: "\n") {
                    lines.append(line)
                    if !line.hasSuffix("\\") { break }
                }
                let command = lines.joined(separator: "\n")
                XCTAssertTrue(command.contains("--force-resolved-versions"), "\(script): \(command)")
            }
        }
        let action = try read(".github/actions/prepare-apple-build/action.yml")
        XCTAssertTrue(action.contains("--force-resolved-versions \\\n          resolve"))
        XCTAssertTrue(action.contains("EXPECTED_XCODE_VERSION: ${{ inputs.xcode-version }}"))
        XCTAssertTrue(action.contains("EXPECTED_XCODE_BUILD: ${{ inputs.xcode-build }}"))
        XCTAssertTrue(action.contains("set -euo pipefail\n        bash .github/scripts/verify_xcode_toolchain.sh"))

        let toolchain = try read(".github/scripts/verify_xcode_toolchain.sh")
        XCTAssertTrue(toolchain.contains("set -euo pipefail"))
        // The action inputs hold the only copy of the pins; an empty or missing value fails.
        XCTAssertTrue(
            toolchain.contains(
                #"[[ -n "${EXPECTED_XCODE_VERSION:-}" && -n "${EXPECTED_XCODE_BUILD:-}" ]] || release_fail toolchain"#
            ))
        XCTAssertTrue(toolchain.contains(#"expected_version="$EXPECTED_XCODE_VERSION""#))
        XCTAssertTrue(toolchain.contains(#"expected_build="$EXPECTED_XCODE_BUILD""#))
        XCTAssertFalse(toolchain.contains("27.1"))
        XCTAssertFalse(toolchain.contains("27A9275"))
        XCTAssertTrue(
            toolchain.contains(
                #"[[ "$xcode_version" == "$expected_version" && "$xcode_build" == "$expected_build" ]] || release_fail toolchain"#
            ))
    }

    func testProtonAppVersionHeaderInputsReachEveryShippedApp() throws {
        func read(_ path: String) throws -> String {
            try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
        }
        let project = try read("project.yml")

        // x-pm-appversion is built from these bundle keys; both platforms must carry them.
        for plist in ["iOSApp/Info.plist", "App/Info.plist"] {
            let contents = try read(plist)
            XCTAssertTrue(contents.contains("<key>EncryptedMemoriesBuildCommit</key>"), plist)
            XCTAssertTrue(
                contents.contains(
                    "<key>EncryptedMemoriesProtonChannel</key>\n\t<string>$(ENCRYPTED_MEMORIES_PROTON_CHANNEL)</string>"
                ),
                plist
            )
        }
        XCTAssertTrue(project.contains("INFOPLIST_FILE: App/Info.plist"))
        XCTAssertTrue(project.contains("ENCRYPTED_MEMORIES_PROTON_CHANNEL: alpha"))
    }

    /// Background execution stays limited to BGProcessingTask work with the two identifiers the apps register.
    /// App Review rejects keep-alive modes, and an undeclared identifier fails registration only at runtime.
    func testIOSBackgroundTaskDeclarationsStayMinimal() throws {
        let infoData = try Data(contentsOf: repoRoot.appendingPathComponent("iOSApp/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        )
        XCTAssertNotNil(info["NSPhotoLibraryUsageDescription"], "photo backup needs a usage description on iOS")
        XCTAssertEqual(
            info["BGTaskSchedulerPermittedIdentifiers"] as? [String],
            [
                "at.oncloud.encryptedmemories.photo-backup.processing",
                "at.oncloud.encryptedmemories.smart-search.processing",
            ])
        XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["processing"], "no keep-alive background mode")
    }

    func testPhotoLibraryBackupAdapterStaysUIAndSDKFree() {
        let adapterDir = repoRoot.appendingPathComponent(
            "Packages/EncryptedMemoriesKit/Sources/PhotoLibraryBackupAdapter")
        let files = sourceFiles(in: adapterDir)
        XCTAssertFalse(files.isEmpty, "the PhotoKit adapter target must exist")
        for url in files {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let importLines = Set(
                text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("import ") }
            )
            // Photos is this target's purpose; UI frameworks, OS scheduling, and the SDK are not.
            for forbidden in [
                "import UIKit",
                "import AppKit",
                "import SwiftUI",
                "import BackgroundTasks",
                "import ProtonDriveSDK",
                "import ProtonCore",
            ] {
                XCTAssertFalse(
                    importLines.contains(forbidden),
                    "\(url.lastPathComponent) must keep \(forbidden) out of the shared PhotoKit adapter")
            }
        }
    }

    func testAlbumSyncCoreStaysPureSwift() {
        let coreDir = repoRoot.appendingPathComponent("Packages/EncryptedMemoriesKit/Sources/AlbumSyncCore")
        let files = sourceFiles(in: coreDir)
        XCTAssertFalse(files.isEmpty, "the AlbumSyncCore target must exist")
        for url in files {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let importLines = Set(
                text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("import ") }
            )
            // The sync engine is universal: platform frameworks, PhotoKit, and the SDK live in
            // adapters only.
            for forbidden in [
                "import UIKit",
                "import AppKit",
                "import SwiftUI",
                "import Photos",
                "import PhotosUI",
                "import BackgroundTasks",
                "import ProtonDriveSDK",
                "import ProtonCore",
            ] {
                XCTAssertFalse(
                    importLines.contains(forbidden),
                    "\(url.lastPathComponent) must keep \(forbidden) out of AlbumSyncCore")
            }
        }
    }

    func testMobileAppStoreDeviceCapabilitiesDeclareRendererFloor() throws {
        let infoData = try Data(contentsOf: repoRoot.appendingPathComponent("iOSApp/Info.plist"))
        let info = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any]
        )
        let capabilities = try XCTUnwrap(info["UIRequiredDeviceCapabilities"] as? [String])

        XCTAssertTrue(capabilities.contains("arm64"))
        XCTAssertTrue(capabilities.contains("metal"))
        XCTAssertTrue(
            capabilities.contains("iphone-ipad-minimum-performance-a12"),
            "App Store distribution must exclude devices below the closest available hardware floor"
        )

        let project = try String(
            contentsOf: repoRoot.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        XCTAssertTrue(project.contains("SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO"))
        XCTAssertTrue(project.contains("SUPPORTS_XR_DESIGNED_FOR_IPHONE_IPAD: NO"))
        XCTAssertTrue(project.contains("INFOPLIST_KEY_NSHumanReadableCopyright:"))
    }

    func testUploadCoreStaysPlatformAndSDKAgnostic() {
        for url in sourceFiles(in: uploadCoreDir) {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let importLines = Set(
                text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("import ") }
            )
            for forbidden in [
                "import AppKit",
                "import UIKit",
                "import Photos",
                "import PhotosUI",
                "import BackgroundTasks",
                "import ProtonDriveSDK",
                "import ProtonCore",
            ] {
                XCTAssertFalse(
                    importLines.contains(forbidden),
                    "\(url.lastPathComponent) must keep platform/API adapters out of UploadCore")
            }
        }
    }

    func testMacAppEntitlementsStaySandboxedAndMinimal() throws {
        let entitlementsURL = repoRoot.appendingPathComponent("App/EncryptedMemories.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            "macOS entitlements must remain a dictionary plist"
        )

        for required in [
            "com.apple.security.app-sandbox",
            "com.apple.security.network.client",
            "com.apple.security.files.user-selected.read-write",
            // Folder backup persists the user's chosen folders as security-scoped bookmarks.
            "com.apple.security.files.bookmarks.app-scope",
            // Photos-library backup reads originals through PhotoKit.
            "com.apple.security.personal-information.photos-library",
        ] {
            XCTAssertEqual(plist[required] as? Bool, true, "missing required entitlement \(required)")
        }

        for forbidden in [
            "com.apple.security.cs.disable-library-validation",
            "com.apple.security.cs.allow-unsigned-executable-memory",
            "com.apple.security.cs.allow-jit",
            "com.apple.security.files.downloads.read-write",
            "com.apple.security.files.pictures.read-write",
            "com.apple.security.temporary-exception.files.absolute-path.read-write",
            "com.apple.security.temporary-exception.files.home-relative-path.read-write",
        ] {
            XCTAssertNil(plist[forbidden], "entitlement \(forbidden) must not be present without a documented need")
        }
    }

    func testPlatformAppsShipPrivacyManifestsForRequiredReasonAPIs() throws {
        let relativePath = "Shared/PrivacyInfo.xcprivacy"
        let data = try Data(contentsOf: repoRoot.appendingPathComponent(relativePath))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            "\(relativePath) must be a dictionary plist"
        )

        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false, "\(relativePath) must not declare tracking")
        let collectedData = try XCTUnwrap(plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let collectedDataByType = Dictionary(
            uniqueKeysWithValues: collectedData.compactMap { entry -> (String, [String: Any])? in
                guard let type = entry["NSPrivacyCollectedDataType"] as? String else { return nil }
                return (type, entry)
            }
        )
        XCTAssertEqual(
            Set(collectedDataByType.keys),
            [
                "NSPrivacyCollectedDataTypeCrashData",
                "NSPrivacyCollectedDataTypeOtherDiagnosticData",
            ]
        )
        for (type, entry) in collectedDataByType {
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeLinked"] as? Bool, false, "\(type) must not be linked")
            XCTAssertEqual(entry["NSPrivacyCollectedDataTypeTracking"] as? Bool, false, "\(type) must not track")
            XCTAssertEqual(
                entry["NSPrivacyCollectedDataTypePurposes"] as? [String],
                ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
            )
        }

        let apiTypes = try XCTUnwrap(
            plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
            "\(relativePath) must declare required-reason API use"
        )
        let reasonsByType = Dictionary(
            uniqueKeysWithValues: apiTypes.compactMap { entry -> (String, Set<String>)? in
                guard let type = entry["NSPrivacyAccessedAPIType"] as? String,
                    let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String]
                else { return nil }
                return (type, Set(reasons))
            }
        )

        XCTAssertEqual(reasonsByType["NSPrivacyAccessedAPICategoryUserDefaults"], ["CA92.1"])
        XCTAssertEqual(reasonsByType["NSPrivacyAccessedAPICategoryDiskSpace"], ["E174.1"])
        XCTAssertEqual(
            reasonsByType["NSPrivacyAccessedAPICategoryFileTimestamp"],
            ["C617.1", "3B52.1"]
        )

        let projectYML = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertEqual(
            projectYML.components(separatedBy: "- Shared/PrivacyInfo.xcprivacy").count - 1,
            2,
            "macOS and iOS/iPadOS targets must embed the one shared privacy manifest"
        )
    }

    /// What one key pattern found in the scanned sources: its call sites, the keys it checked, and the keys that
    /// the catalog lacks.
    private struct KeyScan {
        var sites = 0
        var checked = 0
        var missing: [String] = []

        mutating func add(_ other: KeyScan) {
            sites += other.sites
            checked += other.checked
            missing += other.missing
        }
    }

    /// `L10n.string("key")`, with the key in capture group 1.
    private func literalKeyPattern() throws -> NSRegularExpression {
        try NSRegularExpression(pattern: #"L10n\.string\(\s*"((?:[^"\\]|\\.)*)""#)
    }

    /// `L10n.string(condition ? "a" : "b")`, with the keys in capture groups 1 and 2. The condition holds no string
    /// literal, no closing parenthesis and no line break, so a call with another argument followed by a ternary on
    /// the same line is not read as a ternary key.
    private func ternaryKeyPattern() throws -> NSRegularExpression {
        let key = #""((?:[^"\\]|\\.)*)""#
        return try NSRegularExpression(pattern: #"L10n\.string\(\s*[^"\n)]*?\?\s*"# + key + #"\s*:\s*"# + key)
    }

    /// Checks every key that `pattern` captures in `text` against `known`. This is the one place that holds the scan.
    private func scanKeys(
        in text: String, label: String, pattern: NSRegularExpression, known: Set<String>
    ) -> KeyScan {
        var scan = KeyScan()
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            scan.sites += 1
            for group in 1..<match.numberOfRanges {
                guard let keyRange = Range(match.range(at: group), in: text) else { continue }
                let key = String(text[keyRange])
                // An interpolated key resolves to a format key such as "a11y.grid.position %lld %lld".
                guard !key.contains("\\(") else { continue }
                scan.checked += 1
                if !known.contains(key) { scan.missing.append("\(label): \(key)") }
            }
        }
        return scan
    }

    private func packageCatalogKeys() throws -> Set<String> {
        let data = try Data(
            contentsOf: repoRoot.appendingPathComponent(
                "Packages/EncryptedMemoriesKit/Sources/PhotosCore/Resources/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(try XCTUnwrap(catalog["strings"] as? [String: Any]).keys)
    }

    /// `L10n.string` reads the package catalog only. A literal key that this catalog lacks renders as the raw
    /// key, for example as a VoiceOver label, even when an app catalog holds it.
    ///
    /// The scan reads `L10n.string("key")` and `L10n.string(condition ? "a" : "b")`. Known blind spots, each
    /// unchecked here: interpolated keys, `L10n.string(dynamicKey:)`, a key held in a variable or returned by a
    /// function (`BackupStatus.titleKey`), `String(localized:)` and SwiftUI `Text("key")` reads (without a bundle
    /// they read the app catalog, not the package catalog), a nested ternary, and a ternary whose condition holds a string literal, a call or a line break.
    func testEveryLiteralLocalizationKeyHasACatalogEntry() throws {
        let known = try packageCatalogKeys()
        let patterns = (literal: try literalKeyPattern(), ternary: try ternaryKeyPattern())
        var literal = KeyScan()
        var ternary = KeyScan()
        for root in ["App", "iOSApp", "Packages/EncryptedMemoriesKit/Sources"] {
            for url in sourceFiles(in: repoRoot.appendingPathComponent(root)) where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let label = url.lastPathComponent
                literal.add(scanKeys(in: text, label: label, pattern: patterns.literal, known: known))
                ternary.add(scanKeys(in: text, label: label, pattern: patterns.ternary, known: known))
            }
        }
        XCTAssertGreaterThan(literal.checked, 100, "the scan must find the literal keys")
        // The four ternary calls of today: AlbumActionCoordinator, UIKitTimelineGridHostAccessibility (two) and
        // MobileViewerFilmstrip. A lower bound, so that a new call does not break the test.
        XCTAssertGreaterThanOrEqual(ternary.sites, 4, "the scan must find the ternary calls")
        XCTAssertGreaterThanOrEqual(ternary.checked, 8, "both branches of a ternary are keys")
        XCTAssertEqual(literal.missing + ternary.missing, [], "literal keys without a catalog entry")
    }

    func testTheKeyScanChecksBothBranchesOfATernary() throws {
        let known: Set<String> = ["a11y.video", "a11y.photo"]
        let pattern = try ternaryKeyPattern()

        let broken = #"""
            let kind = L10n.string(item.isVideo ? "a11y.video" : "a11y.phto")
            """#
        let brokenScan = scanKeys(in: broken, label: "fixture", pattern: pattern, known: known)
        XCTAssertEqual(brokenScan.missing, ["fixture: a11y.phto"])
        XCTAssertEqual(brokenScan.sites, 1)
        XCTAssertEqual(brokenScan.checked, 2)
        let literalScan = scanKeys(in: broken, label: "fixture", pattern: try literalKeyPattern(), known: known)
        XCTAssertEqual(literalScan.sites, 0, "the literal pattern does not read a ternary")

        let valid = #"""
            let kind = L10n.string(item.isVideo ? "a11y.video" : "a11y.photo")
            let other = L10n.string(item?.isVideo ?? false ? "a11y.photo" : "a11y.video")
            """#
        let validScan = scanKeys(in: valid, label: "fixture", pattern: pattern, known: known)
        XCTAssertEqual(validScan.missing, [])
        XCTAssertEqual(validScan.sites, 2)
        XCTAssertEqual(validScan.checked, 4)

        let interpolated = #"""
            let kind = L10n.string(item.isVideo ? "a11y.video" : "a11y.count \(count)")
            """#
        let interpolatedScan = scanKeys(in: interpolated, label: "fixture", pattern: pattern, known: known)
        XCTAssertEqual(interpolatedScan.missing, [], "an interpolated key stays out of the scan")
        XCTAssertEqual(interpolatedScan.checked, 1)
    }
}
