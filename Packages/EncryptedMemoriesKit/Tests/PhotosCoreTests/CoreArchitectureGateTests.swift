import Foundation
import Synchronization
import XCTest

/// Central architecture gate for universal Core targets.
///
/// Target-local purity tests still exist as focused unit tests, but this file is the
/// shared contract that every universal Core target must pass. Add a target here
/// before treating it as reusable Core.
final class CoreArchitectureGateTests: XCTestCase {
    private struct CoreTargetRule {
        let name: String
        let allowedImports: Set<String>
        let expectedDependencies: Set<String>
        let extraForbiddenTokens: [String]
    }

    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    private var packageManifest: URL {
        packageRoot.appendingPathComponent("Package.swift")
    }

    private var sourcesRoot: URL {
        packageRoot.appendingPathComponent("Sources")
    }

    private var repoRoot: URL {
        packageRoot.deletingLastPathComponent().deletingLastPathComponent()
    }

    private static let coreTargets: [CoreTargetRule] = [
        CoreTargetRule(
            name: "AppleSecurityCore",
            allowedImports: ["Foundation", "Security"],
            expectedDependencies: [],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "PhotosCore",
            // PhotosCore uses CryptoKit for timeline digests, OSLog for instrumentation, and SQLite3 for its app-owned metadata store.
            // Observation drives the shared immutable snapshot owner; it adds no platform UI dependency.
            // ImageIO writes location-free copies of outbound photos on every platform.
            allowedImports: [
                "AVFoundation", "CoreGraphics", "CryptoKit", "Foundation", "ImageIO", "Observation", "OSLog",
                "SQLite3",
            ],
            expectedDependencies: [],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "MediaByteCache",
            allowedImports: ["CryptoKit", "Foundation", "PhotosCore"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: ["CGImage"]
        ),
        CoreTargetRule(
            name: "MediaDecodingCore",
            allowedImports: ["CoreGraphics", "Foundation", "ImageIO"],
            expectedDependencies: [],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "MediaFeedCore",
            // CryptoKit hashes coverage identifiers before they reach disk; it is universal
            // Apple-platform infrastructure, not platform UI or hardware policy.
            allowedImports: ["CryptoKit", "Foundation", "MediaByteCache", "MediaDecodingCore", "PhotosCore"],
            expectedDependencies: ["MediaByteCache", "MediaDecodingCore", "PhotosCore"],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "MediaLocationCore",
            allowedImports: ["CryptoKit", "Foundation", "Observation", "PhotosCore"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: ["MapKit"]
        ),
        CoreTargetRule(
            name: "MediaCacheCore",
            // MediaCacheCore has no Observation dependency; learned dimensions are stored in PhotosCore metadata.
            allowedImports: ["Foundation", "PhotosCore"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "GridCore",
            // QuartzCore is intentionally not allowed: GridCore is pure value geometry
            // that takes injected clocks (never `CACurrentMediaTime`) and uses simd/`CGAffineTransform` (never
            // `CATransform3D`), so it needs no QuartzCore symbol. Excluding QuartzCore structurally closes the
            // render-surface hole where a QuartzCore-sourced `CAMetalDrawable`/`CAMetalLayer`/`CADisplayLink`
            // could otherwise enter Core past both the import allowlist and the token gate. Re-add consciously
            // (with a value-math justification) if a legitimate need ever appears.
            allowedImports: ["CoreGraphics", "simd"],
            expectedDependencies: [],
            // CoreGraphics drawing/surface types - as opposed to the `CGRect`/`CGSize`/`CGPoint`/`CGFloat`
            // value types GridCore legitimately relies on - have no place in pure grid geometry. Scoped to
            // GridCore (not global) because `CGImage` is a legitimate decoded-image type in MediaDecodingCore
            // and MediaFeedCore, so a global ban would wrongly fail those Core targets.
            extraForbiddenTokens: ["CGContext", "CGImage", "CGColorSpace", "CGLayer"]
        ),
        CoreTargetRule(
            name: "UploadCore",
            // UploadCore uses AVFoundation/ImageIO for metadata, CryptoKit for dedupe hashing, and SQLite3 for manifest storage.
            // These dependencies remain platform-neutral so dedupe stays in shared Core.
            allowedImports: [
                "AVFoundation", "CryptoKit", "Foundation", "ImageIO", "Observation", "PhotosCore", "SQLite3",
                "Synchronization",
            ],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "AlbumCore",
            allowedImports: ["Foundation", "PhotosCore"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "AccountStateCore",
            allowedImports: ["Foundation", "PhotosCore"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "DeviceRootCore",
            allowedImports: ["Foundation"],
            expectedDependencies: [],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "TimelineCore",
            // UploadCore: photos that the backup has not uploaded yet are part of the timeline (pending grid).
            // Observation: the shared `@Observable` library model (`TimelineViewModel`) for macOS and iOS.
            allowedImports: [
                "CoreGraphics", "Foundation", "GridCore", "MediaFeedCore", "MediaLocationCore", "Observation",
                "PhotosCore", "UploadCore",
            ],
            expectedDependencies: ["GridCore", "MediaFeedCore", "MediaLocationCore", "PhotosCore", "UploadCore"],
            extraForbiddenTokens: []
        ),
        CoreTargetRule(
            name: "PhotoViewerCore",
            allowedImports: ["AVFoundation", "CoreGraphics", "Foundation", "ImageIO", "Observation", "PhotosCore"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: ["PhotoDiagnostics"]
        ),
        // MLSearchCore: pure Swift, platform-neutral. Owns the ML index model, store protocol,
        // in-memory + SQLite stores, packed vector block, planner, progress, query/result types,
        // and vector-scorer protocol. SQLite3: the system C library backing the persistent
        // embedding store (same allowance as PhotosCore/UploadCore stores). CoreML/Vision/
        // UIKit/AppKit/SwiftUI/Photos/SDK are banned so search and indexing stay in shared Core.
        // CryptoKit: streaming SHA-256 verification of downloaded model artifacts (same
        // universal-crypto allowance as MediaByteCache). Observation: the shared @Observable
        // Smart Search controller both platform Settings surfaces bind to (same allowance as
        // MediaLocationCore).
        CoreTargetRule(
            name: "MLSearchCore",
            allowedImports: ["CryptoKit", "Foundation", "Observation", "PhotosCore", "SQLite3"],
            expectedDependencies: ["PhotosCore"],
            extraForbiddenTokens: ["CoreML", "Vision", "NaturalLanguage", "MLModel"]
        ),
    ]

    private static let forbiddenFrameworkImports: Set<String> = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "MapKit",
        "AVKit",
        // `Metal` itself belongs to renderer/adapter targets; universal Core targets must remain drawable-free.
        "Metal",
        "MetalKit",
    ]

    private static let forbiddenTokens: [String] = [
        "NSImage",
        "UIImage",
        "NSView",
        "UIView",
        "NSWorkspace",
        "NSOpenPanel",
        "UIApplication",
        "NSApplication",
        "MTKView",
        // Ban render-surface and presentation types so universal Core remains drawable-free.
        // Concrete names also catch qualified references and re-exported shims when import checks are bypassed.
        "CAMetalDrawable",
        "CAMetalLayer",
        "CAMetalDisplayLink",
        "CADisplayLink",
        "CALayer",
        "MTLDevice",
        "MTLTexture",
        "MTLBuffer",
        "MTLCommandQueue",
        "MTLCommandBuffer",
        "MTLRenderPassDescriptor",
        "MTLRenderCommandEncoder",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    private static let adapterAndFeatureModules: Set<String> = [
        "AlbumsFeature",
        "DesignSystem",
        "DesignSystemAppKitAdapter",
        "DesignSystemCore",
        "DesignSystemUIKitAdapter",
        "MapFeature",
        "MapUIKitAdapter",
        "MediaCache",
        "MediaCacheAppKitAdapter",
        "MediaCacheCore",
        "MediaCacheUIKitAdapter",
        "MetalGridTextureAppKitAdapter",
        "MetalGridTextureUIKitAdapter",
        "PhotoViewerFeature",
        "PhotoViewerCore",
        "PhotoViewerUIKitAdapter",
        "PrivacyFeature",
        "ProtonAuth",
        "TimelineFeature",
        "TimelineUIKitAdapter",
        "UploadFeature",
    ]

    private static let renderingCoreAllowedImports: Set<String> = [
        "CoreGraphics",
        "Metal",
        "QuartzCore",
        "simd",
    ]

    private static let renderingCoreForbiddenImports: Set<String> = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "MapKit",
        "AVKit",
        "MetalKit",
        "PhotosCore",
        "MediaCache",
        "TimelineFeature",
    ]

    private static let renderingCoreForbiddenTokens: [String] = [
        "MTKView",
        "NSView",
        "UIView",
        "NSImage",
        "UIImage",
        "NSScrollView",
        "UIScrollView",
        "NSEvent",
        "UIEvent",
        "NSGestureRecognizer",
        "UIGestureRecognizer",
        "NSAccessibility",
        "NSColor",
        "UIColor",
        "NSFont",
        "UIFont",
        "NSBezierPath",
        "UIBezierPath",
        "PhotoUID",
        "PhotoItem",
        "ThumbnailFeed",
        "MediaCache",
        "CAMetalLayer",
        "CAMetalDisplayLink",
        "CADisplayLink",
        "CALayer",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    private static let composeCoreAllowedImports: Set<String> = [
        "CoreGraphics",
        "GridCore",
        "Metal",
        "MetalGridTextureCore",
        "MetalRenderingCore",
        "simd",
    ]

    private static let composeCoreForbiddenImports: Set<String> = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "MapKit",
        "AVKit",
        "MetalKit",
        "PhotosCore",
        "MediaCache",
        "TimelineFeature",
        "TimelineUIKitFeature",
    ]

    private static let composeCoreForbiddenTokens: [String] = [
        "MTKView",
        "NSView",
        "UIView",
        "NSImage",
        "UIImage",
        "NSScrollView",
        "UIScrollView",
        "NSColor",
        "UIColor",
        "NSFont",
        "UIFont",
        "PhotoUID",
        "PhotoItem",
        "ThumbnailFeed",
        "MediaCache",
        "MTKView",
        "CAMetalDrawable",
        "CAMetalLayer",
        "CADisplayLink",
        "CALayer",
        "PhotoDiagnostics",
        "PhotoPerformanceSignposts",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    private static let textureCoreAllowedImports: Set<String> = [
        "CoreGraphics",
        "GridCore",
        "Metal",
    ]

    private static let textureCoreForbiddenImports: Set<String> = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "MapKit",
        "AVKit",
        "MetalKit",
        "PhotosCore",
        "MediaCache",
        "TimelineFeature",
        "MetalRenderingCore",
        "DesignSystem",
    ]

    private static let textureCoreForbiddenTokens: [String] = [
        "MTKView",
        "NSView",
        "UIView",
        "NSImage",
        "UIImage",
        "NSScrollView",
        "UIScrollView",
        "NSEvent",
        "UIEvent",
        "NSGestureRecognizer",
        "UIGestureRecognizer",
        "NSAccessibility",
        "NSColor",
        "UIColor",
        "NSFont",
        "UIFont",
        "PhotoUID",
        "PhotoItem",
        "ThumbnailFeed",
        "MediaCache",
        "MetalGridRenderer",
        "MetalGridDrawableTarget",
        "CAMetalDrawable",
        "CAMetalLayer",
        "CAMetalDisplayLink",
        "CADisplayLink",
        "CALayer",
        "MTLCommandQueue",
        "MTLCommandBuffer",
        "MTLRenderPassDescriptor",
        "MTLRenderCommandEncoder",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    func testUniversalCoreImportsStayOnTargetAllowlists() throws {
        var violations: [String] = []

        for rule in Self.coreTargets {
            let files = try swiftFiles(in: sourcesRoot.appendingPathComponent(rule.name))
            XCTAssertFalse(files.isEmpty, "Expected source files for \(rule.name)")

            for file in files {
                let imports = try importedModules(in: file)
                let unexpected = imports.subtracting(rule.allowedImports)
                if !unexpected.isEmpty {
                    violations.append(
                        "\(rule.name)/\(file.lastPathComponent): unexpected imports \(unexpected.sorted())")
                }

                let forbidden = imports.intersection(Self.forbiddenFrameworkImports)
                if !forbidden.isEmpty {
                    violations.append(
                        "\(rule.name)/\(file.lastPathComponent): forbidden platform imports \(forbidden.sorted())")
                }

                let featureImports = imports.intersection(Self.adapterAndFeatureModules)
                if !featureImports.isEmpty {
                    violations.append(
                        "\(rule.name)/\(file.lastPathComponent): Core must not import adapters/features \(featureImports.sorted())"
                    )
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Universal Core import gate failed:
            \(violations.joined(separator: "\n"))

            Add reusable code to the correct Core target and update this shared
            rule only after confirming macOS, iOS, and iPadOS buildability.
            """
        )
    }

    func testUniversalCoreSourcesDoNotReferencePlatformUITypesOrHardwarePolicy() throws {
        var violations: [String] = []

        for rule in Self.coreTargets {
            let forbidden = Self.forbiddenTokens + rule.extraForbiddenTokens
            let files = try swiftFiles(in: sourcesRoot.appendingPathComponent(rule.name))
            XCTAssertFalse(files.isEmpty, "Expected source files for \(rule.name)")

            for file in files {
                let code = try strippedCode(of: file)
                for token in try references(to: forbidden, in: code) {
                    violations.append("\(rule.name)/\(file.lastPathComponent): \(token)")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Universal Core token gate failed:
            \(violations.joined(separator: "\n"))

            Platform image/view types and hardware sizing policy belong in
            platform adapters, not in reusable Core targets.
            """
        )
    }

    func testPackageManifestKeepsUniversalCoreDependenciesOneWay() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        var violations: [String] = []

        for rule in Self.coreTargets {
            guard let dependencyLine = manifestLine(forTarget: rule.name, in: manifest) else {
                violations.append("\(rule.name): missing Package.swift target declaration")
                continue
            }
            let dependencies = Set(dependencies(inTargetLine: dependencyLine))
            if dependencies != rule.expectedDependencies {
                violations.append(
                    "\(rule.name): dependencies \(dependencies.sorted()) != expected \(rule.expectedDependencies.sorted())"
                )
            }
            let forbidden = dependencies.intersection(Self.adapterAndFeatureModules)
            if !forbidden.isEmpty {
                violations.append("\(rule.name): must not depend on adapters/features \(forbidden.sorted())")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Universal Core dependency gate failed:
            \(violations.joined(separator: "\n"))

            Core dependencies may point only toward lower-level Core targets.
            Adapters and feature/UI targets must depend on Core, never the reverse.
            """
        )
    }

    func testUniversalCoreProductsArePublishedByMatchingTargets() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let missing = Self.coreTargets
            .map(\.name)
            .filter { target in
                !manifest.contains(".library(name: \"\(target)\", targets: [\"\(target)\"])")
            }

        XCTAssertTrue(
            missing.isEmpty,
            "Universal Core targets must be published as matching library products: \(missing.sorted())"
        )
    }

    func testAllSecItemCallsStayInAppleSecurityCore() throws {
        let allowedRoot = sourcesRoot.appendingPathComponent("AppleSecurityCore").standardizedFileURL
        let tokens = ["SecItemCopyMatching(", "SecItemAdd(", "SecItemUpdate(", "SecItemDelete("]
        var violations: [String] = []

        for file in try swiftFiles(in: sourcesRoot) {
            guard !file.standardizedFileURL.path.hasPrefix(allowedRoot.path + "/") else { continue }
            let code = try strippedCode(of: file)
            for token in tokens where code.contains(token) {
                violations.append("\(file.path): direct \(token) must use AppleSecurityCore")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Keychain transport duplication detected:\n\(violations.joined(separator: "\n"))"
        )
    }

    func testAppTargetsHaveRequiredPrivateKeychainGroups() throws {
        let project = try String(contentsOf: repoRoot.appendingPathComponent("project.yml"), encoding: .utf8)
        let macEntitlements = try String(
            contentsOf: repoRoot.appendingPathComponent("App/EncryptedMemories.entitlements"),
            encoding: .utf8
        )

        XCTAssertTrue(project.contains("CODE_SIGN_ENTITLEMENTS: App/EncryptedMemories.entitlements"))
        XCTAssertFalse(project.contains("CODE_SIGN_ENTITLEMENTS: iOSApp/EncryptedMemoriesMobile.entitlements"))
        XCTAssertTrue(macEntitlements.contains("<key>keychain-access-groups</key>"))
        XCTAssertTrue(macEntitlements.contains("$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent("iOSApp/EncryptedMemoriesMobile.entitlements").path
            )
        )
    }

    func testMetalRenderingCoreHasSeparatePackageBoundary() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        var violations: [String] = []

        if !manifest.contains(".library(name: \"MetalRenderingCore\", targets: [\"MetalRenderingCore\"])") {
            violations.append("MetalRenderingCore: missing matching library product")
        }

        guard let targetLine = manifestLine(forTarget: "MetalRenderingCore", in: manifest) else {
            XCTFail("MetalRenderingCore: missing Package.swift target declaration")
            return
        }

        let dependencies = Set(dependencies(inTargetLine: targetLine))
        if !dependencies.isEmpty {
            violations.append("MetalRenderingCore: dependencies \(dependencies.sorted()) != []")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            MetalRenderingCore package boundary regressed:
            \(violations.joined(separator: "\n"))

            Shared Metal rendering has its own target and gate; it is not Universal GridCore.
            """
        )
    }

    func testMetalRenderingCoreStaysRenderOnly() throws {
        let sourceRoot = sourcesRoot.appendingPathComponent("MetalRenderingCore")
        let files = try swiftFiles(in: sourceRoot)
        XCTAssertFalse(files.isEmpty, "Expected source files for MetalRenderingCore")

        var violations: [String] = []

        for file in files {
            let imports = try importedModules(in: file)
            let unexpected = imports.subtracting(Self.renderingCoreAllowedImports)
            if !unexpected.isEmpty {
                violations.append(
                    "MetalRenderingCore/\(file.lastPathComponent): unexpected imports \(unexpected.sorted())")
            }

            let forbiddenImports = imports.intersection(Self.renderingCoreForbiddenImports)
            if !forbiddenImports.isEmpty {
                violations.append(
                    "MetalRenderingCore/\(file.lastPathComponent): forbidden imports \(forbiddenImports.sorted())")
            }

            let code = try strippedCode(of: file)
            for token in try references(to: Self.renderingCoreForbiddenTokens, in: code) {
                violations.append("MetalRenderingCore/\(file.lastPathComponent): forbidden token \(token)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            MetalRenderingCore render-only gate failed:
            \(violations.joined(separator: "\n"))

            MetalRenderingCore may own Metal draw primitives and draw targets, but platform views,
            scroll/gesture hosts, glyph rasterization, photo-domain IDs, media feeds, and hardware budgets
            belong in adapters.
            """
        )
    }

    func testMetalGridTextureCoreHasSeparatePackageBoundary() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        var violations: [String] = []

        if !manifest.contains(".library(name: \"MetalGridTextureCore\", targets: [\"MetalGridTextureCore\"])") {
            violations.append("MetalGridTextureCore: missing matching library product")
        }

        guard let targetLine = manifestLine(forTarget: "MetalGridTextureCore", in: manifest) else {
            XCTFail("MetalGridTextureCore: missing Package.swift target declaration")
            return
        }

        let dependencies = Set(dependencies(inTargetLine: targetLine))
        if dependencies != ["GridCore"] {
            violations.append("MetalGridTextureCore: dependencies \(dependencies.sorted()) != [GridCore]")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            MetalGridTextureCore package boundary regressed:
            \(violations.joined(separator: "\n"))

            Shared Metal texture caching is separate from render command encoding and may depend only on
            GridCore's portable texture policies.
            """
        )
    }

    func testMetalGridTextureCoreStaysTextureOnly() throws {
        let sourceRoot = sourcesRoot.appendingPathComponent("MetalGridTextureCore")
        let files = try swiftFiles(in: sourceRoot)
        XCTAssertFalse(files.isEmpty, "Expected source files for MetalGridTextureCore")

        var violations: [String] = []

        for file in files {
            let imports = try importedModules(in: file)
            let unexpected = imports.subtracting(Self.textureCoreAllowedImports)
            if !unexpected.isEmpty {
                violations.append(
                    "MetalGridTextureCore/\(file.lastPathComponent): unexpected imports \(unexpected.sorted())")
            }

            let forbiddenImports = imports.intersection(Self.textureCoreForbiddenImports)
            if !forbiddenImports.isEmpty {
                violations.append(
                    "MetalGridTextureCore/\(file.lastPathComponent): forbidden imports \(forbiddenImports.sorted())")
            }

            let code = try strippedCode(of: file)
            for token in try references(to: Self.textureCoreForbiddenTokens, in: code) {
                violations.append("MetalGridTextureCore/\(file.lastPathComponent): forbidden token \(token)")
            }
        }

        let cacheFile = sourceRoot.appendingPathComponent("MetalGridTextureCache.swift")
        let glyphFile = sourceRoot.appendingPathComponent("MetalGridGlyphRasterizer.swift")
        for file in [cacheFile, glyphFile] where !FileManager.default.fileExists(atPath: file.path) {
            violations.append("MetalGridTextureCore/\(file.lastPathComponent): missing shared texture-core file")
        }

        if FileManager.default.fileExists(atPath: cacheFile.path) {
            let source = try String(contentsOf: cacheFile, encoding: .utf8)
            // `canAdmitUpload` / `maxUploadBytesPerFrame` / `maxResidentBytes` pin the byte-budget
            // enforcement seam: the cache must gate texture creation on the resident byte budget and
            // bound per-frame upload bytes, not just texture counts.
            for symbol in [
                "package final class MetalGridTextureCache",
                "GridTextureResidencyPolicy<ID>",
                "GridTextureBudget",
                "uploadVisible(wanted: [ID]",
                "canAdmitUpload(",
                "maxUploadBytesPerFrame",
                "maxResidentBytes",
            ] where !source.contains(symbol) {
                violations.append("MetalGridTextureCore/MetalGridTextureCache.swift: missing \(symbol)")
            }
        }

        if FileManager.default.fileExists(atPath: glyphFile.path) {
            let source = try String(contentsOf: glyphFile, encoding: .utf8)
            for symbol in [
                "package struct MetalGridGlyphRequest", "package struct MetalGridGlyphColor",
                "package protocol MetalGridGlyphRasterizing",
            ] where !source.contains(symbol) {
                violations.append("MetalGridTextureCore/MetalGridGlyphRasterizer.swift: missing \(symbol)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            MetalGridTextureCore texture-only gate failed:
            \(violations.joined(separator: "\n"))

            This target may own reusable Metal texture resources and upload/cache mechanics. Platform views,
            glyph rasterization implementations, render command encoding, photo-domain IDs, media feeds, and
            hardware-budget defaults remain outside this target.
            """
        )
    }

    func testMetalGridComposeCoreStaysCompositionOnly() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let sourceRoot = sourcesRoot.appendingPathComponent("MetalGridComposeCore")
        var violations: [String] = []

        // Package boundary: a matching library product, dependencies only toward lower Metal/Grid Core.
        if !manifest.contains(".library(name: \"MetalGridComposeCore\", targets: [\"MetalGridComposeCore\"])") {
            violations.append("MetalGridComposeCore: missing matching library product")
        }
        if let targetLine = manifestLine(forTarget: "MetalGridComposeCore", in: manifest) {
            let dependencies = Set(dependencies(inTargetLine: targetLine))
            if dependencies != ["GridCore", "MetalGridTextureCore", "MetalRenderingCore"] {
                violations.append(
                    "MetalGridComposeCore: dependencies \(dependencies.sorted()) != [GridCore, MetalGridTextureCore, MetalRenderingCore]"
                )
            }
        } else {
            violations.append("MetalGridComposeCore: missing Package.swift target declaration")
        }

        let files = try swiftFiles(in: sourceRoot)
        XCTAssertFalse(files.isEmpty, "Expected source files for MetalGridComposeCore")

        for file in files {
            let imports = try importedModules(in: file)
            let unexpected = imports.subtracting(Self.composeCoreAllowedImports)
            if !unexpected.isEmpty {
                violations.append(
                    "MetalGridComposeCore/\(file.lastPathComponent): unexpected imports \(unexpected.sorted())")
            }
            let forbiddenImports = imports.intersection(Self.composeCoreForbiddenImports)
            if !forbiddenImports.isEmpty {
                violations.append(
                    "MetalGridComposeCore/\(file.lastPathComponent): forbidden imports \(forbiddenImports.sorted())")
            }
            let code = try strippedCode(of: file)
            for token in try references(to: Self.composeCoreForbiddenTokens, in: code) {
                violations.append("MetalGridComposeCore/\(file.lastPathComponent): forbidden token \(token)")
            }
        }

        // The universal composer must own the settled-frame sequence as a generic, data-in/data-out API.
        let composerFile = sourceRoot.appendingPathComponent("MetalGridFrameComposer.swift")
        if FileManager.default.fileExists(atPath: composerFile.path) {
            let source = try String(contentsOf: composerFile, encoding: .utf8)
            for symbol in [
                "package enum MetalGridFrameComposer",
                "func classifyVisibility",
                "func viewportDrawSlots",
                "func stream",
                "func buildGroups",
                "GridTextureStreamingPolicy.window",
            ] where !source.contains(symbol) {
                violations.append("MetalGridComposeCore/MetalGridFrameComposer.swift: missing \(symbol)")
            }
        } else {
            violations.append("MetalGridComposeCore/MetalGridFrameComposer.swift: missing universal frame composer")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            MetalGridComposeCore composition-only gate failed:
            \(violations.joined(separator: "\n"))

            The universal frame composer may own the settled-grid streaming + render-group sequence over the
            injected texture cache, generic in the item ID. Platform views, photo-domain IDs, native colours,
            media feeds, and host diagnostics belong in the macOS/iOS hosts that call it.
            """
        )
    }

    func testUIKitGlyphRasterizerStaysInPlatformAdapter() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let adapterRoot = sourcesRoot.appendingPathComponent("MetalGridTextureUIKitAdapter")
        let adapterFile = adapterRoot.appendingPathComponent("UIKitMetalGridGlyphRasterizer.swift")
        let textureRoot = sourcesRoot.appendingPathComponent("MetalGridTextureCore")
        var violations: [String] = []

        if !manifest.contains(
            ".library(name: \"MetalGridTextureUIKitAdapter\", targets: [\"MetalGridTextureUIKitAdapter\"])")
        {
            violations.append("MetalGridTextureUIKitAdapter: missing matching library product")
        }

        if let targetLine = manifestLine(forTarget: "MetalGridTextureUIKitAdapter", in: manifest) {
            let dependencies = Set(dependencies(inTargetLine: targetLine))
            if dependencies != ["GridCore", "MetalGridTextureCore"] {
                violations.append(
                    "MetalGridTextureUIKitAdapter: dependencies \(dependencies.sorted()) != [GridCore, MetalGridTextureCore]"
                )
            }
        } else {
            violations.append("MetalGridTextureUIKitAdapter: missing Package.swift target declaration")
        }

        guard FileManager.default.fileExists(atPath: adapterFile.path) else {
            XCTFail("MetalGridTextureUIKitAdapter/UIKitMetalGridGlyphRasterizer.swift: missing UIKit glyph adapter")
            return
        }

        let imports = try importedModules(in: adapterFile)
        let expectedImports: Set<String> = ["CoreGraphics", "MetalGridTextureCore", "UIKit"]
        if imports != expectedImports {
            violations.append(
                "MetalGridTextureUIKitAdapter/UIKitMetalGridGlyphRasterizer.swift: imports \(imports.sorted()) != \(expectedImports.sorted())"
            )
        }
        for forbidden in ["AppKit", "SwiftUI", "MetalKit", "PhotosCore", "MediaCache", "TimelineFeature"]
        where imports.contains(forbidden) {
            violations.append(
                "MetalGridTextureUIKitAdapter/UIKitMetalGridGlyphRasterizer.swift: must not import \(forbidden)")
        }

        let source = try String(contentsOf: adapterFile, encoding: .utf8)
        for symbol in [
            "#if canImport(UIKit)",
            "package final class UIKitMetalGridGlyphRasterizer",
            "MetalGridGlyphRasterizing",
            "UIImage.SymbolConfiguration",
            "UIImage(systemName:",
            "UIGraphicsImageRenderer",
            "case .text",
            "NSAttributedString",
            "UIFont.monospacedSystemFont",
            "image.cgImage",
        ] where !source.contains(symbol) {
            violations.append("MetalGridTextureUIKitAdapter/UIKitMetalGridGlyphRasterizer.swift: missing \(symbol)")
        }

        for file in try swiftFiles(in: textureRoot) {
            let code = try strippedCode(of: file)
            for token in try references(
                to: ["UIKitMetalGridGlyphRasterizer", "UIImage", "UIColor", "UIGraphicsImageRenderer"], in: code)
            {
                violations.append(
                    "MetalGridTextureCore/\(file.lastPathComponent): UIKit adapter leaked into texture core via \(token)"
                )
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            UIKit glyph adapter boundary regressed:
            \(violations.joined(separator: "\n"))

            UIKit SF Symbol rasterization belongs in an iOS/iPadOS adapter target. MetalGridTextureCore owns
            only the shared cache and glyph request contract.
            """
        )
    }

    func testPhotoViewerUIKitAdapterStaysPlatformOnlyAndCoreBacked() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let adapterRoot = sourcesRoot.appendingPathComponent("PhotoViewerUIKitAdapter")
        let imageFile = adapterRoot.appendingPathComponent("UIKitViewerImageAdapter.swift")
        var violations: [String] = []

        if !manifest.contains(".library(name: \"PhotoViewerUIKitAdapter\", targets: [\"PhotoViewerUIKitAdapter\"])") {
            violations.append("PhotoViewerUIKitAdapter: missing matching library product")
        }

        if let targetLine = manifestLine(forTarget: "PhotoViewerUIKitAdapter", in: manifest) {
            let dependencies = Set(dependencies(inTargetLine: targetLine))
            // The shared viewer display store (UIKitViewerImageStore) lives here and needs universal Core:
            // PhotosCore (PhotoUID / FullMediaProvider) and MediaCacheCore (the shared WrapperImageCache with
            // memory-pressure semantics). Both are platform-neutral Core - not the macOS MediaCache umbrella.
            let expected: Set<String> = ["PhotoViewerCore", "PhotosCore", "MediaCacheCore"]
            if dependencies != expected {
                violations.append(
                    "PhotoViewerUIKitAdapter: dependencies \(dependencies.sorted()) != \(expected.sorted())")
            }
        } else {
            violations.append("PhotoViewerUIKitAdapter: missing Package.swift target declaration")
        }

        if !FileManager.default.fileExists(atPath: imageFile.path) {
            violations.append(
                "PhotoViewerUIKitAdapter/\(imageFile.lastPathComponent): missing UIKit viewer adapter file"
            )
        }

        if FileManager.default.fileExists(atPath: imageFile.path) {
            let imports = try importedModules(in: imageFile)
            let expectedImports: Set<String> = ["CoreGraphics", "Foundation", "PhotoViewerCore", "UIKit"]
            if imports != expectedImports {
                violations.append(
                    "PhotoViewerUIKitAdapter/UIKitViewerImageAdapter.swift: imports \(imports.sorted()) != \(expectedImports.sorted())"
                )
            }
            let source = try String(contentsOf: imageFile, encoding: .utf8)
            for symbol in [
                "#if canImport(UIKit)",
                "public enum UIKitViewerImageAdapter",
                "UIImage(cgImage: cgImage",
                // Prefix (no closing paren) so the adapter may pass the optional bounded `maxPixelSize` argument
                // while the gate still proves it stays core-backed - decoding via the shared `ViewerFullImageDecoder`.
                "ViewerFullImageDecoder.decodeCGImage(data",
            ] where !source.contains(symbol) {
                violations.append("PhotoViewerUIKitAdapter/UIKitViewerImageAdapter.swift: missing \(symbol)")
            }
        }

        for file in try swiftFiles(in: adapterRoot) {
            let imports = try importedModules(in: file)
            for forbidden in [
                "AppKit", "SwiftUI", "AVKit", "MediaCache", "PhotoViewerFeature", "TimelineFeature", "MapFeature",
                "ProtonDriveSDK",
            ] where imports.contains(forbidden) {
                violations.append("PhotoViewerUIKitAdapter/\(file.lastPathComponent): must not import \(forbidden)")
            }
            let code = try strippedCode(of: file)
            for forbidden in try references(
                to: ["NSImage", "NSView", "AVPlayerView", "NSViewRepresentable", "ThumbnailFeed", "PhotoViewerModel"],
                in: code)
            {
                violations.append(
                    "PhotoViewerUIKitAdapter/\(file.lastPathComponent): forbidden macOS/feature reference \(forbidden)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            PhotoViewer UIKit adapter boundary regressed:
            \(violations.joined(separator: "\n"))

            iOS/iPadOS viewer adapters may translate PhotoViewerCore decoded images, transition timing, and
            AVPlayer layers into UIKit types, but macOS viewer state/UI and MediaCache stay outside this target.
            """
        )
    }

    func testMLSearchAppleAdapterStaysAppleOnlyAndCoreBacked() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let adapterRoot = sourcesRoot.appendingPathComponent("MLSearchAppleAdapter")
        var violations: [String] = []

        if !manifest.contains(".library(name: \"MLSearchAppleAdapter\", targets: [\"MLSearchAppleAdapter\"])") {
            violations.append("MLSearchAppleAdapter: missing matching library product")
        }

        if let targetLine = manifestLine(forTarget: "MLSearchAppleAdapter", in: manifest) {
            let dependencies = Set(dependencies(inTargetLine: targetLine))
            if dependencies != ["MLSearchCore", "MediaFeedCore", "PhotosCore"] {
                violations.append(
                    "MLSearchAppleAdapter: dependencies \(dependencies.sorted()) != [MLSearchCore, MediaFeedCore, PhotosCore]"
                )
            }
        } else {
            violations.append("MLSearchAppleAdapter: missing Package.swift target declaration")
        }

        let allowedImports: Set<String> = [
            "CoreML", "Accelerate", "CoreGraphics", "CryptoKit", "Foundation", "ImageIO",
            "MLSearchCore", "MediaFeedCore", "PhotosCore", "Vision",
        ]
        let forbiddenImports: Set<String> = ["UIKit", "AppKit", "SwiftUI", "Photos", "ProtonDriveSDK", "ProtonCore"]

        let files = try swiftFiles(in: adapterRoot)
        XCTAssertFalse(files.isEmpty, "Expected source files for MLSearchAppleAdapter")

        for file in files {
            let imports = try importedModules(in: file)
            let unexpected = imports.subtracting(allowedImports)
            if !unexpected.isEmpty {
                violations.append(
                    "MLSearchAppleAdapter/\(file.lastPathComponent): unexpected imports \(unexpected.sorted())")
            }
            let forbidden = imports.intersection(forbiddenImports)
            if !forbidden.isEmpty {
                violations.append(
                    "MLSearchAppleAdapter/\(file.lastPathComponent): forbidden imports \(forbidden.sorted())")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            MLSearchAppleAdapter boundary regressed:
            \(violations.joined(separator: "\n"))

            The shared Apple adapter may import Apple ML/image frameworks + MLSearchCore + MediaFeedCore + PhotosCore only.
            UIKit/AppKit/SwiftUI/Photos/SDK imports belong in higher-level platform targets.
            """
        )
    }

    func testMLBackgroundAdapterOwnsOnlyOSOpportunities() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        let target = try XCTUnwrap(manifestLine(forTarget: "MLSearchBackgroundAppleAdapter", in: manifest))
        XCTAssertEqual(Set(dependencies(inTargetLine: target)), ["MLSearchCore", "PhotosCore"])
        let allowed: Set<String> = [
            "Foundation", "MLSearchCore", "PhotosCore", "os", "BackgroundTasks", "UIKit", "AppKit",
        ]
        let files = try swiftFiles(in: sourcesRoot.appendingPathComponent("MLSearchBackgroundAppleAdapter"))
        XCTAssertFalse(files.isEmpty)
        for file in files {
            XCTAssertTrue(try importedModules(in: file).isSubset(of: allowed), file.lastPathComponent)
        }
    }

    func testNoTargetOutsideMLSearchAppleAdapterMayImportCoreML() throws {
        let manifest = try String(contentsOf: packageManifest, encoding: .utf8)
        var violations: [String] = []

        // CoreML is allowed only in MLSearchAppleAdapter. Every other target is banned from
        // importing it so that inference stays behind the single shared adapter seam.
        let exemptTargets: Set<String> = ["MLSearchAppleAdapter"]

        // Discover every target directory under Sources/.
        let topLevelDirs = try FileManager.default.contentsOfDirectory(
            at: sourcesRoot, includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        for dir in topLevelDirs {
            let targetName = dir.lastPathComponent
            if exemptTargets.contains(targetName) { continue }

            let files = try swiftFiles(in: dir)
            for file in files {
                let imports = try importedModules(in: file)
                if imports.contains("CoreML") {
                    violations.append(
                        "\(targetName)/\(file.lastPathComponent): CoreML import is only permitted in MLSearchAppleAdapter"
                    )
                }
                if imports.contains("Vision") {
                    violations.append(
                        "\(targetName)/\(file.lastPathComponent): Vision import is only permitted in MLSearchAppleAdapter (and only if it does not introduce a server-side/CPU-only ML path)"
                    )
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            CoreML/Vision leaked outside MLSearchAppleAdapter:
            \(violations.joined(separator: "\n"))

            CoreML inference must stay behind the single shared Apple adapter seam so a bug in
            inference is fixable once for macOS/iOS/iPadOS. UI/feature/Core targets must not
            import CoreML or Vision directly.
            """
        )

        // Sanity: the manifest must publish the adapter product (this catches accidental removal).
        XCTAssertTrue(
            manifest.contains("\"MLSearchAppleAdapter\""), "MLSearchAppleAdapter must be declared in Package.swift")
    }

    func testNoCommittedMLModelArtifactsUnderSourceTree() throws {
        // Model artifacts are not allowed under Sources or Tests.
        let bannedExtensions: Set<String> = ["mlmodel", "mlmodelc", "mlpackage"]
        var violations: [String] = []

        let enumerator = FileManager.default.enumerator(
            at: packageRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        if let enumerator {
            for case let url as URL in enumerator {
                let ext = url.pathExtension.lowercased()
                if bannedExtensions.contains(ext) {
                    violations.append("\(url.path): ML model artifact must not be committed before license clearance")
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Committed ML model artifact(s) detected:
            \(violations.joined(separator: "\n"))

            Do not ship model weights until the Stage-0 license spike resolves a permissive
            license. Stage 1 ships the architecture skeleton only.
            """
        )
    }

    func testMLSearchAppleAdapterComputePolicyRemainsCentralized() throws {
        // Production sources under MLSearchAppleAdapter must not expose public .all or .cpuOnly.
        // These may only appear behind #if debug guards or in test files.
        let adapterRoot = sourcesRoot.appendingPathComponent("MLSearchAppleAdapter")
        let files = try swiftFiles(in: adapterRoot)
        var violations: [String] = []

        for file in files {
            guard file.lastPathComponent != "CoreMLComputePolicy.swift" else {
                // Policy file itself is checked separately below.
                continue
            }

            let source = try String(contentsOf: file, encoding: .utf8)
            let code = try strippedCode(of: file)

            // No non-policy source may reference .all or .cpuOnly as compute units outside debug guards.
            let hasAllComputeUnitsToken =
                code.range(
                    of: #"(?<![A-Za-z0-9_])\.all(?![A-Za-z0-9_])"#,
                    options: .regularExpression
                ) != nil
            if hasAllComputeUnitsToken && !source.contains("#if DEBUG") {
                violations.append("\(file.lastPathComponent): reference to .all must be behind #if DEBUG guard")
            }
            let hasCPUOnlyComputeUnitsToken =
                code.range(
                    of: #"(?<![A-Za-z0-9_])\.cpuOnly(?![A-Za-z0-9_])"#,
                    options: .regularExpression
                ) != nil
            if hasCPUOnlyComputeUnitsToken && !source.contains("#if DEBUG") {
                violations.append("\(file.lastPathComponent): reference to .cpuOnly must be behind #if DEBUG guard")
            }
        }

        // CoreMLComputePolicy.swift itself must not expose public .all/.cpuOnly as static members,
        // nor a public init taking arbitrary MLComputeUnits (that would allow .all/.cpuOnly in production).
        let policyFile = adapterRoot.appendingPathComponent("CoreMLComputePolicy.swift")
        let policySource = try String(contentsOf: policyFile, encoding: .utf8)
        if policySource.contains("public static let performanceOptimized") {
            violations.append("CoreMLComputePolicy.swift: must not expose public performanceOptimized")
        }
        if policySource.contains("public static let cpuOnly") {
            violations.append("CoreMLComputePolicy.swift: must not expose public cpuOnly")
        }
        if policySource.contains("public init(computeUnits:") {
            violations.append(
                "CoreMLComputePolicy.swift: public init(computeUnits:) would allow arbitrary units in production")
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            ML compute policy hardened incorrectly:
            \(violations.joined(separator: "\n"))

            Foreground inference uses .cpuAndNeuralEngine. The central policy alone may select
            CPU-only for iOS background execution. Arbitrary debug overrides remain internal.
            """
        )
    }

    func testRuntimeStoresNeverUseInPlaceSchemaMigrationDDL() throws {
        let forbiddenPatterns = [
            #"\bALTER\s+TABLE\b"#,
            #"\bRENAME\s+COLUMN\b"#,
            #"\bDROP\s+COLUMN\b"#,
        ]
        let anyPattern = try NSRegularExpression(
            pattern: forbiddenPatterns.map { "(?:\($0))" }.joined(separator: "|"), options: .caseInsensitive)
        var violations: [String] = []

        for file in try swiftFiles(in: sourcesRoot) {
            let source = try String(contentsOf: file, encoding: .utf8)
            // One search rules out the usual file; only a hit names each pattern.
            guard anyPattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
            else { continue }
            for pattern in forbiddenPatterns
            where source.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil {
                violations.append("\(file.path): contains forbidden migration DDL \(pattern)")
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            """
            Runtime persistence must use an exact schema or a classified reset. It must never mutate an
            existing schema in place:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                !isDirectory.boolValue,
                url.pathExtension == "swift"
            else { continue }
            results.append(url)
        }
        return results.sorted { $0.path < $1.path }
    }

    private func importedModules(in file: URL) throws -> Set<String> {
        let source = try String(contentsOf: file, encoding: .utf8)
        var modules = Set<String>()

        for line in source.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefix: String
            if trimmed.hasPrefix("@_exported import ") {
                prefix = "@_exported import "
            } else if trimmed.hasPrefix("@preconcurrency import ") {
                prefix = "@preconcurrency import "
            } else if trimmed.hasPrefix("import ") {
                prefix = "import "
            } else {
                continue
            }
            let remainder = trimmed.dropFirst(prefix.count)
            let moduleName = remainder.split(separator: " ").first.map(String.init) ?? String(remainder)
            modules.insert(moduleName)
        }

        return modules
    }

    private func manifestLine(forTarget target: String, in manifest: String) -> String? {
        let escapedTarget = NSRegularExpression.escapedPattern(for: target)
        let pattern = "\\.target\\s*\\(\\s*name\\s*:\\s*\\\"" + escapedTarget + "\\\""
        guard let match = manifest.range(of: pattern, options: .regularExpression),
            let openingParenthesis = manifest[match.lowerBound...].firstIndex(of: "(")
        else { return nil }

        return balancedRegion(
            in: manifest,
            startingAt: openingParenthesis,
            opening: "(",
            closing: ")"
        )
    }

    private func dependencies(inTargetLine line: String) -> [String] {
        guard let label = line.range(of: #"dependencies\s*:"#, options: .regularExpression),
            let openingBracket = line[label.upperBound...].firstIndex(of: "["),
            let dependencies = balancedRegion(
                in: line,
                startingAt: openingBracket,
                opening: "[",
                closing: "]"
            )
        else { return [] }

        let matches = dependencies.matches(of: #/\"([A-Za-z0-9_]+)\"/#)
        return matches.map { String($0.1) }
    }

    private func balancedRegion(
        in source: String,
        startingAt openingIndex: String.Index,
        opening: Character,
        closing: Character
    ) -> String? {
        var depth = 0
        var index = openingIndex
        var isInsideString = false
        var isEscapingString = false

        while index < source.endIndex {
            let character = source[index]
            if isInsideString {
                if isEscapingString {
                    isEscapingString = false
                } else if character == "\\" {
                    isEscapingString = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 {
                    return String(source[openingIndex...index])
                }
            }
            index = source.index(after: index)
        }

        return nil
    }

    /// The entries of `tokens` that `code` references, in list order. One precompiled search over every plain
    /// token rules out the usual file; only a hit checks each token with `contains(_:in:)`.
    private func references(to tokens: [String], in code: String) throws -> [String] {
        let words = tokens.filter { !$0.contains(".") }
        let anyWord = try Self.alternation(of: words)
        let hasWord = anyWord.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
        return tokens.filter { token in (hasWord || token.contains(".")) && contains(token, in: code) }
    }

    private static let alternations = Mutex<[[String]: NSRegularExpression]>([:])

    private static func alternation(of words: [String]) throws -> NSRegularExpression {
        if let cached = alternations.withLock({ $0[words] }) { return cached }
        let pattern = #"\b(?:"# + words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")\b"#
        let regex = try NSRegularExpression(pattern: pattern)
        alternations.withLock { $0[words] = regex }
        return regex
    }

    /// Stripped sources by path, so each file is read and stripped once per test process although several tests
    /// scan it.
    private static let strippedSources = Mutex<[String: String]>([:])

    /// The code of `file` on disk without comments and string literals.
    private func strippedCode(of file: URL) throws -> String {
        let key = file.standardizedFileURL.path
        if let cached = Self.strippedSources.withLock({ $0[key] }) { return cached }
        let code = stripCommentsAndStringLiterals(from: try String(contentsOf: file, encoding: .utf8))
        Self.strippedSources.withLock { $0[key] = code }
        return code
    }

    private func contains(_ token: String, in code: String) -> Bool {
        if token.contains(".") {
            return code.contains(token)
        }

        let pattern = #"\b\#(NSRegularExpression.escapedPattern(for: token))\b"#
        return code.range(of: pattern, options: .regularExpression) != nil
    }

    private func stripCommentsAndStringLiterals(from source: String) -> String {
        var result = ""
        var index = source.startIndex
        var inLineComment = false
        var inBlockComment = false
        var inString = false
        var escapingString = false

        func nextIndex(after index: String.Index) -> String.Index {
            source.index(after: index)
        }

        while index < source.endIndex {
            let character = source[index]
            let next = nextIndex(after: index)
            let nextCharacter = next < source.endIndex ? source[next] : nil

            if inLineComment {
                if character == "\n" {
                    inLineComment = false
                    result.append("\n")
                } else {
                    result.append(" ")
                }
                index = next
                continue
            }

            if inBlockComment {
                if character == "*", nextCharacter == "/" {
                    inBlockComment = false
                    result.append("  ")
                    index = nextIndex(after: next)
                } else {
                    result.append(character == "\n" ? "\n" : " ")
                    index = next
                }
                continue
            }

            if inString {
                if escapingString {
                    escapingString = false
                    result.append(" ")
                } else if character == "\\" {
                    escapingString = true
                    result.append(" ")
                } else if character == "\"" {
                    inString = false
                    result.append(" ")
                } else {
                    result.append(character == "\n" ? "\n" : " ")
                }
                index = next
                continue
            }

            if character == "/", nextCharacter == "/" {
                inLineComment = true
                result.append("  ")
                index = nextIndex(after: next)
            } else if character == "/", nextCharacter == "*" {
                inBlockComment = true
                result.append("  ")
                index = nextIndex(after: next)
            } else if character == "\"" {
                inString = true
                result.append(" ")
                index = next
            } else {
                result.append(character)
                index = next
            }
        }

        return result
    }
}
