import Foundation

struct ReceiptStore {
    let directory: URL

    static func `default`() -> ReceiptStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let receiptsDir = docs.appendingPathComponent("receipts", isDirectory: true)
        if !FileManager.default.fileExists(atPath: receiptsDir.path) {
            try? FileManager.default.createDirectory(at: receiptsDir, withIntermediateDirectories: true)
        }
        return ReceiptStore(directory: receiptsDir)
    }

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }

    func writeJPEG(_ data: Data, id: UUID) throws {
        try data.write(to: url(for: id), options: .atomic)
    }

    func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
