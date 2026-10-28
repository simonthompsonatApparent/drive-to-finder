#!/bin/bash
# Drive to Finder — remove the Mac helper. Run as root.
rm -rf "/Library/Application Support/Apparent/DriveFinder"
rm -f "/Library/Google/Chrome/NativeMessagingHosts/com.apparent.drivefinder.json"
rmdir "/Library/Application Support/Apparent" 2>/dev/null || true
echo "Drive to Finder helper removed."
exit 0
