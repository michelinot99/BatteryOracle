import Foundation
import IOKit
import IOKit.ps

/// One reading of the internal battery and of the whole system's power draw.
struct BatterySnapshot {
    var date = Date()
    var level: Double              // 0–100, as shown by macOS
    var plugged: Bool
    var charging: Bool
    var systemWatts: Double?       // whole-Mac power draw, measured on battery and on AC
    var fullChargeWh: Double       // usable energy at 100 %
    var health: Double             // full charge capacity / design capacity
    var cycles: Int
    var temperature: Double?       // °C
    var adapterWatts: Int?
    var minutesToFull: Int?
}

enum BatteryReader {
    /// Reads AppleSmartBattery directly: cheap (no subprocess) and richer than IOPowerSources.
    static func read() -> BatterySnapshot? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }

        func num(_ key: String, in dict: [String: Any]? = nil) -> NSNumber? { (dict ?? d)[key] as? NSNumber }

        guard let current = num("CurrentCapacity")?.doubleValue,
              let maxCap = num("MaxCapacity")?.doubleValue, maxCap > 0 else { return nil }

        let data = d["BatteryData"] as? [String: Any]
        let telemetry = d["PowerTelemetryData"] as? [String: Any]
        let adapter = d["AdapterDetails"] as? [String: Any]

        let fcc = num("FullChargeCapacity", in: data)?.doubleValue ?? num("AppleRawMaxCapacity")?.doubleValue ?? 0
        let design = num("DesignCapacity")?.doubleValue ?? num("DesignCapacity", in: data)?.doubleValue ?? fcc
        let voltage = (num("Voltage")?.doubleValue ?? 11_500) / 1000
        // Li-ion cells sit around 3.85 V nominal; infer the series count from the pack voltage.
        let cells = min(4, max(2, (voltage / 3.8).rounded()))
        let fullWh = fcc / 1000 * cells * 3.85

        var systemWatts = num("SystemLoad", in: telemetry).map { $0.doubleValue / 1000 }
        if systemWatts == nil || systemWatts == 0, let amps = num("InstantAmperage")?.int64Value, amps < 0 {
            systemWatts = Double(-amps) / 1000 * voltage
        }

        let toFull = num("AvgTimeToFull")?.intValue ?? 65535
        let temp = num("Temperature")?.doubleValue

        return BatterySnapshot(
            level: (current / maxCap * 100).rounded(),
            plugged: (d["ExternalConnected"] as? Bool) ?? false,
            charging: (d["IsCharging"] as? Bool) ?? false,
            systemWatts: systemWatts,
            fullChargeWh: fullWh > 1 ? fullWh : 50,
            health: design > 0 ? min(1, fcc / design) : 1,
            cycles: num("CycleCount")?.intValue ?? 0,
            temperature: temp.map { $0 / 100 },
            adapterWatts: num("Watts", in: adapter)?.intValue,
            minutesToFull: toFull > 0 && toFull < 65535 ? toFull : nil
        )
    }
}

extension Notification.Name {
    static let powerSourceChanged = Notification.Name("BatteryOraclePowerSourceChanged")
}

/// Wakes the app the moment the charger is connected or removed, instead of waiting for the next poll.
enum PowerSourceObserver {
    private static var source: CFRunLoopSource?

    static func start() {
        guard source == nil,
              let src = IOPSNotificationCreateRunLoopSource({ _ in
                  NotificationCenter.default.post(name: .powerSourceChanged, object: nil)
              }, nil)?.takeRetainedValue() else { return }
        source = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
    }
}
