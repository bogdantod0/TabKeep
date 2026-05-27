import Foundation

struct ReceiptDTO: Codable, Equatable, Sendable {
    let id: UUID
    let expenseID: UUID
    let uploaderUserID: UUID?
    let contentType: String
    let byteSize: Int64
    let state: String          // "pending" | "ready"
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case expenseID = "expense_id"
        case uploaderUserID = "uploader_user_id"
        case contentType = "content_type"
        case byteSize = "byte_size"
        case state
        case createdAt = "created_at"
    }
}

struct ReceiptCreateRequestDTO: Encodable, Sendable {
    let receiptID: UUID
    let contentType: String
    let byteSize: Int64

    enum CodingKeys: String, CodingKey {
        case receiptID = "receipt_id"
        case contentType = "content_type"
        case byteSize = "byte_size"
    }
}

struct ReceiptCreateResponseDTO: Decodable, Sendable {
    let receiptID: UUID
    let uploadURL: URL
    let objectKey: String
    let headers: [String: String]

    enum CodingKeys: String, CodingKey {
        case receiptID = "receipt_id"
        case uploadURL = "upload_url"
        case objectKey = "object_key"
        case headers
    }
}
