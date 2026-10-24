import DesignSystemCore
import Foundation
import MapKit
import PhotoViewerCore
import PhotosCore
import SwiftUI

/// Native iOS metadata sheet for the full-screen viewer.
///
/// Metadata and album membership are supplied by the viewer so this view only owns presentation. The
/// shared `PhotoMetadataLoadState` remains the single source of truth for the metadata request lifecycle.
struct MobileViewerInfoSheet: View {
    @AppStorage(AppSettingsKey.mapAndPlacesEnabled) private var mapAndPlacesEnabled =
        AppSettingsDefault.mapAndPlacesEnabled
    let item: PhotoItem
    let metadataLoadState: PhotoMetadataLoadState
    let albumTitles: [String]
    let canLoadAlbumMemberships: Bool
    let isLoadingAlbumMemberships: Bool
    let albumMembershipsLoadFailed: Bool
    let placeName: String?
    let onRetry: () -> Void
    let onClose: () -> Void

    private var metadata: PhotoMetadata? {
        metadataLoadState.metadata
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    captureSection
                    fileSection
                    locationSection
                    albumsSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .mobileNavigationTitle(L10n.string("infopanel.info"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        Label(L10n.string("infopanel.close"), systemImage: "xmark")
                    }
                    .accessibilityLabel(L10n.string("infopanel.close"))
                }
                .mobileVisibilityPriority(.high)
            }
            .presentationDragIndicator(.visible)
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.captureTime, format: .dateTime.weekday(.wide).day().month(.wide).year())
                .font(.headline)
            Text(item.captureTime, format: .dateTime.hour().minute())
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let device = metadata?.device, !device.isEmpty {
                Label(device, systemImage: "camera")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .accessibilityLabel(device)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let type = mediaType {
                metadataRow(L10n.string("infopanel.type"), value: type)
            }

            metadataStateContent
        }
    }

    @ViewBuilder
    private var metadataStateContent: some View {
        switch metadataLoadState {
        case .idle:
            Label(L10n.string("infopanel.info"), systemImage: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.string("infopanel.info"))

        case .loading:
            ProgressSpinner(accessibilityLabel: L10n.string("infopanel.info"))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)

        case .loaded(let metadata):
            loadedMetadataSection(metadata)

        case .unavailable:
            EmptyView()

        case .failed:
            ContentUnavailableView {
                Label(
                    L10n.string("infopanel.load_failed_title"),
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(L10n.string("infopanel.load_failed_message"))
            } actions: {
                RetryButton(.prominent, action: onRetry)
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func loadedMetadataSection(_ metadata: PhotoMetadata) -> some View {
        if let filename = nonEmpty(metadata.filename) {
            metadataRow(L10n.string("infopanel.name"), value: filename)
        }
        if let width = metadata.pixelWidth, let height = metadata.pixelHeight,
            width > 0, height > 0
        {
            metadataRow(
                L10n.string("infopanel.dimensions"),
                value: "\(width) × \(height) (\(megapixels(width, height)) MP)"
            )
        }
        if let size = metadata.fileSize, size >= 0 {
            metadataRow(L10n.string("infopanel.size"), value: L10n.fileSize(Int64(size)))
        }

        let duration = metadata.durationSeconds ?? item.durationSeconds
        if let duration, duration > 0 {
            metadataRow(L10n.string("infopanel.duration"), value: durationString(duration))
        }
    }

    @ViewBuilder
    private var locationSection: some View {
        let location = ViewerInfoLocation(
            metadata: metadata, placeName: placeName, mapAndPlacesEnabled: mapAndPlacesEnabled)
        if location.hasContent {
            VStack(alignment: .leading, spacing: 10) {
                if let placeName = location.placeName {
                    Label(placeName, systemImage: "mappin.and.ellipse")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let latitude = metadata?.latitude, let longitude = metadata?.longitude,
                    let coordinates = location.coordinateText
                {
                    if location.showsMap, let mapLabel = location.mapAccessibilityLabel {
                        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                        let mapTitle = location.markerTitle
                        Map(
                            initialPosition: .region(
                                MKCoordinateRegion(
                                    center: coordinate,
                                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                                ))
                        ) {
                            Marker(mapTitle, coordinate: coordinate)
                        }
                        .id(location.mapIdentity)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1.55, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(mapLabel))
                    }

                    Text(coordinates)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityLabel(
                            Text(coordinates)
                        )
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var albumsSection: some View {
        if canLoadAlbumMemberships {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.string("infopanel.albums"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                if isLoadingAlbumMemberships {
                    ProgressSpinner(accessibilityLabel: L10n.string("infopanel.albums"))
                } else if albumMembershipsLoadFailed {
                    Label(
                        L10n.string("infopanel.albums_load_failed"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                } else if albumTitles.isEmpty {
                    Text(L10n.string("infopanel.no_albums"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(albumTitles, id: \.self) { title in
                        Label(title, systemImage: "rectangle.stack")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var mediaType: String? {
        if let mimeType = nonEmpty(metadata?.mimeType) {
            return mimeType
        }
        return nonEmpty(item.mediaType)
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func megapixels(_ width: Int, _ height: Int) -> String {
        String(format: "%.1f", (Double(width) * Double(height)) / 1_000_000)
    }

    private func durationString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
