import KokokoLibrary

extension KokokoCoreChecks {
    static func firmwareVersionChecks() {
        eq(firmwareStatus(device: "2.5.1", published: "2.5.1"), .current, "firmware: equal versions are current")
        eq(firmwareStatus(device: "2.5.1", published: "2.6.0"), .behind(latest: "2.6.0"),
           "firmware: an older device is behind")
        eq(firmwareStatus(device: "2.10.0", published: "2.9.3"), .ahead,
           "firmware: components compare as numbers, not text")
        eq(firmwareStatus(device: "2.9.3", published: "2.10.0"), .behind(latest: "2.10.0"),
           "firmware: a lower number in the same place is behind")
        eq(firmwareStatus(device: "2.6.0", published: "2.5.1"), .ahead,
           "firmware: a device newer than the published release is ahead")
        eq(firmwareStatus(device: "2.5", published: "2.5.0"), .current,
           "firmware: a missing trailing component counts as 0")
        eq(firmwareStatus(device: "2.5.0.1", published: "2.5"), .ahead,
           "firmware: an extra non-zero component is newer")
        eq(firmwareStatus(device: "2.5", published: "2.5.0.1"), .behind(latest: "2.5.0.1"),
           "firmware: a missing component is older than a non-zero one")
        eq(firmwareStatus(device: "2.5.1", published: "2.5.1+42"), .current,
           "firmware: a build suffix on the published version is ignored")
        eq(firmwareStatus(device: "2.5.1+7", published: "2.5.1"), .current,
           "firmware: a build suffix on the device version is ignored")
        eq(firmwareStatus(device: "2.5.1+7", published: "2.6.0+3"), .behind(latest: "2.6.0"),
           "firmware: the latest version is named without its build suffix")
        eq(firmwareStatus(device: "2.5.1b", published: "2.5.1b+3"), .current,
           "firmware: identical versions are current even when they are not numbers")
        check(firmwareStatus(device: "2.5.x", published: "2.5.1") == nil,
              "firmware: a non-numeric component is not compared")
        check(firmwareStatus(device: "", published: "2.5.1") == nil, "firmware: an empty version is not compared")
        check(firmwareStatus(device: "2..1", published: "2.0.1") == nil,
              "firmware: an empty component is not compared")

        eq(firmwareSuffix(.current), " ✓", "firmware suffix: current")
        eq(firmwareSuffix(.behind(latest: "2.6.0")), " → 2.6.0", "firmware suffix: behind names the release")
        eq(firmwareSuffix(.ahead), " (newer than the published release)",
           "firmware suffix: ahead says newer than the published release")
        eq(firmwareSuffix(nil), "", "firmware suffix: nothing known shows nothing")
    }
}
