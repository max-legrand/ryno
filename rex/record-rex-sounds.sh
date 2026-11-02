#!/bin/sh
# Record Rex's program-activity sounds (attention, success, error) so ryno can play the same sound.
# Rex synthesizes them in code, so there is no file to copy: this records Rex's audio output with a
# Core Audio process tap while a background Rex tab reports each status.
#
#   rex/record-rex-sounds.sh        # run in a terminal inside Rex, not from an agent's sandbox
#
# Writes ~/.config/ryno/sounds/{attention,success,error}.caf (RYNO_SOUNDS_DIR overrides). The first run
# asks for the "System Audio Recording" permission for "Ryno Sound Capture"; allow it and run again.
# Rex's Play sounds setting (Settings > Notifications) must be on.
set -eu

if [ "${1:-}" = "--emit" ]; then # internal: report one status from the background tab
	kind=""; [ "$2" = "blocked" ] && kind=":kind=question"
	sleep 1
	printf '\033]7501;state=%s%s:app=ryno-sound\033\\' "$2" "$kind"
	sleep 3
	exit 0
fi

: "${REX_SESSION:?run this in a terminal inside Rex}"
here=$(cd "$(dirname "$0")" && pwd)
out=${RYNO_SOUNDS_DIR:-$HOME/.config/ryno/sounds}
app=$HOME/Applications/RynoCapture.app
bin=$app/Contents/MacOS/capture-sound
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ ! -x "$bin" ] || [ "$here/capture-sound.swift" -nt "$bin" ]; then
	echo "building $app"
	mkdir -p "$app/Contents/MacOS"
	cat >"$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.ryno.capture</string>
<key>CFBundleName</key><string>Ryno Sound Capture</string>
<key>CFBundleExecutable</key><string>capture-sound</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>Ryno records Rex's notification sounds so it can play the same ones.</string>
</dict></plist>
EOF
	swiftc -O -o "$bin" "$here/capture-sound.swift"
	codesign -s - --force "$app" >/dev/null
fi

rex_pid=$(pgrep -f '\.app/Contents/MacOS/Rex$' | head -1)
[ -n "$rex_pid" ] || { echo "Rex app is not running" >&2; exit 1; }
mkdir -p "$out"

record() { # name state
	log=$tmp/$1.out
	: >"$log"
	# A separate app, so macOS asks for (and remembers) the permission for it, not for Rex.
	open -n --stdout "$log" --stderr "$log" "$app" --args "$rex_pid" 8 "$tmp/$1.caf"
	sleep 3
	w=$(rex window new -s "$REX_SESSION" ryno-sound --focus=false --json -- sh "$here/record-rex-sounds.sh" --emit "$2" | jq -r .window_id)
	for _ in $(seq 1 20); do grep -q '^peak' "$log" && break; sleep 0.5; done
	rex window close -s "$REX_SESSION" "$w" >/dev/null 2>&1 || true
	if ! grep -q '^start' "$log"; then
		echo "$1: no audio captured. Allow \"Ryno Sound Capture\" under System Settings > Privacy & Security >" >&2
		echo "  Screen & System Audio Recording (System Audio Recording Only), check Rex plays sounds, and retry." >&2
		cat "$log" >&2
		return 1
	fi
	afconvert -f WAVE -d LEI16 "$tmp/$1.caf" "$tmp/$1.wav"
	python3 - "$tmp/$1.wav" "$tmp/$1-trim.wav" <<'EOF'
import struct, sys, wave
w = wave.open(sys.argv[1])
rate, n, ch, sw = w.getframerate(), w.getnframes(), w.getnchannels(), w.getsampwidth()
frames = w.readframes(n)
data = struct.unpack("<%dh" % (n * ch), frames)
loud = [i for i in range(n) if max(abs(data[i * ch + c]) for c in range(ch)) > 0.002 * 32768]
if not loud:
    sys.exit("silence")
start, end = max(0, loud[0] - rate // 200), min(n, loud[-1] + rate // 10)
o = wave.open(sys.argv[2], "wb")
o.setnchannels(ch); o.setsampwidth(sw); o.setframerate(rate)
o.writeframes(frames[start * ch * sw:end * ch * sw])
EOF
	afconvert -f caff -d LEI16 "$tmp/$1-trim.wav" "$out/$1.caf"
	echo "saved $out/$1.caf ($(afinfo "$out/$1.caf" | sed -n 's/^estimated duration: //p'))"
	sleep 1
}

record attention blocked
record success done
record error error
