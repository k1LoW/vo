import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import AudioToolbox

enum AudioChannel: String, Sendable, CaseIterable {
    case mic
    case speaker
    case file

    var shortLabel: String {
        switch self {
        case .mic:     return "MIC"
        case .speaker: return "SPK"
        case .file:    return "FILE"
        }
    }

    /// Human description used in device-follow notices on stderr.
    var deviceDescription: String {
        switch self {
        case .mic:     return "microphone input device"
        case .speaker: return "system audio output device"
        case .file:    return "input file"
        }
    }

    /// 256-color palette tint for this channel's TTY output (Terminal.app safe).
    /// mic = amber, speaker = teal, file = steel blue. Shared by the live renderer and
    /// the startup banner. The file tint is used only when --input is set; it shows up
    /// on the timestamp column (the [file] label is suppressed since file mode is
    /// always a single channel).
    var tint256: Int {
        switch self {
        case .mic:     return 130
        case .speaker: return 24
        case .file:    return 67
        }
    }
}

/// A captured PCM buffer plus the host time (seconds, mach timebase) of its first sample.
/// The capture layer always supplies it, falling back to `hostTimeNowSeconds()` when the
/// platform timestamp is invalid, so the pipeline can rely on it to align each channel's
/// analyzer timeline onto a shared session axis.
struct TimedBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let hostTime: Double
}

/// Microphone capture using AVAudioEngine.
final class MicCapture: @unchecked Sendable {
    let stream: AsyncStream<TimedBuffer>
    /// Invoked once if the default input device changes out from under the engine.
    var onDeviceLost: (@Sendable () -> Void)?
    private let builder: AsyncStream<TimedBuffer>.Continuation
    private let engine = AVAudioEngine()
    private let voiceProcessing: Bool
    // When set, capture is pinned to this device instead of following the system
    // default input. Pinning also suppresses the default-change listener below.
    private let deviceID: AudioDeviceID?
    private var deviceListener: DefaultDeviceChangeListener?

    init(voiceProcessing: Bool = false, deviceID: AudioDeviceID? = nil) {
        self.voiceProcessing = voiceProcessing
        self.deviceID = deviceID
        let (s, b) = AsyncStream<TimedBuffer>.makeStream()
        self.stream = s
        self.builder = b
    }

    func start() throws {
        // Pipeline.runChannel registers stop() only once start() returns, so unwind any
        // partial setup here before rethrowing, mirroring SpeakerCapture.start().
        do {
            try startUnchecked()
        } catch {
            stop()
            throw error
        }
    }

    private func startUnchecked() throws {
        let inputNode = engine.inputNode

        // Optionally enable system voice processing (echo cancellation + noise reduction + AGC).
        // Trade-off: stops the mic from re-capturing audio from the speaker, but switches the
        // OS audio session to a "communication" mode that attenuates system output volume.
        // Off by default; enable with --voice-processing.
        if voiceProcessing {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
            } catch {
                FileHandle.standardError.write(Data(
                    "vo: warning: voice processing unavailable on mic input, continuing without echo cancellation (\(error.localizedDescription))\n".utf8
                ))
            }
        }

        // Pin the input unit to the chosen device after the voice-processing toggle.
        // Enabling voice processing swaps in a fresh audio unit that would not carry a
        // device set on the previous one, so pinning earlier would be silently dropped.
        // Must still precede reading the input format and engine.start().
        if let deviceID {
            try Self.setInputDevice(deviceID, on: inputNode)
        }

        // A device caught mid-switch (a Bluetooth headset moving between A2DP and HFP
        // above all) reports a placeholder format here that no longer describes the
        // hardware, and installTap answers that by *raising* rather than returning:
        // an NSException no Swift catch can see, which aborts the process mid-session.
        // So reject the obvious placeholder up front and route the install itself
        // through the Objective-C bridge, leaving the caller free to retry once the
        // device settles.
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoError.audioDeviceNotReady(channel: .mic, format: "\(inputFormat)")
        }
        let builder = self.builder
        do {
            try catchingNSException {
                inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, when in
                    // Copy the buffer because installTap reuses the underlying storage.
                    guard let copy = buffer.copy() else { return }
                    // Forward the tap's host time so the pipeline can place this buffer on the
                    // shared session axis. AVAudioTime carries it when isHostTimeValid; fall back to
                    // the current host time otherwise so the value is always present.
                    let hostTime = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : hostTimeNowSeconds()
                    builder.yield(TimedBuffer(buffer: copy, hostTime: hostTime))
                }
            }
        } catch {
            throw VoError.audioTapInstallFailed(channel: .mic, underlying: error)
        }
        try engine.start()

        // The engine stays bound to the input device it started on. If the default
        // input changes (new default selected, current one unplugged), the tap goes
        // quiet with no error, so watch for the change and let the channel stop.
        // Skip this when pinned to an explicit device. The user asked for that device,
        // so a default-input change is theirs to make and should not stop the session.
        if deviceID == nil {
            let listener = DefaultDeviceChangeListener(selector: kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
                self?.onDeviceLost?()
            }
            listener.start()
            self.deviceListener = listener
        }
    }

    /// Pin the AVAudioEngine input node's underlying HAL audio unit to a specific device.
    private static func setInputDevice(_ deviceID: AudioDeviceID, on node: AVAudioInputNode) throws {
        guard let unit = node.audioUnit else {
            throw CoreAudioError(code: kAudioUnitErr_Uninitialized, op: "InputAudioUnit")
        }
        var dev = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &dev,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw CoreAudioError(code: status, op: "SetInputDevice") }
    }

    func stop() {
        deviceListener?.cancel()
        deviceListener = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        builder.finish()
    }
}

/// System audio (speaker) capture using Core Audio process taps (macOS 14.4+).
/// Requires the Audio Recording TCC permission, not Screen Recording: ScreenCaptureKit
/// would force a screen-capture grant even though vo only ever wanted the audio.
final class SpeakerCapture: @unchecked Sendable {
    let stream: AsyncStream<TimedBuffer>
    /// Invoked once if the default output device changes out from under the aggregate.
    var onDeviceLost: (@Sendable () -> Void)?
    private let builder: AsyncStream<TimedBuffer>.Continuation

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var deviceListener: DefaultDeviceChangeListener?
    // When set, the aggregate anchors to this output device instead of the system
    // default. Pinning also suppresses the default-change listener below.
    private let outputDeviceUID: String?
    // Runs the IOProc off Core Audio's real-time IO thread: the block deep-copies
    // and yields into an AsyncStream, neither of which is safe on the RT thread.
    private let ioQueue = DispatchQueue(label: "vo.spk.audio")

    init(outputDeviceUID: String? = nil) {
        self.outputDeviceUID = outputDeviceUID
        let (s, b) = AsyncStream<TimedBuffer>.makeStream()
        self.stream = s
        self.builder = b
    }

    func start() async throws {
        // Any step past the first allocation can throw, and Pipeline.runChannel only
        // registers stop() once start() returns. So clean up partial allocations here
        // before rethrowing, otherwise the tap / aggregate would dangle.
        do {
            try await startUnchecked()
        } catch {
            await stop()
            throw error
        }
    }

    private func startUnchecked() async throws {
        // Global system-output tap. vo never plays audio, so there is nothing of
        // our own to exclude from the mix.
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .unmuted
        tapDescription.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tapDescription, &tap)
        guard status == noErr else { throw CoreAudioError(code: status, op: "CreateProcessTap") }
        self.tapID = tap

        // A process tap carries no clock of its own, so it has to ride an aggregate
        // device anchored to an output device, the pinned one if given, else the
        // current default output.
        let outputUID = try outputDeviceUID ?? defaultOutputDeviceUID()
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "vo-system-tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ]
            ],
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr else { throw CoreAudioError(code: status, op: "CreateAggregateDevice") }
        self.aggregateID = aggregate

        var asbd = try tapStreamFormat(tap)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            throw VoError.noCompatibleAudioFormat
        }

        let builder = self.builder
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, ioQueue) { _, inInputData, inInputTime, _, _ in
            // The no-copy buffer aliases Core Audio's IO memory; downstream consumers
            // run async and must own their data, so deep-copy before yielding.
            guard let aliased = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData),
                  let owned = aliased.copy() else { return }
            // Forward the input timestamp's host time so the pipeline can place this buffer
            // on the shared session axis. Valid when the hostTimeValid flag is set; fall
            // back to the current host time otherwise so the value is always present.
            let ts = inInputTime.pointee
            let hostTime = ts.mFlags.contains(.hostTimeValid) ? AVAudioTime.seconds(forHostTime: ts.mHostTime) : hostTimeNowSeconds()
            builder.yield(TimedBuffer(buffer: owned, hostTime: hostTime))
        }
        guard status == noErr, let procID else {
            throw CoreAudioError(code: status, op: "CreateIOProc")
        }
        self.ioProcID = procID

        status = AudioDeviceStart(aggregate, procID)
        guard status == noErr else { throw CoreAudioError(code: status, op: "DeviceStart") }

        // The aggregate stays anchored to the output device it was built on. If the
        // default output changes, the tap keeps reading a stale (or vanished) device
        // with no error, so watch for the change and let the channel stop.
        // Skip this when pinned to an explicit device. The user asked for that device,
        // so a default-output change is theirs to make and should not stop the session.
        if outputDeviceUID == nil {
            let listener = DefaultDeviceChangeListener(selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
                self?.onDeviceLost?()
            }
            listener.start()
            self.deviceListener = listener
        }
    }

    func stop() async {
        deviceListener?.cancel()
        deviceListener = nil
        if let procID = ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        builder.finish()
    }

    /// UID of the current default output device, used as the aggregate's main sub-device.
    private func defaultOutputDeviceUID() throws -> String {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        try audioObjectProperty(
            AudioObjectID(kAudioObjectSystemObject),
            globalPropertyAddress(kAudioHardwarePropertyDefaultOutputDevice),
            into: &deviceID,
            op: "DefaultOutputDevice"
        )
        return try audioObjectString(
            deviceID,
            globalPropertyAddress(kAudioDevicePropertyDeviceUID),
            op: "OutputDeviceUID"
        )
    }

    /// Stream format the tap delivers, read from the tap object itself.
    private func tapStreamFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var asbd = AudioStreamBasicDescription()
        try audioObjectProperty(
            tap,
            globalPropertyAddress(kAudioTapPropertyFormat),
            into: &asbd,
            op: "TapFormat"
        )
        return asbd
    }
}

/// Fires `onChange` once when the system default input or output device changes, so a
/// capture bound to the old device can stop instead of going silently dead. The OS
/// listener block is installed on the main queue and removed on `cancel()`.
final class DefaultDeviceChangeListener: @unchecked Sendable {
    private let selector: AudioObjectPropertySelector
    private let onChange: @Sendable () -> Void
    private var block: AudioObjectPropertyListenerBlock?
    private var fired = false

    init(selector: AudioObjectPropertySelector, onChange: @escaping @Sendable () -> Void) {
        self.selector = selector
        self.onChange = onChange
    }

    private var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    func start() {
        var addr = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Coalesce to a single shutdown: the default-device property can fire more
            // than once for one switch, and downstream stopAll is idempotent anyway.
            guard let self, !self.fired else { return }
            self.fired = true
            self.onChange()
        }
        self.block = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block
        )
    }

    func cancel() {
        guard let block else { return }
        var addr = address
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block
        )
        self.block = nil
    }
}

struct CoreAudioError: Error, CustomStringConvertible {
    let code: OSStatus
    let op: String
    var description: String { "CoreAudio error (\(op)): \(code)" }
}

extension AVAudioPCMBuffer {
    /// Allocate a deep copy of the buffer. AVAudioEngine reuses its tap buffer; downstream
    /// consumers running async must own their copy.
    func copy() -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
        out.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            let bytes = Int(min(src[i].mDataByteSize, dst[i].mDataByteSize))
            if let s = src[i].mData, let d = dst[i].mData {
                memcpy(d, s, bytes)
            }
        }
        return out
    }
}

/// Audio source backed by an on-disk file. Unlike MicCapture / SpeakerCapture, this is
/// pull-based; the resampler calls `nextBuffer()` per iteration instead of consuming an
/// AsyncStream. The intent is end-to-end backpressure for file mode. A push stream that
/// reads ahead would let memory grow proportionally to (disk-speed − analyzer-speed) ×
/// duration on long files, breaking the "memory stays bounded across long sessions"
/// invariant CLAUDE.md asserts. Pull keeps exactly one decoded buffer alive at a time
/// here and the bounded analyzer-input buffer caps the rest.
///
/// `TimedBuffer.hostTime` is the cumulative playback position on the file's own
/// timeline, so pairing this with `sessionStart = 0` makes `audio.start` in the JSONL
/// the file timecode directly. AVAudioFile accepts anything AudioToolbox can decode
/// (wav, m4a/aac, mp3, caf, …); `processingFormat` is the natural decoded format and
/// the pipeline's AVAudioConverter step resamples it into the SpeechAnalyzer-best
/// format the same way it does for live capture buffers.
final class FileSource: @unchecked Sendable {
    let format: AVAudioFormat
    let durationSeconds: Double
    private let file: AVAudioFile
    private let chunkFrames: AVAudioFrameCount
    private let lock = NSLock()
    private var cursor: Double = 0
    private var stopped = false

    init(url: URL, chunkFrames: AVAudioFrameCount = 4096) throws {
        let f = try AVAudioFile(forReading: url)
        self.file = f
        self.format = f.processingFormat
        self.durationSeconds = f.processingFormat.sampleRate > 0
            ? Double(f.length) / f.processingFormat.sampleRate
            : 0
        self.chunkFrames = chunkFrames
    }

    /// Read and return the next decoded buffer. Returns nil at EOF or after `stop()`.
    /// Throws the underlying error if `AVAudioFile.read` fails mid-stream so the
    /// caller can surface a corrupt / truncated / disconnected-volume failure instead
    /// of silently treating it as EOF.
    func nextBuffer() throws -> TimedBuffer? {
        lock.lock()
        let isStopped = stopped
        lock.unlock()
        if isStopped { return nil }
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return nil }
        try file.read(into: buf, frameCount: chunkFrames)
        if buf.frameLength == 0 { return nil }
        let timed = TimedBuffer(buffer: buf, hostTime: cursor)
        if format.sampleRate > 0 {
            cursor += Double(buf.frameLength) / format.sampleRate
        }
        return timed
    }

    /// Stop further reads. Subsequent `nextBuffer()` calls return nil. Idempotent and
    /// safe to call from any thread (the SIGINT-driven stopper runs on the main queue
    /// while the resampler task reads on its own executor).
    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
