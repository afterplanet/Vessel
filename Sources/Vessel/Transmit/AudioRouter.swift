import AVFoundation
import CoreAudio

struct AudioOutput: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
}

/// Sends generated signals, or the Mac's microphone, to the radio's audio input.
/// Nothing plays unless a device was chosen on purpose, so it can't reach the speakers by accident.
@MainActor
final class AudioRouter {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var micEngine: AVAudioEngine?

    static func outputs() -> [AudioOutput] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var n: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &n) == noErr, n > 0 else { return nil }
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &name) == noErr, let cf = name else { return nil }
            return AudioOutput(id: id, name: cf.takeRetainedValue() as String)
        }
    }

    private func makeEngine(device: AudioDeviceID, format: AVAudioFormat, volume: Float) throws -> (AVAudioEngine, AVAudioPlayerNode) {
        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        e.attach(p)
        e.connect(p, to: e.mainMixerNode, format: format)
        e.mainMixerNode.outputVolume = volume
        guard let unit = e.outputNode.audioUnit else { throw RigError(message: "No audio output") }
        var dev = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw RigError(message: "Could not open that audio output") }
        e.prepare()
        try e.start()
        return (e, p)
    }

    /// Plays once, calling `finished` on the main actor when the last sample has gone out.
    func play(_ samples: [Float], device: AudioDeviceID, volume: Float = 1, finished: @escaping @MainActor () -> Void) throws {
        stop()
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: AudioSignals.sampleRate, channels: 1),
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw RigError(message: "Nothing to send")
        }
        buf.frameLength = buf.frameCapacity
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let (e, p) = try makeEngine(device: device, format: format, volume: volume)
        engine = e
        player = p
        p.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { _ in
            Task { @MainActor in finished() }
        }
        p.play()
    }

    /// Passes the default microphone to the chosen output until `stop()`. macOS needs two
    /// engines for this, because one engine can't span separate input and output devices.
    func startMic(device: AudioDeviceID) async throws {
        stop()
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw RigError(message: "Microphone access is off") }
        let mic = AVAudioEngine()
        let format = mic.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw RigError(message: "No microphone") }
        let (e, p) = try makeEngine(device: device, format: format, volume: 1)
        mic.inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            p.scheduleBuffer(buffer, completionHandler: nil)
        }
        mic.prepare()
        try mic.start()
        p.play()
        engine = e
        player = p
        micEngine = mic
    }

    func stop() {
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }
}
