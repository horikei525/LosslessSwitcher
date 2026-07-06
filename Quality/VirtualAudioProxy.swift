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
    private let engine = AVAudioEngine()
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
        DispatchQueue.main.async {
            self.triggerRestart()
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

        print("[VirtualAudioProxy] Starting AVAudioEngine pass-through from virtual device (\(virtualDevice.name)) to physical device (\(targetDevice.name)) at \(sampleRate) Hz")

        let inputUnit = engine.inputNode.audioUnit!
        let outputUnit = engine.outputNode.audioUnit!

        // Set input device on the engine's input node
        var inID = inputID
        var status = AudioUnitSetProperty(
            inputUnit,
            AudioUnitPropertyID(kAudioOutputUnitProperty_CurrentDevice),
            kAudioUnitScope_Global,
            0,
            &inID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            print("[VirtualAudioProxy] Error setting input device: \(status)")
            return
        }

        // Set output device on the engine's output node
        var outID = outputID
        status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &outID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            print("[VirtualAudioProxy] Error setting output device: \(status)")
            return
        }

        // Connect nodes with standard stereo format at target sample rate
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 2,
                                         interleaved: false) else {
            print("[VirtualAudioProxy] Error creating audio format")
            return
        }

        engine.connect(engine.inputNode, to: engine.outputNode, format: format)

        do {
            try engine.start()
            isRunning = true
            activeInputID = inputID
            activeOutputID = outputID
            activeSampleRate = sampleRate
            print("[VirtualAudioProxy] AVAudioEngine pass-through started successfully")
        } catch {
            print("[VirtualAudioProxy] Failed to start AVAudioEngine: \(error)")
        }
    }

    func stop() {
        if isRunning {
            engine.stop()
            engine.reset()
            isRunning = false
            activeInputID = nil
            activeOutputID = nil
            activeSampleRate = nil
            print("[VirtualAudioProxy] AVAudioEngine pass-through stopped")
        }
    }
}
