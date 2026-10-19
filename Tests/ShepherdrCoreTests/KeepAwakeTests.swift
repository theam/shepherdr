import Foundation
import IOKit.pwr_mgt
import Testing
@testable import ShepherdrCore

@MainActor
struct KeepAwakeTests {
    /// What macOS says this process holds, by assertion type.
    private func held() -> [String] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [Int: [[String: Any]]] else { return [] }
        return (all[Int(getpid())] ?? [])
            .filter { ($0["AssertName"] as? String) == "Shepherdr keeps this Mac awake" }
            .compactMap { $0["AssertType"] as? String }
    }

    @Test func holdsAndReleasesTheAssertions() {
        let awake = KeepAwake()
        #expect(!awake.isOn && held().isEmpty)
        awake.turnOn()
        defer { awake.turnOff() }
        #expect(awake.isOn)
        #expect(Set(held()) == ["PreventUserIdleSystemSleep", "PreventSystemSleep"])
        awake.turnOff()
        #expect(!awake.isOn && held().isEmpty)
    }

    @Test func theScreenStaysLitOnlyWhenAsked() {
        let awake = KeepAwake()
        awake.turnOn()
        defer { awake.turnOff() }
        #expect(!held().contains("PreventUserIdleDisplaySleep"))
        awake.keepsScreenOn = true
        #expect(held().contains("PreventUserIdleDisplaySleep"))
        awake.keepsScreenOn = false
        #expect(!held().contains("PreventUserIdleDisplaySleep") && awake.isOn)
    }

    @Test func choosingTheScreenWhileOffHoldsNothing() {
        let awake = KeepAwake()
        awake.keepsScreenOn = true
        #expect(!awake.isOn && held().isEmpty)
    }

    @Test func toggleFlipsIt() {
        let awake = KeepAwake()
        awake.toggle()
        #expect(awake.isOn)
        awake.toggle()
        #expect(!awake.isOn && held().isEmpty)
    }
}
