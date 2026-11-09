#if os(macOS)
    import AppKit
    import PhotosCore
    import SwiftUI
    import XCTest
    import Vision

    @testable import AlbumsFeature

    /// Keeps the shared album form's native Mac presentation visible while mobile bar policy changes.
    final class AlbumToolbarRenderingTests: XCTestCase {
        @MainActor func testAlbumSheetKeepsItsTextActionsOnMac() async throws {
            _ = NSApplication.shared
            try requireVisionOCR()
            let backend = FakeAlbumBackend(capabilities: .sdkCatalogWithHTTPWrites)
            let coordinator = AlbumActionCoordinator(repository: repository(backend))
            let host = NSHostingController(
                rootView: Color.clear.frame(width: 480, height: 320)
                    .sheet(isPresented: .constant(true)) { AlbumCreationSheet(coordinator: coordinator) })
            let window = NSWindow(contentViewController: host)
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            for _ in 0..<100 where window.attachedSheet == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            let sheet = try XCTUnwrap(window.attachedSheet, "Album Mac: attachedSheet unavailable")
            defer { sheet.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(500))
            let contentView = try XCTUnwrap(sheet.contentView, "Album Mac: sheet contentView unavailable")
            let view = try XCTUnwrap(contentView.superview, "Album Mac: contentView superview unavailable")
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                sheet.appearance = NSAppearance(named: appearance)
                try await Task.sleep(for: .milliseconds(300))
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(
                    view.bitmapImageRepForCachingDisplay(in: view.bounds), "Album Mac: bitmapRep unavailable")
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["de-DE", "en-US"]
                let image = try XCTUnwrap(bitmap.cgImage, "Album Mac: bitmap cgImage unavailable")
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                } catch {
                    XCTFail("Album Mac: Vision.perform failed: \(error)")
                    throw error
                }
                let visibleText = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
                print("[Album Mac] visible text=\(visibleText)")
                XCTAssertTrue(visibleText.contains(L10n.string("action.cancel")))
                XCTAssertTrue(visibleText.contains(L10n.string("albums.create_action")))
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = "Album sheet \(appearance.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
                if let directory = ProcessInfo.processInfo.environment["ALBUM_TOOLBAR_SCREENSHOT_DIR"] {
                    let url = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try data.write(to: url.appendingPathComponent("album-\(appearance.rawValue).png"))
                }
            }
        }

        @MainActor private func requireVisionOCR() throws {
            let renderer = ImageRenderer(
                content: Text("Cancel Create")
                    .font(.system(size: 32))
                    .foregroundStyle(.black)
                    .padding(20)
                    .background(.white))
            renderer.scale = 2
            guard let image = renderer.cgImage else { throw XCTSkip("Vision OCR unavailable on this runner") }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["de-DE", "en-US"]
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                throw XCTSkip("Vision OCR unavailable on this runner")
            }
            let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
            guard !text.isEmpty else { throw XCTSkip("Vision OCR unavailable on this runner") }
        }
    }
#endif
