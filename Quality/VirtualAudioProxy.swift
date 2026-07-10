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
/// 仮想オーディオデバイスから物理出力へのリアルタイムオーディオパススルーを処理するプロキシレイヤー。
class VirtualAudioProxy {
    private let outputDevices: OutputDevices
    private let coreAudio = SimplyCoreAudio()
    
    // Use two engines to avoid the macOS limitation where a single AVAudioEngine cannot easily
    // handle separate input and output hardware devices without aggregate setups.
    private let inputEngine = AVAudioEngine()
    private let outputEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    
    private var isRunning = false
    private var activeInputID: AudioDeviceID?
    private var activeOutputID: AudioDeviceID?
    private var activeSampleRate: Double?
    private var cancellables = Set<AnyCancellable>()

    init(outputDevices: OutputDevices) {
        self.outputDevices = outputDevices
        
        // Observe output device selection changes to restart pass-through
        // パススルーを再起動するために出力デバイスの選択変更を監視
        outputDevices.$selectedOutputDevice
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.triggerRestart()
                }
            }
            .store(in: &cancellables)
            
        // Observe current sample rate changes to update pass-through format
        // パススルーフォーマットを更新するために現在のサンプルレート変更を監視
        outputDevices.$currentSampleRate
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.triggerRestart()
                }
            }
            .store(in: &cancellables)
    }

    func startProxy() {
        print("[VirtualAudioProxy] starting proxy layer")
        
        // Request microphone permission on startup to ensure loopback capture is allowed by the OS
        // ループバック録音がOSによって許可されるように起動時にマイク権限を要求します
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
                print("[VirtualAudioProxy] Warning: Microphone permission is denied via AVAudioApplication. Pass-through might output silence.")
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
                print("[VirtualAudioProxy] Warning: Microphone permission is denied or restricted. Pass-through might output silence.")
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
        // 1. 仮想オーディオデバイスを検索
        guard let virtualDevice = coreAudio.allOutputDevices.first(where: { $0.name == "LosslessSwitcher Virtual Device" }) else {
            print("[VirtualAudioProxy] Warning: LosslessSwitcher Virtual Device not found!")
            stop()
            return
        }

        // 2. Find the physical output device (user selected, or default)
        // 2. 物理出力デバイスを検索 (ユーザー選択、またはデフォルト)
        var physicalDevice = outputDevices.selectedOutputDevice ?? coreAudio.defaultOutputDevice
        if physicalDevice == virtualDevice {
            // Fallback to a non-virtual device if the default/selected is the virtual device itself
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
        // すでに同じ設定で動作している場合は何もしない
        if isRunning && activeInputID == inputID && activeOutputID == outputID && activeSampleRate == sampleRate {
            return
        }

        stop()

        print("[VirtualAudioProxy] Starting dual AVAudioEngine pass-through from \(virtualDevice.name) to \(targetDevice.name) at \(sampleRate) Hz")

        let outputUnit = outputEngine.outputNode.audioUnit!
        AudioUnitUninitialize(outputUnit)

        // 1. Set output device on outputEngine's output node
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

        // 2. Set input device on inputEngine's input node
        let inputUnit = inputEngine.inputNode.audioUnit!
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

        // Connect playerNode -> mainMixerNode -> outputNode on outputEngine.
        outputEngine.attach(playerNode)
        
        let inputFormat = inputEngine.inputNode.inputFormat(forBus: 0)
        let outputFormat = outputEngine.outputNode.inputFormat(forBus: 0)

        guard inputFormat.channelCount > 0, outputFormat.channelCount > 0 else {
            print("[VirtualAudioProxy] Error: Invalid channel count on nodes (Input: \(inputFormat.channelCount), Output: \(outputFormat.channelCount))")
            return
        }

        outputEngine.connect(playerNode, to: outputEngine.mainMixerNode, format: inputFormat)
        outputEngine.connect(outputEngine.mainMixerNode, to: outputEngine.outputNode, format: outputFormat)

        // Remove any existing tap first to avoid crash if a tap is already installed due to asynchronous scheduling
        inputEngine.inputNode.removeTap(onBus: 0)

        // Install tap on inputEngine's inputNode to capture loopback audio from virtual device
        inputEngine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
            guard let self = self else { return }
            if self.playerNode.isPlaying {
                self.playerNode.scheduleBuffer(buffer)
            }
        }

        // Delay starting the engines slightly to let CoreAudio adjust the hardware sample rate.
        // ハードウェア側のサンプリングレート設定が安定するのを待つために少し遅延させてから開始します。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            do {
                try self.outputEngine.start()
                self.playerNode.play()
                
                try self.inputEngine.start()
                
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
    }

    func stop() {
        if isRunning || playerNode.isPlaying {
            playerNode.stop()
            inputEngine.stop()
            outputEngine.stop()
            
            inputEngine.inputNode.removeTap(onBus: 0)
            
            inputEngine.reset()
            outputEngine.reset()
            
            isRunning = false
            activeInputID = nil
            activeOutputID = nil
            activeSampleRate = nil
            print("[VirtualAudioProxy] AVAudioEngine pass-through stopped")
        }
    }
}
