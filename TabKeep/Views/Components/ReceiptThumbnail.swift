import SwiftUI
import UIKit

enum ReceiptThumbnailSource: Hashable {
    case url(URL)
    case data(Data)
    case remote(receiptID: UUID)
}

struct ReceiptThumbnail: View {
    let source: ReceiptThumbnailSource
    var cornerRadius: CGFloat = 12
    var onDelete: (() -> Void)? = nil
    var deleteAccessibilityIdentifier: String? = nil

    @State private var resolvedURL: URL?
    @State private var failed: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Color.clear is the size-defining background — fills whatever
            // .frame() the caller applies. The image is overlaid + clipped
            // so a landscape photo's natural aspect ratio doesn't bleed into
            // the layout pass (which previously caused thumbnails to render
            // as landscape rectangles inside a fixed-square .frame).
            Color.clear
                .overlay(
                    Group {
                        if let image = loadImage() {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else if failed {
                            retryPlaceholder
                        } else if case .remote = source {
                            loadingPlaceholder
                        } else {
                            placeholder
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                )

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, Color.black.opacity(0.7))
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(deleteAccessibilityIdentifier ?? "receiptDeleteButton")
            }
        }
        .task(id: sourceID) { await triggerDownloadIfNeeded() }
    }

    private var sourceID: String {
        switch source {
        case .url(let u): return "url:\(u.path)"
        case .data: return "data"
        case .remote(let id): return "remote:\(id.uuidString)"
        }
    }

    private static let imageCache = NSCache<NSURL, UIImage>()

    private func loadImage() -> UIImage? {
        switch source {
        case .url(let url):
            return cachedImage(at: url)
        case .data(let data):
            return UIImage(data: data)
        case .remote:
            guard let url = resolvedURL else { return nil }
            return cachedImage(at: url)
        }
    }

    private func cachedImage(at url: URL) -> UIImage? {
        let key = url as NSURL
        if let cached = Self.imageCache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        Self.imageCache.setObject(image, forKey: key)
        return image
    }

    private func triggerDownloadIfNeeded() async {
        guard case .remote(let id) = source, resolvedURL == nil, !failed else { return }
        do {
            resolvedURL = try await ReceiptDownloader.shared.fileURL(for: id)
        } catch {
            failed = true
        }
    }

    private var placeholder: some View {
        ZStack {
            AppTheme.cardBackground
            Image("image-off")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
        }
    }

    private var loadingPlaceholder: some View {
        ZStack {
            AppTheme.cardBackground
            ProgressView()
                .controlSize(.small)
        }
    }

    private var retryPlaceholder: some View {
        Button {
            failed = false
            resolvedURL = nil
            Task { await triggerDownloadIfNeeded() }
        } label: {
            ZStack {
                AppTheme.cardBackground
                VStack(spacing: 2) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                    Text("Retry").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
