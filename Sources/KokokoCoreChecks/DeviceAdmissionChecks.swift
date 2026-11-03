import Foundation
import KokokoLibrary

extension KokokoCoreChecks {
    static func deviceAdmissionChecks() {
        var gate = DeviceAdmission()
        check(!gate.occupied && !gate.operation, "device admission: idle leaves controls enabled")
        check(gate.beginOperation(), "device admission: idle accepts file work")
        check(gate.occupied && gate.operation, "device admission: file work owns the device and disables controls")
        eq(gate.beginPreview(), nil, "device admission: preview does not queue behind file work")
        check(!gate.beginOperation(), "device admission: conflicting file work is refused")
        check(gate.endOperation(), "device admission: file release requests deferred-work flushing")
        check(!gate.endOperation(), "device admission: duplicate release does not flush again")
        guard let token = gate.beginPreview() else {
            check(false, "device admission: idle accepts preview")
            return
        }
        check(gate.occupied && !gate.operation, "device admission: preview owns the device without disabling controls")
        eq(gate.beginPreview(), nil, "device admission: duplicate preview is ignored, not queued")
        check(!gate.beginOperation(), "device admission: preview refuses conflicting file work")
        check(!gate.endOperation() && gate.occupied, "device admission: file release cannot free preview")
        check(!gate.endPreview(UUID()) && gate.occupied, "device admission: only the owner releases preview")
        var tabs = PendingTabLoad()
        eq(tabs.open(.projects, showing: .sounds, deviceBusy: gate.occupied), nil,
           "device admission: tab loading waits during a visually idle preview")
        eq(tabs.waiting, .projects, "device admission: preview retains deferred tab work")
        check(gate.endPreview(token), "device admission: preview completion requests the existing deferred flush")
        eq(tabs.deviceReleased(showing: .projects), .projects, "device admission: preview release loads the waiting tab")
        eq(tabs.deviceReleased(showing: .projects), nil, "device admission: deferred tab is consumed once")
        for outcome in ["success", "error", "cancellation"] {
            guard let current = gate.beginPreview() else {
                check(false, "device admission: accepts a later preview")
                return
            }
            check(!gate.endPreview(token) && gate.occupied, "device admission: stale completion does not release a newer preview")
            check(gate.endPreview(current) && !gate.occupied, "device admission: \(outcome) releases the preview")
        }
        check(gate.beginOperation(), "device admission: file work can start after preview completes")
        check(!gate.endPreview(token) && gate.operation, "device admission: stale preview cannot release file work")
        _ = gate.endOperation()
    }
}
