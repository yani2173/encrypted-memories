import Metal

/// One shared hardware floor for every Apple-platform Metal renderer.
public enum Metal3RuntimeCapability {
    public static func supports(device: MTLDevice) -> Bool {
        device.supportsFamily(.metal3)
    }

    // swift-format-ignore
    public static func supportsDefaultDevice() -> Bool {
        #if ENCRYPTED_MEMORIES_UPGRADE_TEST && os(macOS)
        return true
        #else
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return supports(device: device)
        #endif
    }
}
