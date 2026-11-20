#!/usr/bin/env bash
# Read-only VCam triage to run in a normal macOS Terminal with the iPhone on USB.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/data/vcam-diagnostic-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
chmod 700 "$OUT"
SSH=(ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$ROOT/config/known_hosts"
     -o HostKeyAlias=iphone11-lab -o BatchMode=yes -o IdentitiesOnly=yes
     -o PasswordAuthentication=no -o ConnectTimeout=8
     -i "$HOME/.ssh/iphone11_lab_ed25519" -p 2222 mobile@127.0.0.1)
SCP=(scp -q -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$ROOT/config/known_hosts"
     -o HostKeyAlias=iphone11-lab -o BatchMode=yes -o IdentitiesOnly=yes
     -o PasswordAuthentication=no -i "$HOME/.ssh/iphone11_lab_ed25519" -P 2222)

echo "Output: $OUT"
# uname -a is executed as requested, but its hostname is kept off disk/stdout.
"${SSH[@]}" 'uname -a >/dev/null && test -d /var/jb && whoami' > "$OUT/preflight.txt"
if ! grep -qx mobile "$OUT/preflight.txt"; then
  echo 'Preflight failed: remote user is not mobile.' >&2
  exit 1
fi
echo 'Remote iOS preflight passed (uname -a, mobile, /var/jb).'

"${SSH[@]}" 'dpkg-query -W -f="${Package} ${Version} ${Architecture}\n" com.tinysweet.vcamios ellekit 2>&1; ps -e -o comm= | grep -E "(^|/)(cameracaptured|mediaserverd|SpringBoard)$" || true; ls -ld /tmp /private/var/tmp /tmp/VCamStatus 2>&1 || true' > "$OUT/device-state.txt"
for name in vcam.dylib vcam.plist vcam_menu.dylib vcam_menu.plist; do
  "${SCP[@]}" "mobile@127.0.0.1:/var/jb/Library/MobileSubstrate/DynamicLibraries/$name" "$OUT/$name"
done

plutil -lint "$OUT/vcam.plist" "$OUT/vcam_menu.plist" > "$OUT/plist-check.txt"
plutil -p "$OUT/vcam.plist" >> "$OUT/plist-check.txt"
file "$OUT/vcam.dylib" "$OUT/vcam_menu.dylib" > "$OUT/binary.txt"
otool -L "$OUT/vcam.dylib" >> "$OUT/binary.txt"
otool -l "$OUT/vcam.dylib" | grep -E 'LC_BUILD_VERSION|LC_VERSION_MIN_IPHONEOS|platform |minos |sdk ' >> "$OUT/binary.txt" || true
codesign -dv --verbose=2 "$OUT/vcam.dylib" >> "$OUT/binary.txt" 2>&1 || true
shasum -a 256 "$OUT"/vcam*.dylib "$OUT"/vcam*.plist > "$OUT/SHA256SUMS"

# Capture only VCam-related unified syslog lines. Open Camera during this window.
if command -v idevicesyslog >/dev/null 2>&1; then
  echo 'Collecting VCam syslog for 20 seconds; open the Camera app now.'
  python3 -I - <<'PY' | python3 -I "$ROOT/scripts/redact.py" > "$OUT/vcam-syslog.redacted.txt"
import select, subprocess, time
p = subprocess.Popen(['idevicesyslog'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     text=True, bufsize=1)
deadline = time.monotonic() + 20
try:
    while time.monotonic() < deadline:
        ready, _, _ = select.select([p.stdout], [], [], max(0, min(0.5, deadline-time.monotonic())))
        if ready:
            line = p.stdout.readline()
            if not line: break
            if '[VCam]' in line or 'vcam.dylib' in line or 'vcam_menu.dylib' in line:
                print(line, end='')
finally:
    p.terminate()
    try: p.wait(timeout=2)
    except subprocess.TimeoutExpired: p.kill()
PY
  python3 -I "$ROOT/scripts/redact.py" --check < "$OUT/vcam-syslog.redacted.txt"
fi
echo "Done: $OUT"
