/// What a file or folder panel is opened for; `none` picks sounds to upload.
public enum PendingPicker: Equatable, Sendable {
    case none
    case downloadFolder([UInt16])
    case backupFolder(DeviceLibrary.Scope)
    case restoreFolder
}

/// What the open panel was shown for, and for which device generation.
public struct PanelRequest: Equatable, Sendable {
    public private(set) var picker: PendingPicker = .none
    private var generation = 0

    public init() {}

    public mutating func open(_ picker: PendingPicker, generation: Int) {
        self.picker = picker
        self.generation = generation
    }

    /// What the panel's result is for, or nil for a folder chosen for a device
    /// that has left: used now, it would act on whatever is connected since,
    /// its slots or a restore over it. Sounds to upload go to the device that
    /// is connected when they arrive, as when the panel stays open.
    public func route(currentGeneration: Int) -> PendingPicker? {
        picker == .none || generation == currentGeneration ? picker : nil
    }
}
