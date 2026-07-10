//
//  VirtualAudioProxy.swift
//  LosslessSwitcher
//
//  Created by GitHub Copilot on behalf of the user.
//

import Foundation
import CoreAudioTypes
import CoreAudio
import AudioToolbox
import AVFoundation
import SimplyCoreAudio
import Combine

/// A proxy layer that handles real-time audio pass-through from the virtual audio device to the physical output.
class VirtualAudioProxy {
    private let outputDevices: OutputDevices
    private let coreAudio = SimplyCoreAudio()
    
    // We recreate these engines and player node on every sample rate switch to clear internal AVAudioEngine device caches
    private var inputEngine: AVAudioEngine?
    private var outputEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    
    // Pre-roll queue to cushion audio playback and prevent starvation clicking
    private var preRollQueue: [AVAudioPCMBuffer] = []
    private var isPlaying = false
    private let queueLock = NSObject()
    
    private var isRunning = false
    private var activeInputID: AudioDeviceID?
    private var activeOutputID: AudioDeviceID?
    private var activeSampleRate: Double?
    private var cancellables = Set<AnyCancellable>()
    private var pendingRestartWorkItem: DispatchWorkItem?

    init(outputDevices: OutputDevices) {
        self.outputDevices = outputDevices
    }

    func startProxy() {
        print("[VirtualAudioProxy] starting proxy layer")
        requestMicrophonePermission()
        
        DispatchQueue.main.async {
            self.triggerRestart()
        }
    }

    private func requestMicrophonePermission() {
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                print("[VirtualAudioProxy] Microphone permission authorized via AVAudioApplication.")
            case .undetermined:
                print("[VirtualAudioProxy] Requesting microphone permission via AVAudioApplication...")
                AVAudioApplication.requestRecordPermission { granted in
                    print("[VirtualAudioProxy] Microphone permission request complete (AVAudioApplication), granted: \(granted)")
                }
            case .denied:
                print("[VirtualAudioProxy] Warning: Microphone permission is denied via AVAudioApplication.")
            @unknown default:
                break
            }
        } else {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                print("[VirtualAudioProxy] Microphone permission authorized.")
            case .notDetermined:
                print("[VirtualAudioProxy] Requesting microphone permission...")
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    print("[VirtualAudioProxy] Microphone permission request complete, granted: \(granted)")
                }
            case .denied, .restricted:
                print("[VirtualAudioProxy] Warning: Microphone permission is denied or restricted.")
            @unknown default:
                break
            }
        }
    }

    func prepareBufferedTransition(sampleRate: Double, bitDepth: Int) {
        print("[VirtualAudioProxy] preparing buffered transition to \(sampleRate) Hz / \(bitDepth) bit")
        DispatchQueue.main.async {
            self.restartPassThrough(sampleRate: sampleRate)
        }
    }

    private func triggerRestart() {
        let sampleRate = outputDevices.currentSampleRate ?? 44100.0
        self.restartPassThrough(sampleRate: sampleRate)
    }

    func restartPassThrough(sampleRate: Double) {
        // 1. Find the virtual audio device
        guard let virtualDevice = coreAudio.allOutputDevices.first(where: { $0.name == "LosslessSwitcher Virtual Device" }) else {
            print("[VirtualAudioProxy] Warning: LosslessSwitcher Virtual Device not found!")
            stop()
            return
        }

        // 2. Find the physical output device
        var physicalDevice = outputDevices.selectedOutputDevice ?? coreAudio.defaultOutputDevice
        if physicalDevice == virtualDevice {
            physicalDevice = coreAudio.allOutputDevices.first(where: {
                $0 != virtualDevice && !$0.name.localizedCaseInsensitiveContains("BlackHole")
            })
        }

        guard let targetDevice = physicalDevice else {
            print("[VirtualAudioProxy] Warning: No target physical output device found!")
            stop()
            return
        }

        let inputID = virtualDevice.id
        let outputID = targetDevice.id

        // If already running with the same configuration, do nothing
        if isRunning && activeInputID == inputID && activeOutputID == outputID && activeSampleRate == sampleRate {
            return
        }

        stop()

        print("[VirtualAudioProxy] Starting dual AVAudioEngine pass-through (AVAudioPlayerNode Jitter Buffer) from \(virtualDevice.name) to \(targetDevice.name) at \(sampleRate) Hz")

        // Cancel any pending start task to avoid concurrent configuration races
        pendingRestartWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            do {
                // Recreate the engines and player node on every start to clear format caches
                let inEngine = AVAudioEngine()
                let outEngine = AVAudioEngine()
                let pNode = AVAudioPlayerNode()
                
                self.inputEngine = inEngine
                self.outputEngine = outEngine
                self.playerNode = pNode
                
                let outputUnit = outEngine.outputNode.audioUnit!
                AudioUnitUninitialize(outputUnit)

                // Set output device on outputEngine
                var outID = outputID
                var status = AudioUnitSetProperty(
                    outputUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &outID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status != noErr {
                    print("[VirtualAudioProxy] Error setting output device: \(status) (Target ID: \(outputID))")
                    return
                }

                // Set input device on inputEngine
                let inputUnit = inEngine.inputNode.audioUnit!
                AudioUnitUninitialize(inputUnit)
                
                var inID = inputID
                status = AudioUnitSetProperty(
                    inputUnit,
                    AudioUnitPropertyID(kAudioOutputUnitProperty_CurrentDevice),
                    kAudioUnitScope_Global,
                    0,
                    &inID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status != noErr {
                    print("[VirtualAudioProxy] Error setting input device: \(status) (Target ID: \(inputID))")
                    return
                }

                let outputFormat = outEngine.outputNode.inputFormat(forBus: 0)
                guard outputFormat.channelCount > 0 else {
                    print("[VirtualAudioProxy] Error: Invalid channel count on output node")
                    return
                }

                // Retrieve native outputFormat of the input node to prevent mismatch crashes
                let tapFormat = inEngine.inputNode.outputFormat(forBus: 0)
                guard tapFormat.channelCount > 0 else {
                    print("[VirtualAudioProxy] Error: Invalid channel count on input node")
                    return
                }

                // Connect playerNode -> mainMixerNode -> outputNode on outputEngine
                outEngine.attach(pNode)
                outEngine.connect(pNode, to: outEngine.mainMixerNode, format: tapFormat)
                outEngine.connect(outEngine.mainMixerNode, to: outEngine.outputNode, format: outputFormat)

                // Reset pre-roll flags and queues
                objc_sync_enter(self.queueLock)
                self.preRollQueue.removeAll()
                self.isPlaying = false
                objc_sync_exit(self.queueLock)

                // Remove any existing tap to avoid duplication crash
                inEngine.inputNode.removeTap(onBus: 0)

                // Install tap to queue PCM buffers and handle pre-rolling
                let actualSampleRate = sampleRate > 1000 ? sampleRate : sampleRate * 1000.0
                
                inEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, time in
                    guard let self = self else { return }
                    
                    objc_sync_enter(self.queueLock)
                    if !self.isPlaying {
                        self.preRollQueue.append(buffer)
                        
                        // Calculate total frames accumulated in the queue
                        let totalFrames = self.preRollQueue.reduce(0) { $0 + Int($1.frameLength) }
                        // Target a very low latency 0.15 second (150ms) pre-roll buffer
                        let preRollThreshold = Int(actualSampleRate * 0.15)
                        
                        if totalFrames >= preRollThreshold {
                            for buf in self.preRollQueue {
                                pNode.scheduleBuffer(buf)
                            }
                            self.preRollQueue.removeAll()
                            pNode.scheduleBuffer(buffer)
                            pNode.play()
                            self.isPlaying = true
                            print("[VirtualAudioProxy] Pre-roll complete, started playerNode playback (Total Frames: \(totalFrames))")
                        }
                    } else {
                        pNode.scheduleBuffer(buffer)
                    }
                    objc_sync_exit(self.queueLock)
                }

                // Mute inputEngine's mixer output to isolate it from physical DAC.
                inEngine.mainMixerNode.outputVolume = 0.0

                try outEngine.start()
                try inEngine.start()
                
                self.isRunning = true
                self.activeInputID = inputID
                self.activeOutputID = outputID
                self.activeSampleRate = sampleRate
                print("[VirtualAudioProxy] Dual AVAudioEngine pass-through started successfully")
            } catch {
                print("[VirtualAudioProxy] Failed to start engines, retrying... Error: \(error)")
                self.stop()
            }
        }

        pendingRestartWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    func stop() {
        if isRunning {
            inputEngine?.stop()
            outputEngine?.stop()
            
            inputEngine?.inputNode.removeTap(onBus: 0)
            
            playerNode?.stop()
            if let pNode = playerNode {
                outputEngine?.detach(pNode)
            }
            
            inputEngine?.reset()
            outputEngine?.reset()
            
            inputEngine = nil
            outputEngine = nil
            playerNode = nil
            
            objc_sync_enter(queueLock)
            preRollQueue.removeAll()
            isPlaying = false
            objc_sync_exit(queueLock)
            
            isRunning = false
            activeInputID = nil
            activeOutputID = nil
            activeSampleRate = nil
            print("[VirtualAudioProxy] AVAudioEngine pass-through stopped")
        }
    }
}
