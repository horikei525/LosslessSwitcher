//
//  AudioPluginBridge.swift
//  LosslessSwitcher
//
//  Created by GitHub Copilot on behalf of the user.
//
//  Bridge between the C++ Audio Server Plugin and Swift code.
//  C++ Audio Server Plugin と Swift コード間のブリッジ。

import Foundation
import CoreAudioTypes
import CoreAudio
import AppKit

// Bridging header declaration for C++ interop
// C++ 相互運用性のためのブリッジングヘッダー宣言
// (This would normally be in a bridging header file)

@MainActor
class AudioPluginBridge: ObservableObject {
    @Published var lastDetectedSampleRate: Double = 44100.0
    @Published var lastDetectedBitDepth: UInt32 = 16
    @Published var lastDetectedProcessID: pid_t = 0
    @Published var lastDetectedBundleID: String = ""
    
    static let shared = AudioPluginBridge()
    
    private var sampleRateChangeCallback: ((SampleRateChangeInfo) -> Void)?
    private var isPluginLoaded = false
    
    /// Information about a detected sample rate change
    /// 検出されたサンプルレート変更に関する情報
    struct SampleRateChangeInfo {
        let processID: pid_t
        let bundleID: String
        let newSampleRate: Double
        let bitDepth: UInt32
        let timestamp: Date
    }
    
    private init() {
        initializePlugin()
    }
    
    /// Initialize the Audio Server Plugin
    /// Audio Server Plugin を初期化
    private func initializePlugin() {
        // In a real implementation, this would load and initialize the plugin
        // 実装では、プラグインをロードして初期化します
        
        DispatchQueue.global().async {
            // Simulate plugin loading for now
            // 現在のところ、プラグインロードをシミュレート
            print("[AudioPluginBridge] Plugin initialization in progress...")
            
            // Register callback with the C++ plugin
            // C++ プラグインにコールバックを登録
            // LosslessSwitcherPlugin_RegisterSampleRateCallback(
            //     audioPluginSampleRateCallback,
            //     Unmanaged.passUnretained(self).toOpaque()
            // )
            
            DispatchQueue.main.async {
                self.isPluginLoaded = true
                print("[AudioPluginBridge] Plugin initialized successfully")
            }
        }
    }
    
    /// Register a callback to receive sample rate change notifications
    /// サンプルレート変更通知を受け取るコールバックを登録
    func registerSampleRateChangeCallback(_ callback: @escaping (SampleRateChangeInfo) -> Void) {
        self.sampleRateChangeCallback = callback
    }
    
    /// Called by the C++ plugin when sample rate changes
    /// サンプルレート変更時に C++ プラグインから呼ばれる
    @MainActor
    func onSampleRateChanged(processID: pid_t, bundleID: String, newSampleRate: Double, bitDepth: UInt32) {
        let info = SampleRateChangeInfo(
            processID: processID,
            bundleID: bundleID,
            newSampleRate: newSampleRate,
            bitDepth: bitDepth,
            timestamp: Date()
        )
        
        // Update published properties
        // 公開プロパティを更新
        self.lastDetectedProcessID = processID
        self.lastDetectedBundleID = bundleID
        self.lastDetectedSampleRate = newSampleRate
        self.lastDetectedBitDepth = bitDepth
        
        // Call registered callback
        // 登録されたコールバックを呼び出す
        self.sampleRateChangeCallback?(info)
        
        print("[AudioPluginBridge] Sample rate changed: \(info)")
    }
    
    /// Get current device info from the plugin
    /// プラグインから現在のデバイス情報を取得
    func getCurrentDeviceInfo() -> (sampleRate: Double, bitDepth: UInt32) {
        // In production, this would query the C++ plugin
        // 本番環境では、C++ プラグインをクエリします
        return (lastDetectedSampleRate, lastDetectedBitDepth)
    }
    
    /// Check if the plugin is loaded and ready
    /// プラグインがロードされて準備完了か確認
    func isReady() -> Bool {
        return isPluginLoaded
    }
}

// MARK: - C++ Callback Bridge

/// Objective-C compatible callback wrapper for the C++ plugin
/// C++ プラグイン用の Objective-C 互換コールバックラッパー

fileprivate func audioPluginSampleRateCallback(
    clientPID: pid_t,
    bundleID: UnsafePointer<CChar>?,
    newSampleRate: Float64,
    bitDepth: UInt32
) {
    // Resolve the real bundle ID using NSRunningApplication on macOS
    // NSRunningApplication を使用して実際のバンドルIDを解決します
    let resolvedBundleID = NSRunningApplication(processIdentifier: clientPID)?.bundleIdentifier
        ?? bundleID.map { String(cString: $0) }
        ?? "unknown"
    
    Task { @MainActor in
        AudioPluginBridge.shared.onSampleRateChanged(
            processID: clientPID,
            bundleID: resolvedBundleID,
            newSampleRate: newSampleRate,
            bitDepth: bitDepth
        )
    }
}
