// Record what one process (or the whole system) plays, using a Core Audio process tap (macOS 14.4+).
// Used to save Rex's synthesized program-activity sounds so ryno can play the same sound.
//
//   capture-sound <pid|all> <seconds> <out.caf>
//
// Prints "start <unix time>" when audio starts arriving, then "peak <level>" at the end, so callers
// can line the recording up with events they triggered. Needs the "System Audio Recording" permission;
// without it the tap delivers silence (peak 0).
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

func fail(_ msg: String) -> Never {
	FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
	exit(1)
}

func check(_ status: OSStatus, _ what: String) {
	if status != noErr { fail("\(what) failed: \(status)") }
}

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
	AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

func processObject(for pid: pid_t) -> AudioObjectID {
	var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
	var pid = pid
	var object = AudioObjectID(kAudioObjectUnknown)
	var size = UInt32(MemoryLayout<AudioObjectID>.size)
	check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object), "translate pid")
	if object == kAudioObjectUnknown { fail("process \(pid) has no audio object (has it played audio yet?)") }
	return object
}

func defaultOutputUID() -> String {
	var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
	var device = AudioObjectID(kAudioObjectUnknown)
	var size = UInt32(MemoryLayout<AudioObjectID>.size)
	check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device), "default output device")
	var uidAddr = address(kAudioDevicePropertyDeviceUID)
	var uid: Unmanaged<CFString>?
	size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
	check(AudioObjectGetPropertyData(device, &uidAddr, 0, nil, &size, &uid), "output device UID")
	return uid!.takeRetainedValue() as String
}

let args = CommandLine.arguments
guard args.count == 4, let seconds = Double(args[2]) else { fail("usage: capture-sound <pid|all> <seconds> <out.caf>") }
let outURL = URL(fileURLWithPath: args[3])

let tap: CATapDescription
if args[1] == "all" {
	tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
} else if let pid = pid_t(args[1]) {
	tap = CATapDescription(stereoMixdownOfProcesses: [processObject(for: pid)])
} else {
	fail("bad pid: \(args[1])")
}
tap.uuid = UUID()
tap.isPrivate = true
tap.muteBehavior = .unmuted

var tapID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(tap, &tapID), "create process tap")

var formatAddr = address(kAudioTapPropertyFormat)
var asbd = AudioStreamBasicDescription()
var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
check(AudioObjectGetPropertyData(tapID, &formatAddr, 0, nil, &asbdSize, &asbd), "tap format")
guard let format = AVAudioFormat(streamDescription: &asbd) else { fail("unsupported tap format") }

let outputUID = defaultOutputUID()
let aggregate: [String: Any] = [
	kAudioAggregateDeviceNameKey: "ryno-capture",
	kAudioAggregateDeviceUIDKey: UUID().uuidString,
	kAudioAggregateDeviceMainSubDeviceKey: outputUID,
	kAudioAggregateDeviceIsPrivateKey: true,
	kAudioAggregateDeviceIsStackedKey: false,
	kAudioAggregateDeviceTapAutoStartKey: true,
	kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
	kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tap.uuid.uuidString]],
]
var deviceID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID), "create aggregate device")

let file: AVAudioFile
do {
	file = try AVAudioFile(forWriting: outURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
} catch {
	fail("open \(outURL.path): \(error)")
}

var started = false
var peak: Float = 0
let queue = DispatchQueue(label: "ryno.capture")
var procID: AudioDeviceIOProcID?
check(AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { _, input, _, _, _ in
	if !started {
		started = true
		print(String(format: "start %.3f", Date().timeIntervalSince1970))
		fflush(stdout)
	}
	guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
	if let channels = buffer.floatChannelData {
		let stride = buffer.stride
		for c in 0..<Int(format.channelCount) {
			for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[c][i * stride])) }
		}
	}
	try? file.write(from: buffer)
}, "create IO proc")

check(AudioDeviceStart(deviceID, procID), "start device")
Thread.sleep(forTimeInterval: seconds)
AudioDeviceStop(deviceID, procID)
queue.sync {}
AudioDeviceDestroyIOProcID(deviceID, procID!)
AudioHardwareDestroyAggregateDevice(deviceID)
AudioHardwareDestroyProcessTap(tapID)
print(String(format: "peak %.4f", peak))
