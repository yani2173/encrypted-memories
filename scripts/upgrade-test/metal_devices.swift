import Foundation
import Metal

func describe(_ device: any MTLDevice) -> [String: Any] {
    [
        "name": device.name,
        "supportsFamilyMetal3": device.supportsFamily(.metal3),
        "registryID": String(device.registryID),
        "isLowPower": device.isLowPower,
        "hasUnifiedMemory": device.hasUnifiedMemory,
    ]
}

var report: [String: Any] = [
    "allDevices": MTLCopyAllDevices().map(describe),
    "defaultDevice": NSNull(),
]
if let device = MTLCreateSystemDefaultDevice() {
    report["defaultDevice"] = describe(device)
}
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
