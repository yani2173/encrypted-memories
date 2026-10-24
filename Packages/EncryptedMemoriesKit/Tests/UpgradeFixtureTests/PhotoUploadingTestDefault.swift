import UploadCore

/// Test doubles that do not care about the network keep a reservation that coordinates with nothing. Production
/// uploaders have no such default: the compiler makes each of them choose its admission.
extension PhotoUploading {
    func reserveNetwork(allowsExpensiveNetwork: Bool) async throws -> UploadNetworkReservation {
        try await UploadNetworkAdmission().reserve(allowsExpensiveNetwork: allowsExpensiveNetwork)
    }
}
