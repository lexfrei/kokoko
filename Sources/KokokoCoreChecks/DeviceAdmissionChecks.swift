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
        backgroundAdmissionChecks()
    }

    private static func backgroundAdmissionChecks() {
        var gate = DeviceAdmission()
        guard let background = gate.beginBackground() else {
            check(false, "background admission: idle accepts one read")
            return
        }
        check(gate.occupied && !gate.userOccupied && !gate.operation, "background admission: read reserves device without disabling user entry points")
        eq(gate.beginBackground(), nil, "background admission: only one background read may own the device")
        check(!gate.beginOperation() && gate.beginPreview() == nil, "background admission: short actions are refused, never replayed")
        guard case .waiting(let owner) = gate.requestForeground() else {
            check(false, "background admission: one file action waits behind current read")
            return
        }
        check(gate.foregroundWaiting && gate.userOccupied && !gate.operation, "background admission: waiting owner is visible without claiming an active operation")
        eq(gate.requestForeground(), .refused, "background admission: second file action is explicitly refused")
        eq(gate.endBackground(UUID()), .stale, "background admission: wrong callback cannot release read or promote waiter")
        check(gate.foregroundWaiting, "background admission: wrong release preserves pending owner")
        eq(gate.endBackground(background), .foreground(owner), "background admission: read atomically promotes the waiting owner")
        check(gate.operation && !gate.foregroundWaiting, "background admission: operation owns gate before continuation resumes")
        check(gate.beginBackground() == nil && gate.beginPreview() == nil && !gate.beginOperation(),
              "background admission: no operation steals the foreground handoff gap")
        eq(gate.endBackground(background), .stale, "background admission: late duplicate read completion cannot release foreground")
        check(gate.operation && gate.endOperation() && !gate.occupied, "background admission: foreground release restores idle")
        eq(gate.requestForeground(), .started, "background admission: file work without a read starts directly")
        _ = gate.endOperation()
        guard let read = gate.beginBackground(), case .waiting(let cancelled) = gate.requestForeground() else {
            check(false, "background admission: cancellation fixture owns read and waiter")
            return
        }
        check(!gate.cancelForeground(UUID()), "background admission: wrong cancellation cannot remove waiter")
        check(gate.cancelForeground(cancelled) && gate.occupied && !gate.userOccupied,
              "background admission: cancellation removes only pending foreground ownership")
        guard case .waiting(let next) = gate.requestForeground() else {
            check(false, "background admission: later explicit file action can wait after cancellation")
            return
        }
        check(!gate.cancelForeground(cancelled), "background admission: late cancellation cannot remove a new waiter")
        eq(gate.endBackground(read), .foreground(next), "background admission: only current pending owner is promoted")
        _ = gate.endOperation()
        guard let idleRead = gate.beginBackground() else { return }
        eq(gate.endBackground(idleRead), .idle, "background admission: read with no waiter returns idle without foreground lifecycle")
    }
}
