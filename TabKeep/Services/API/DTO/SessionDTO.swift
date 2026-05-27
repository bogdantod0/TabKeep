import Foundation

struct SessionDTO: Codable, Equatable {
    let deviceToken: String
    let user: UserDTO
    let linkedProviders: [String]

    enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case user
        case linkedProviders = "linked_providers"
    }
}
