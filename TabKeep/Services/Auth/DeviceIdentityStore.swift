import Foundation

final class DeviceIdentityStore {
    private static let key = "device_id"

    func deviceID() -> UUID {
        let defaults = UserDefaults.standard
        if let str = defaults.string(forKey: Self.key), let id = UUID(uuidString: str) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: Self.key)
        return id
    }
}
