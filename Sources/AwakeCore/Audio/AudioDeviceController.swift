import Foundation
import CoreAudio
import AudioToolbox

/// Snapshot of a CoreAudio output device.
public struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    public var id: AudioDeviceID
    public var name: String
    public var uid: String
    public var sampleRate: Double
    public var channels: Int
    public var transportType: UInt32
    public var isDefault: Bool

    public var isHeadphones: Bool {
        let lower = name.lowercased()
        let hints = ["headphone", "airpods", "earphone", "earbuds", "wh-", "wf-", "hd ", "momentum", "quietcomfort", "bose", "sony", "sennheiser", "耳机"]
        if hints.contains(where: { lower.contains($0) }) { return true }
        // Bluetooth devices are overwhelmingly personal audio devices.
        return transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    public var transportLabel: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: return "内置"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "蓝牙"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeAggregate: return "聚合"
        case kAudioDeviceTransportTypeVirtual: return "虚拟"
        default: return "音频"
        }
    }
}

/// Thin, dependency-free wrapper over the handful of CoreAudio properties Awake needs:
/// default device, nominal sample rate, hog mode and hardware volume.
public enum AudioDeviceController {

    // MARK: - Device lookup

    public static func defaultOutputDevice() -> AudioOutputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { return nil }
        return describe(deviceID, isDefault: true)
    }

    public static func describe(_ deviceID: AudioDeviceID, isDefault: Bool = false) -> AudioOutputDevice? {
        guard let name = stringProperty(deviceID, kAudioObjectPropertyName) else { return nil }
        let uid = stringProperty(deviceID, kAudioDevicePropertyDeviceUID) ?? ""
        let rate = nominalSampleRate(deviceID) ?? 44100
        let channels = outputChannelCount(deviceID)
        let transport = uint32Property(deviceID, kAudioDevicePropertyTransportType) ?? 0
        return AudioOutputDevice(id: deviceID, name: name, uid: uid, sampleRate: rate,
                                 channels: channels, transportType: transport, isDefault: isDefault)
    }

    public static func outputDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        let defaultID = defaultOutputDevice()?.id
        return ids.compactMap { id in
            guard outputChannelCount(id) > 0 else { return nil }
            return describe(id, isDefault: id == defaultID)
        }
    }

    public static func outputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - Sample rate

    public static func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    public static func availableSampleRates(_ deviceID: AudioDeviceID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ranges) == noErr else { return [] }
        var values: [Double] = []
        for range in ranges {
            if range.mMinimum == range.mMaximum { values.append(range.mMinimum) }
            else { values.append(contentsOf: [range.mMinimum, range.mMaximum]) }
        }
        return Array(Set(values)).sorted()
    }

    @discardableResult
    public static func setSampleRate(_ rate: Double, deviceID: AudioDeviceID) -> Bool {
        guard availableSampleRates(deviceID).contains(where: { abs($0 - rate) < 1 }) else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = rate
        let size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        return status == noErr
    }

    // MARK: - Hog mode (exclusive access)

    public static func isHogged(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = pid_t(-1)
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &pid) == noErr else { return false }
        return pid == getpid()
    }

    @discardableResult
    public static func setHogMode(_ enabled: Bool, deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyHogMode,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = enabled ? getpid() : pid_t(-1)
        let size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &pid) == noErr
    }

    // MARK: - Hardware volume

    public static func volume(_ deviceID: AudioDeviceID) -> Float? {
        for (selector, element) in volumeCandidates {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr { return value }
        }
        return nil
    }

    @discardableResult
    public static func setVolume(_ value: Float, deviceID: AudioDeviceID) -> Bool {
        for (selector, element) in volumeCandidates {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var scalar = max(0, min(1, value))
            let size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &scalar) == noErr { return true }
        }
        return false
    }

    private static var volumeCandidates: [(AudioObjectPropertySelector, AudioObjectPropertyElement)] {
        [(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyElementMain),
         (kAudioDevicePropertyVolumeScalar, 1),
         (kAudioDevicePropertyVolumeScalar, 2),
         (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyElementMain)]
    }

    // MARK: - Default device change notifications

    public static func observeDefaultDeviceChange(_ handler: @escaping () -> Void) -> AudioObjectPropertyListenerBlock? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let queue = DispatchQueue.main
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        return status == noErr ? block : nil
    }

    public static func removeDefaultDeviceObserver(_ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    // MARK: - Generic property helpers

    private static func stringProperty(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String
    }

    private static func uint32Property(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }
}
