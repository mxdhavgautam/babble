// Records the mic with Apple's voice processing for the demo take, while Babble's meeting mode runs.
//
//     micrec <out.wav> <seconds>
//
// macOS cuts off plain mic readers (ffmpeg included) while a voice-processed reader is running, but a
// second voice-processed reader keeps working. So the take's narration comes from here. Writes
// <out.wav> and <out.wav>.json with `start`, the Unix time of the first sample, for lining it up with
// the video. take.py builds and runs it.
import AVFoundation
import AudioToolbox

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let seconds = Double(CommandLine.arguments[2])!
let rate = 48000.0

/// Samples and the host time of the first one, filled in on Core Audio's thread.
final class Recording: @unchecked Sendable {
    let lock = NSLock()
    var samples: [Float] = []
    var firstHostTime: UInt64 = 0
    var unit: AudioUnit!
    let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 8192)
}
let recording = Recording()
recording.samples.reserveCapacity(Int(rate * (seconds + 5)))

func check(_ step: String, _ status: OSStatus) {
    if status != noErr { FileHandle.standardError.write("micrec: \(step) failed: \(status)\n".data(using: .utf8)!); exit(1) }
}
func set<T: BitwiseCopyable>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: T) {
    var value = value
    check("property \(property)", AudioUnitSetProperty(recording.unit, property, scope, element, &value, UInt32(MemoryLayout<T>.size)))
}

var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
                                            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
var unit: AudioUnit?
check("create", AudioComponentInstanceNew(AudioComponentFindNext(nil, &description)!, &unit))
recording.unit = unit!
let format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                         mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
                                         mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
set(kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1))
set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, format)
set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, format)
set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, UInt32(8192))
set(kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0,
    AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false, mDuckingLevel: .min))
set(kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, AURenderCallbackStruct(inputProc: { _, flags, _, _, _, data in
    if let data { for b in UnsafeMutableAudioBufferListPointer(data) { memset(b.mData, 0, Int(b.mDataByteSize)) } }
    flags.pointee.insert(.unitRenderAction_OutputIsSilence)
    return noErr
}, inputProcRefCon: nil))
set(kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, AURenderCallbackStruct(inputProc: { _, flags, time, bus, frames, _ in
    guard frames <= 8192 else { return kAudio_ParamError }
    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: recording.buffer))
    let status = AudioUnitRender(recording.unit, flags, time, bus, frames, &list)
    guard status == noErr else { return status }
    recording.lock.lock()
    if recording.firstHostTime == 0 { recording.firstHostTime = time.pointee.mHostTime }
    recording.samples.append(contentsOf: UnsafeBufferPointer(start: recording.buffer, count: Int(frames)))
    recording.lock.unlock()
    return noErr
}, inputProcRefCon: nil))
check("initialize", AudioUnitInitialize(recording.unit))
check("start", AudioOutputUnitStart(recording.unit))

Thread.sleep(forTimeInterval: seconds)
AudioOutputUnitStop(recording.unit)

// Host time of the first sample, converted to Unix time.
recording.lock.lock()
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let ago = Double(mach_absolute_time() - recording.firstHostTime) * Double(timebase.numer) / Double(timebase.denom) / 1e9
let start = Date().timeIntervalSince1970 - ago
let file = try AVAudioFile(forWriting: out, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate,
                                                      AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(recording.samples.count))!
pcm.frameLength = AVAudioFrameCount(recording.samples.count)
recording.samples.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
try file.write(from: pcm)
try JSONSerialization.data(withJSONObject: ["start": start, "seconds": Double(recording.samples.count) / rate])
    .write(to: out.appendingPathExtension("json"))
print(String(format: "micrec: %.1f s from %.3f", Double(recording.samples.count) / rate, start))
