import CoreMIDI
import Foundation
import VirtualEP

let device = VirtualEPDevice()
try device.start()
print("vep: virtual EP device '\(device.name)' up — connect kokoko to it")
dispatchMain()
