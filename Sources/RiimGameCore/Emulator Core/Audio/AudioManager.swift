//
//  AudioManager.swift
//  DeltaCore
//
//  Created by Riley Testut on 1/12/16.
//  Copyright © 2016 Riley Testut. All rights reserved.
//

@preconcurrency import AVFoundation

internal extension AVAudioFormat {
    var frameSize: Int {
        return Int(self.streamDescription.pointee.mBytesPerFrame)
    }
}

private extension AVAudioSession {
    func setIgnitedCategory(_ micEnabled: Bool = false) throws {
        if micEnabled {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.mixWithOthers, .allowBluetoothA2DP, .allowAirPlay])
        } else {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        }
    }
}

private extension AVAudioSessionRouteDescription {
    var isHeadsetPluggedIn: Bool {
        let isHeadsetPluggedIn = self.outputs.contains { $0.portType == .headphones || $0.portType == .bluetoothA2DP }
        return isHeadsetPluggedIn
    }
    
    var isOutputtingToReceiver: Bool {
        let isOutputtingToReceiver = self.outputs.contains { $0.portType == .builtInReceiver }
        return isOutputtingToReceiver
    }
    
    var isOutputtingToExternalDevice: Bool {
        let isOutputtingToExternalDevice = self.outputs.contains { $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver }
        return isOutputtingToExternalDevice
    }
}

public class AudioManager: NSObject, AudioRendering {
    /// Currently only supports 16-bit interleaved Linear PCM.
    public var audioFormat: AVAudioFormat {
        didSet {
            self.resetAudioEngine()
        }
    }
    
    public var isEnabled = true {
        didSet
        {
            self.audioBuffer.isEnabled = self.isEnabled
            
            self.updateOutputVolume()
            
            do
            {
                if self.isEnabled
                {
                    try self.audioEngine.start()
                }
                else
                {
                    self.audioEngine.pause()
                }
            }
            catch
            {
                print(error)
            }
            
            self.audioBuffer.reset()
        }
    }
    
    public var respectsSilentMode: Bool = true {
        didSet {
            self.updateOutputVolume()
        }
    }
    
    public var playWithOtherMedia: Bool = true {
        didSet {
            self.updateOutputVolume()
        }
    }
    
    public var mutedByFastForward: Bool = false {
        didSet {
            self.updateOutputVolume()
        }
    }
    
    public var isMicEnabled: Bool = false {
        didSet {
            do
            {
                try AVAudioSession.sharedInstance().setIgnitedCategory(self.isMicEnabled)
            }
            catch
            {
                print(error)
            }
        }
    }
    
    public var audioBuffer: RingBuffer
    
    public var rate = 1.0 {
        didSet {
            self.timePitchEffect.rate = Float(self.rate)
        }
    }
    
    public var audioVolume: Float = 1.0 {
        didSet {
            self.updateOutputVolume()
        }
    }
    
    var frameDuration: Double = (1.0 / 60.0) {
        didSet {
            guard self.audioEngine.isRunning else { return }
            self.resetAudioEngine()
        }
    }
    
    private let audioEngine: AVAudioEngine
    private let audioPlayerNode: AVAudioPlayerNode
    private let timePitchEffect: AVAudioUnitTimePitch
    
    private var sourceNode: AVAudioSourceNode {
        get {
            if _sourceNode == nil
            {
                _sourceNode = self.makeSourceNode()
            }
            
            return _sourceNode as! AVAudioSourceNode
        }
        set {
            _sourceNode = newValue
        }
    }
    private var _sourceNode: Any! = nil
    
    private var audioConverter: AVAudioConverter?
    private var audioConverterRequiredFrameCount: AVAudioFrameCount?
    
    private let audioBufferCount = 3
    
    // Used to synchronize access to self.audioPlayerNode without causing deadlocks.
    private let renderingQueue = DispatchQueue(label: "com.litritt.Ignited.AudioManager.renderingQueue")
    
    private var isMuted: Bool = false {
        didSet {
            self.updateOutputVolume()
        }
    }
            
    public init(audioFormat: AVAudioFormat) {
        self.audioFormat = audioFormat
        
        // Temporary. Will be replaced with more accurate RingBuffer in resetAudioEngine().
        self.audioBuffer = RingBuffer(preferredBufferSize: 4096)!
        
        do {
            // Set category before configuring AVAudioEngine to prevent pausing any currently playing audio from another app.
            try AVAudioSession.sharedInstance().setIgnitedCategory(self.isMicEnabled)
        } catch {
            print(error)
        }
        
        self.audioEngine = AVAudioEngine()
        
        self.audioPlayerNode = AVAudioPlayerNode()
        self.audioEngine.attach(self.audioPlayerNode)
        
        self.timePitchEffect = AVAudioUnitTimePitch()
        self.audioEngine.attach(self.timePitchEffect)
        
        super.init()
        
        self.audioEngine.attach(self.sourceNode)
        
        self.updateOutputVolume()
        
        NotificationCenter.default.addObserver(self, selector: #selector(AudioManager.resetAudioEngine), name: .AVAudioEngineConfigurationChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(AudioManager.resetAudioEngine), name: AVAudioSession.routeChangeNotification, object: nil)
    }
}

public extension AudioManager {
    func start() {
        do {
            try AVAudioSession.sharedInstance().setIgnitedCategory(self.isMicEnabled)
        } catch {
            print(error)
        }
        
        do {
            try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.005)
            try AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print(error)
        }
        
        self.resetAudioEngine()
    }
    
    func stop() {
        
        self.renderingQueue.sync {
            self.audioPlayerNode.stop()
            self.audioEngine.stop()
        }
        
        self.audioBuffer.isEnabled = false
    }
}

private extension AudioManager {
    func render(_ inputBuffer: AVAudioPCMBuffer, into outputBuffer: AVAudioPCMBuffer) {
        guard let buffer = inputBuffer.int16ChannelData, let audioConverter = self.audioConverter else { return }
        
        // Ensure any buffers from previous audio route configurations are no longer processed.
        guard inputBuffer.format == audioConverter.inputFormat && outputBuffer.format == audioConverter.outputFormat else { return }
        
        if self.audioConverterRequiredFrameCount == nil {
            // Determine the minimum number of input frames needed to perform a conversion.
            audioConverter.convert(to: outputBuffer, error: nil) { (requiredPacketCount, outStatus) -> AVAudioBuffer? in
                // In Linear PCM, one packet = one frame.
                self.audioConverterRequiredFrameCount = requiredPacketCount
                
                // Setting to ".noDataNow" sometimes results in crash, so we set to ".endOfStream" and reset audioConverter afterwards.
                outStatus.pointee = .endOfStream
                return nil
            }
            
            audioConverter.reset()
        }
        
        guard let audioConverterRequiredFrameCount = self.audioConverterRequiredFrameCount else { return }
        
        let availableFrameCount = AVAudioFrameCount(self.audioBuffer.availableBytesForReading / self.audioFormat.frameSize)
        if self.audioEngine.isRunning && availableFrameCount >= audioConverterRequiredFrameCount
        {            
            var conversionError: NSError?
            let status = audioConverter.convert(to: outputBuffer, error: &conversionError) { (requiredPacketCount, outStatus) -> AVAudioBuffer? in
                
                // Copy requiredPacketCount frames into inputBuffer's first channel (since audio is interleaved, no need to modify other channels).
                let preferredSize = min(Int(requiredPacketCount) * self.audioFormat.frameSize, Int(inputBuffer.frameCapacity) * self.audioFormat.frameSize)
                buffer[0].withMemoryRebound(to: UInt8.self, capacity: preferredSize) { (uint8Buffer) in
                    let readBytes = self.audioBuffer.read(into: uint8Buffer, preferredSize: preferredSize)
                    
                    let frameLength = AVAudioFrameCount(readBytes / self.audioFormat.frameSize)
                    inputBuffer.frameLength = frameLength
                }
                
                if inputBuffer.frameLength == 0
                {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                else
                {
                    outStatus.pointee = .haveData
                    return inputBuffer
                }
            }
            
            if status == .error
            {
                if let error = conversionError
                {
                    print(error, error.userInfo)
                }
            }
        }
        else
        {
            // If not running or not enough input frames, set frameLength to 0 to minimize time until we check again.
            inputBuffer.frameLength = 0
        }
        
        self.audioPlayerNode.scheduleBuffer(outputBuffer) { [weak self, weak node = audioPlayerNode] in
            guard let self = self else { return }
            
            self.renderingQueue.async {
                if node?.isPlaying == true
                {
                    self.render(inputBuffer, into: outputBuffer)
                }
            }
        }
    }
    
    @objc func resetAudioEngine()
    {
        self.renderingQueue.sync {
            self.audioPlayerNode.reset()
            
            guard let outputAudioFormat = AVAudioFormat(standardFormatWithSampleRate: AVAudioSession.sharedInstance().sampleRate, channels: self.audioFormat.channelCount) else { return }
            
            let inputAudioBufferFrameCount = Int(self.audioFormat.sampleRate * self.frameDuration)
//            let outputAudioBufferFrameCount = Int(outputAudioFormat.sampleRate * self.frameDuration)
            
            // Allocate enough space to prevent us from overwriting data before we've used it.
            let ringBufferAudioBufferCount = Int((self.audioFormat.sampleRate / outputAudioFormat.sampleRate).rounded(.up) + 10.0)
            
            let preferredBufferSize = inputAudioBufferFrameCount * self.audioFormat.frameSize * ringBufferAudioBufferCount
            guard let ringBuffer = RingBuffer(preferredBufferSize: preferredBufferSize) else {
                fatalError("Cannot initialize RingBuffer with preferredBufferSize of \(preferredBufferSize)")
            }
            self.audioBuffer = ringBuffer
            
            let audioConverter = AVAudioConverter(from: self.audioFormat, to: outputAudioFormat)
            self.audioConverter = audioConverter
            
            self.audioConverterRequiredFrameCount = nil
            
            self.audioEngine.disconnectNodeOutput(self.timePitchEffect)
            self.audioEngine.connect(self.timePitchEffect, to: self.audioEngine.mainMixerNode, format: outputAudioFormat)

            self.audioEngine.detach(self.sourceNode)
            
            self.sourceNode = self.makeSourceNode()
            self.audioEngine.attach(self.sourceNode)
            
            self.audioEngine.connect(self.sourceNode, to: self.timePitchEffect, format: outputAudioFormat)
            
            do
            {
                // Explicitly set output port since .defaultToSpeaker option pauses external audio.
                if AVAudioSession.sharedInstance().currentRoute.isOutputtingToReceiver
                {
                    try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
                }
                
                try self.audioEngine.start()
            }
            catch
            {
                print(error)
            }
        }
    }
    
    @objc func updateOutputVolume()
    {
        if !self.isEnabled || self.mutedByFastForward
        {
            self.audioEngine.mainMixerNode.outputVolume = 0.0
        }
        else
        {
            let route = AVAudioSession.sharedInstance().currentRoute
            
            if AVAudioSession.sharedInstance().isOtherAudioPlaying && !self.playWithOtherMedia
            {
                // Mute if another app is playing audio and the user has chosen to.
                self.audioEngine.mainMixerNode.outputVolume = 0.0
            }
            else if self.respectsSilentMode
            {
                if self.isMuted && (route.isHeadsetPluggedIn || !route.isOutputtingToExternalDevice)
                {
                    // Respect mute switch if playing through speaker or headphones.
                    self.audioEngine.mainMixerNode.outputVolume = 0.0
                }
                else
                {
                    // Ignore mute switch for other audio routes (e.g. AirPlay).
                    self.audioEngine.mainMixerNode.outputVolume = self.audioVolume >= 0.0 && self.audioVolume <= 1.0 ? self.audioVolume : 1.0
                }
            }
            else
            {
                // Ignore silent mode and always play game audio (unless another app is playing audio).
                self.audioEngine.mainMixerNode.outputVolume = self.audioVolume >= 0.0 && self.audioVolume <= 1.0 ? self.audioVolume : 1.0
            }
        }
    }
    
    func makeSourceNode() -> AVAudioSourceNode
    {
        var isPrimed = false
        var previousSampleCount: Int?
        
        // Accessing AVAudioSession.sharedInstance() from render block may cause audio glitches,
        // so calculate sampleRateRatio now rather than later when needed 🤷‍♂️
        let sampleRateRatio = (self.audioFormat.sampleRate / AVAudioSession.sharedInstance().sampleRate).rounded(.up)
        
        let sourceNode = AVAudioSourceNode(format: self.audioFormat) { [audioFormat, audioBuffer] (_, _, frameCount, audioBufferList) -> OSStatus in
            defer { previousSampleCount = audioBuffer.availableBytesForReading }
            
            let unsafeAudioBufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let buffer = unsafeAudioBufferList[0].mData else { return kAudioFileStreamError_UnspecifiedError }
            
            let requestedBytes = Int(frameCount) * audioFormat.frameSize
            
            if !isPrimed
            {
                // Make sure audio buffer has enough initial samples to prevent audio distortion.
                
                guard audioBuffer.availableBytesForReading >= requestedBytes * Int(sampleRateRatio) else { return kAudioFileStreamError_DataUnavailable }
                isPrimed = true
            }
            
            if let previousSampleCount = previousSampleCount, audioBuffer.availableBytesForReading < previousSampleCount
            {
                // Audio buffer has been reset, so we need to prime it again.
                
                isPrimed = false
                return kAudioFileStreamError_DataUnavailable
            }
            
            guard audioBuffer.availableBytesForReading >= requestedBytes else {
                isPrimed = false
                return kAudioFileStreamError_DataUnavailable
            }
                        
            let readBytes = audioBuffer.read(into: buffer, preferredSize: requestedBytes)
            unsafeAudioBufferList[0].mDataByteSize = UInt32(readBytes)
            
            return noErr
        }
        
        return sourceNode
    }
}
