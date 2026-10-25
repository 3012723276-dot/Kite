import Foundation

extension SyncRecord {
    var deviceSymbolName: String {
        let name = deviceName.lowercased()
        if name.contains("iphone") { return "iphone" }
        if name.contains("ipad") { return "ipad" }
        if name.contains("mac") { return "laptopcomputer" }
        return "display.and.waveform"
    }
}
