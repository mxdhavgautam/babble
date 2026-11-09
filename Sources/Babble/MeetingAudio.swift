import AVFoundation
import CoreAudio

/// Receives captured audio. Called off the main thread; the buffer is only valid during the call.
typealias AudioSink = @Sendable (AVAudioPCMBuffer) -> Void

/// The meeting's mic, with Apple's voice processing on so the other side's voices coming out of the
/// speakers are cancelled instead of transcribed a second time as "Me". Dictation keeps its own
/// capture path, which measured more accurate for close speech.
///
/// This drives the voice processing audio unit directly. AVAudioEngine's voice processing fails to
/// initialize its output node on macOS 27 (error -10875), which left meetings with no Me side.
@MainActor
final class VoiceMic {
    enum Failure: Error { case noUnit, status(String, OSStatus) }

    private var unit: AudioUnit?
    private var input: Unmanaged<MicInput>?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    func start(_ sink: @escaping AudioSink) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw Failure.noUnit }
        var created: AudioUnit?
        try Self.check("create", AudioComponentInstanceNew(component, &created))
        guard let unit = created else { throw Failure.noUnit }
        self.unit = unit
        let input = Unmanaged.passRetained(MicInput(unit: unit, sink: sink))
        self.input = input

        var on: UInt32 = 1
        try Self.set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on)
        var format = input.takeUnretainedValue().buffer.format.streamDescription.pointee
        try Self.set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format)
        try Self.set(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format)
        var maxFrames = MicInput.capacity
        try Self.set(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames)
        // Voice processing lowers other audio by default, which would make the call quieter.
        var ducking = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false, mDuckingLevel: .min)
        try Self.set(unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0, &ducking)
        // The output side has to run for echo cancellation to work. Babble plays silence through it.
        var silence = AURenderCallbackStruct(inputProc: renderSilence, inputProcRefCon: nil)
        try Self.set(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &silence)
        var capture = AURenderCallbackStruct(inputProc: captureMic, inputProcRefCon: input.toOpaque())
        try Self.set(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &capture)

        try Self.check("initialize", AudioUnitInitialize(unit))
        try Self.check("start", AudioOutputUnitStart(unit))
        watchDevices()
    }

    /// Safe to call after a failed or partial `start`.
    func stop() {
        if let deviceListener {
            for var address in Self.deviceAddresses {
                AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, deviceListener)
            }
        }
        deviceListener = nil
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        input?.release()
        input = nil
    }

    private static let deviceAddresses = [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice].map {
        AudioObjectPropertyAddress(mSelector: $0, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    /// The unit opens the default devices when it initializes, so it reopens when they change
    /// (AirPods connecting, a new output) rather than lose the Me side for the rest of the meeting.
    private func watchDevices() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reopen() }
        }
        for var address in Self.deviceAddresses {
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        deviceListener = listener
    }

    private func reopen() {
        guard let unit else { return }
        log.info("Audio devices changed, reopening the meeting mic")
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        do {
            try Self.check("initialize", AudioUnitInitialize(unit))
            try Self.check("start", AudioOutputUnitStart(unit))
        } catch {
            log.error("Reopening the meeting mic failed: \(error)")
        }
    }

    private static func set<T: BitwiseCopyable>(_ unit: AudioUnit, _ property: AudioUnitPropertyID, _ scope: AudioUnitScope,
                               _ element: AudioUnitElement, _ value: inout T) throws {
        try check("property \(property)", AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<T>.size)))
    }

    private static func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else { throw Failure.status(step, status) }
    }
}

// The real-time side of VoiceMic. It lives outside the class so none of it inherits the main actor:
// Swift 6 checks isolation at runtime and traps when Core Audio calls in on its own thread.

/// What the capture callback needs. `VoiceMic` keeps it alive until `stop`.
private final class MicInput: @unchecked Sendable {
    static let capacity: UInt32 = 4096
    let unit: AudioUnit
    let sink: AudioSink
    /// Reused for every callback. The sink copies what it keeps.
    let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!, frameCapacity: capacity)!

    init(unit: AudioUnit, sink: @escaping AudioSink) {
        self.unit = unit
        self.sink = sink
    }
}

/// Pulls the processed mic audio out of the unit and hands it to the sink.
private func captureMic(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                        _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let input = Unmanaged<MicInput>.fromOpaque(refCon).takeUnretainedValue()
    guard frames <= MicInput.capacity else { return kAudio_ParamError }
    input.buffer.frameLength = frames
    let status = AudioUnitRender(input.unit, flags, time, bus, frames, input.buffer.mutableAudioBufferList)
    if status == noErr { input.sink(input.buffer) }
    return status
}

/// Feeds the unit's output side silence.
private func renderSilence(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                           _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                           _ data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    if let data { for buffer in UnsafeMutableAudioBufferListPointer(data) { memset(buffer.mData, 0, Int(buffer.mDataByteSize)) } }
    flags.pointee.insert(.unitRenderAction_OutputIsSilence)
    return noErr
}

/// Everything the Mac plays, through a Core Audio process tap: audio only, so it needs the
/// "System Audio Recording Only" permission rather than screen recording. Without that permission
/// the tap delivers silence instead of failing.
@MainActor
final class SystemAudio {
    enum Failure: Error { case tap, format, device, ioProc(OSStatus) }

    private let system = AudioHardwareSystem.shared
    private let queue = DispatchQueue(label: "dev.babble.system-audio", qos: .userInitiated)
    private var tap: AudioHardwareTap?
    private var device: AudioHardwareAggregateDevice?
    private var ioProc: AudioDeviceIOProcID?

    func start(_ sink: @escaping AudioSink) throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "Babble meeting"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard let tap = try system.makeProcessTap(description: description) else { throw Failure.tap }
        self.tap = tap
        var streamDescription = try tap.format
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { throw Failure.format }

        // A tap is read through a private aggregate device that contains only the tap.
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Babble meeting",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: try tap.uid, kAudioSubTapDriftCompensationKey: true]],
        ]
        guard let device = try system.makeAggregateDevice(description: composition) else { throw Failure.device }
        self.device = device
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, device.id, queue) { @Sendable _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            sink(buffer)
        }
        guard status == noErr, let ioProc else { throw Failure.ioProc(status) }
        try device.start(IOProcID: ioProc)
    }

    /// Safe to call after a failed or partial `start`.
    func stop() {
        if let device {
            if let ioProc {
                try? device.stop(IOProcID: ioProc)
                AudioDeviceDestroyIOProcID(device.id, ioProc)
            }
            try? system.destroyAggregateDevice(device)
        }
        if let tap { try? system.destroyProcessTap(tap) }
        ioProc = nil
        device = nil
        tap = nil
    }
}
