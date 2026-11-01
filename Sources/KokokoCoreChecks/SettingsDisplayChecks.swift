import KokokoCore
import KokokoLibrary

extension KokokoCoreChecks {
    static func settingsDisplayChecks() {
        eq(JSONValue.double(46875).displayText, "46875", "settings: a whole-number double shows no .0")
        eq(JSONValue.double(-3).displayText, "-3", "settings: a negative whole-number double shows no .0")
        eq(JSONValue.double(0.5).displayText, "0.5", "settings: a fractional double keeps its fraction")
        eq(JSONValue.double(1e20).displayText, "1e+20", "settings: a double past Int range is printed as a double")
        eq(JSONValue.int(46875).displayText, "46875", "settings: an int shows as is")
    }
}
