#!/usr/bin/env python3
"""Write a launchd disabled.plist for jobs that crash-loop on this phone.

  mk-disabled.py OUT.plist

These daemons need hardware or services that do not exist here (Bluetooth,
cellular helper, iTunes sync, FairPlay, ...), so launchd restarts them every
few seconds for the whole uptime. launchd reads the file at its next start:
pack it with tools/mkfiles.py (/private/var/db/com.apple.xpc.launchd/
disabled.plist) and it takes effect on the boot after the one that installs it.
"""
import plistlib
import sys

JOBS = [
    'com.apple.bluetoothd',
    'com.apple.atc',
    'com.apple.sosd',
    'com.apple.CommCenterMobileHelper',
    'com.apple.familycircled',
    'com.apple.fairplayd.H2',
    'com.apple.fairplaydeviceidentityd',
    'com.apple.dt.remotepairingdeviced',
]

with open(sys.argv[1], 'wb') as f:
    plistlib.dump({j: True for j in JOBS}, f, fmt=plistlib.FMT_XML)
