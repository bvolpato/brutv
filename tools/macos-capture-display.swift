import CoreGraphics
import Foundation

let display = CGMainDisplayID()
guard let modes = CGDisplayCopyAllDisplayModes(
    display, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
) as? [CGDisplayMode] else {
    throw NSError(domain: "MacCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot inspect the native Mac display modes"])
}
print("Available display modes: \(modes.map { "\($0.width)x\($0.height)" }.joined(separator: ", "))")
let candidates = modes.filter { $0.width >= 1440 && $0.height >= 1000 }
    .sorted { $0.width * $0.height < $1.width * $1.height }
guard let mode = candidates.first else {
    throw NSError(domain: "MacCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "The runner has no display mode large enough for a native 1280x800 application window"])
}
var configuration: CGDisplayConfigRef?
let started = CGBeginDisplayConfiguration(&configuration)
guard started == .success, let configuration else {
    throw NSError(domain: "MacCapture", code: Int(started.rawValue), userInfo: [NSLocalizedDescriptionKey: "Cannot begin native display configuration"])
}
let result = CGConfigureDisplayWithDisplayMode(configuration, display, mode, nil)
guard result == .success else {
    CGCancelDisplayConfiguration(configuration)
    throw NSError(domain: "MacCapture", code: Int(result.rawValue), userInfo: [NSLocalizedDescriptionKey: "Cannot set the native display to \(mode.width)x\(mode.height)"])
}
let completed = CGCompleteDisplayConfiguration(configuration, .forSession)
guard completed == .success else {
    throw NSError(domain: "MacCapture", code: Int(completed.rawValue), userInfo: [NSLocalizedDescriptionKey: "Cannot preserve the native display mode for the login session"])
}
print("Native display selected: \(mode.width)x\(mode.height)")
