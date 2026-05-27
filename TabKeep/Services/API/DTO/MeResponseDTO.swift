import Foundation

struct MeResponseDTO: Codable, Equatable {
    let user: UserDTO
    let device: DeviceInfoDTO
    let linkedProviders: [String]

    enum CodingKeys: String, CodingKey {
        case user
        case device
        case linkedProviders = "linked_providers"
    }
}
