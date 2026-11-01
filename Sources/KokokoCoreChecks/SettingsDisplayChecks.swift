import KokokoCore
import KokokoLibrary

extension KokokoCoreChecks {
    static func settingsDisplayChecks() {
        eq(JSONValue.double(46875).displayText, "46875", "settings: a whole-number double shows no .0")
        eq(JSONValue.double(-3).displayText, "-3", "settings: a negative whole-number double shows no .0")
        eq(JSONValue.double(0.5).displayText, "0.5", "settings: a fractional double keeps its fraction")
        eq(JSONValue.double(1e20).displayText, "1e+20", "settings: a double past Int range is printed as a double")
        eq(JSONValue.int(46875).displayText, "46875", "settings: an int shows as is")
        eq(SettingsStatus.notLoaded.placeholder(isEmpty: true), "loading...", "settings: says loading before the first read")
        eq(SettingsStatus.failed.placeholder(isEmpty: true), "could not read the settings",
           "settings: a failed read says so instead of loading forever")
        eq(SettingsStatus.unsupported.placeholder(isEmpty: true), "not exposed over midi on this firmware",
           "settings: says the firmware does not expose them")
        eq(SettingsStatus.loaded.placeholder(isEmpty: true), "no settings", "settings: an empty read says there are none")
        eq(SettingsStatus.loaded.placeholder(isEmpty: false), nil, "settings: a read with settings shows them")
        eq([SettingsStatus.notLoaded, .loaded, .unsupported, .failed].filter(\.loadsWhenOpened), [.notLoaded],
           "settings: opening the tab reads only when nothing is known yet; unsupported firmware is not asked again")
    }
}
