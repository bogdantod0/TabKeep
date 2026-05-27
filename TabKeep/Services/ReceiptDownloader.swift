import Foundation
import os

actor ReceiptDownloader {
    static let shared = ReceiptDownloader()

    private let log = Logger(subsystem: "com.example.tabkeep", category: "receipt-downloader")
    private var inFlight: [UUID: Task<URL, Error>] = [:]
    private var remoteProvider: (@Sendable (UUID) async throws -> URL)?

    /// Wired from TabKeepApp at bootstrap to avoid an import cycle.
    func configure(remoteURLProvider: @escaping @Sendable (UUID) async throws -> URL) {
        self.remoteProvider = remoteURLProvider
    }

    /// Returns the local file URL for `id`, downloading + caching from the
    /// server if not already present. Concurrent requesters for the same id
    /// share one download.
    func fileURL(for id: UUID) async throws -> URL {
        let store = ReceiptStore.default()
        let localURL = store.url(for: id)
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
        if let existing = inFlight[id] {
            return try await existing.value
        }
        let task = Task { [weak self] () -> URL in
            guard let self else { throw URLError(.cancelled) }
            return try await self.download(id: id, to: localURL)
        }
        inFlight[id] = task
        defer { inFlight[id] = nil }
        return try await task.value
    }

    private func download(id: UUID, to localURL: URL) async throws -> URL {
        guard let provider = remoteProvider else {
            throw URLError(.notConnectedToInternet, userInfo: ["reason": "downloader_not_configured"])
        }
        let presigned = try await provider(id)
        let (data, response) = try await URLSession.shared.data(from: presigned)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            log.warning("receipt download failed id=\(id) status=\((response as? HTTPURLResponse)?.statusCode ?? -1)")
            throw URLError(.badServerResponse)
        }
        try data.write(to: localURL, options: .atomic)
        return localURL
    }
}
