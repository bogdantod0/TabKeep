import SwiftUI
import UIKit

struct FullScreenReceiptViewer: View {
    let receipts: [ReceiptAttachment]
    @State var index: Int
    @State private var deleteConfirmation: ReceiptAttachment?
    /// Returns true when the current user is allowed to remove this receipt.
    /// Mirrors ExpenseFormContent's per-thumbnail rule so the viewer matches
    /// the grid's affordances. Default = no delete shown.
    var canDelete: (ReceiptAttachment) -> Bool = { _ in false }
    /// Called when the user confirms removal. The viewer dismisses itself
    /// after invoking — the caller is responsible for removing the row from
    /// the model.
    var onDelete: ((ReceiptAttachment) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    init(
        receipts: [ReceiptAttachment],
        initialIndex: Int = 0,
        canDelete: @escaping (ReceiptAttachment) -> Bool = { _ in false },
        onDelete: ((ReceiptAttachment) -> Void)? = nil
    ) {
        self.receipts = receipts
        self._index = State(initialValue: initialIndex)
        self.canDelete = canDelete
        self.onDelete = onDelete
    }

    private var currentReceipt: ReceiptAttachment? {
        guard receipts.indices.contains(index) else { return nil }
        return receipts[index]
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(receipts.enumerated()), id: \.offset) { i, receipt in
                    ReceiptPageView(receiptID: receipt.id)
                        .tag(i)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: receipts.count > 1 ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .navigationTitle(receipts.count > 1 ? "Receipt \(index + 1) of \(receipts.count)" : "Receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let current = currentReceipt, onDelete != nil, canDelete(current) {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(role: .destructive) {
                            deleteConfirmation = current
                        } label: {
                            Image(systemName: "trash")
                                .accessibilityLabel("Remove receipt")
                        }
                        .tint(.red)
                        .accessibilityIdentifier("viewerDeleteReceiptButton")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Remove this receipt?",
                isPresented: Binding(
                    get: { deleteConfirmation != nil },
                    set: { if !$0 { deleteConfirmation = nil } }
                ),
                titleVisibility: .visible,
                presenting: deleteConfirmation
            ) { target in
                Button("Remove", role: .destructive) {
                    onDelete?(target)
                    deleteConfirmation = nil
                    dismiss()
                }
                Button("Cancel", role: .cancel) { deleteConfirmation = nil }
            }
        }
    }
}

private struct ReceiptPageView: View {
    let receiptID: UUID
    @State private var resolvedURL: URL?
    @State private var failed: Bool = false

    var body: some View {
        Group {
            if let url = resolvedURL {
                ZoomableImageView(url: url)
            } else if failed {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Button("Tap to retry") {
                        failed = false
                        Task { await load() }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task(id: receiptID) { await load() }
    }

    private func load() async {
        let store = ReceiptStore.default()
        let localURL = store.url(for: receiptID)
        if FileManager.default.fileExists(atPath: localURL.path) {
            resolvedURL = localURL
            return
        }
        do {
            resolvedURL = try await ReceiptDownloader.shared.fileURL(for: receiptID)
        } catch {
            failed = true
        }
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delegate = context.coordinator

        let imageView = UIImageView()
        imageView.image = UIImage(contentsOfFile: url.path)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}
