import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps this Mac from sleeping on its own, like `caffeinate`, through power assertions: macOS
/// drops them if Shepherdr quits or crashes, so a coffee left on never outlives the app.
///
/// The system assertion holds only on power; on battery macOS still sleeps when the lid closes,
/// which is why `onBattery` is public: the sidebar says so.
@MainActor @Observable
public final class KeepAwake {
    public private(set) var isOn = false
    /// Whether the screen stays lit too; off by default, since agents don't need it. Applies at once.
    public var keepsScreenOn = false { didSet { if isOn && keepsScreenOn != oldValue { hold() } } }
    /// Whether this Mac runs on its battery right now.
    public private(set) var onBattery = KeepAwake.runsOnBattery()

    /// The assertions held now, by the type macOS knows them by.
    @ObservationIgnored private var assertions: [(type: String, id: IOPMAssertionID)] = []
    @ObservationIgnored private nonisolated(unsafe) var powerSource: CFRunLoopSource?

    public init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let keepAwake = Unmanaged<KeepAwake>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { keepAwake.onBattery = KeepAwake.runsOnBattery() }
        }, context)?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
    }

    deinit {
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
    }

    public func toggle() { isOn ? turnOff() : turnOn() }

    public func turnOn() {
        isOn = true
        hold()
        // Without the assertions there is nothing to show as on.
        if assertions.isEmpty { isOn = false }
    }

    public func turnOff() {
        release()
        isOn = false
    }

    /// The kinds of assertion held now, as macOS names them.
    var heldTypes: [String] { assertions.map(\.type) }

    private static func types(keepsScreenOn: Bool) -> [String] {
        // Idle sleep, which holds on battery too, and system sleep, which macOS grants only on power.
        ["PreventUserIdleSystemSleep", "PreventSystemSleep"] + (keepsScreenOn ? ["PreventUserIdleDisplaySleep"] : [])
    }

    private func hold() {
        release()
        for type in Self.types(keepsScreenOn: keepsScreenOn) {
            var id = IOPMAssertionID(0)
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Shepherdr keeps this Mac awake" as CFString, &id) == kIOReturnSuccess {
                assertions.append((type, id))
            }
        }
    }

    private func release() {
        for held in assertions { IOPMAssertionRelease(held.id) }
        assertions = []
    }

    nonisolated private static func runsOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String? else { return false }
        return type == kIOPMBatteryPowerKey
    }
}
