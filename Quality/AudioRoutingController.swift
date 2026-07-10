//
//  AudioRoutingController.swift
//  LosslessSwitcher
//
//  Created by Antigravity on 2026-07-05.
//
//  Handles audio source tracking, priority routing, and DAC format switching.
//  オーディオソースの追跡、優先順位ルーティング、およびDACフォーマットの切り替えを処理します。

import Foundation
import AppKit
import CoreAudioTypes
import SimplyCoreAudio
import UserNotifications
import Combine

struct AudioSource: Identifiable, Equatable {
    let id = UUID()
    let pid: Int
    let bundleID: String?
    let appName: String
    var sampleRate: Double
    var bitDepth: Int
    var sourceURL: String?
    let isNotificationSource: Bool
    var priority: Int

    var displayName: String {
        if let url = sourceURL, !url.isEmpty {
            return "\(appName) (\(url))"
        }
        return appName
    }

    var readableSampleRate: String {
        return String(format: "%.1f kHz", sampleRate / 1000)
    }

    var readableBitDepth: String {
        return "\(bitDepth) bit"
    }
}

@MainActor
class AudioRoutingController: ObservableObject {
    @Published var prioritySources: [AudioSource] = []
    @Published var virtualDeviceStatus: String = "Proxy idle"
    @Published var activeSampleRate: Double = 44100
    @Published var activeBitDepth: Int = 16
    @Published var isManualRoutingPaused: Bool = false

    private let outputDevices: OutputDevices
    private let defaults = Defaults.shared
    private var virtualProxy: VirtualAudioProxy?
    private var cancellables = Set<AnyCancellable>()
    
    // CoreAudio manager for device discovery
    // デバイス検出用のCoreAudioマネージャー
    private let coreAudio = SimplyCoreAudio()

    init(outputDevices: OutputDevices) {
        self.outputDevices = outputDevices
        
        // Register callback to receive sample rate changes from the Audio Plugin
        // Audio Plugin からサンプルレート変更通知を受け取るコールバックを登録
        AudioPluginBridge.shared.registerSampleRateChangeCallback { [weak self] info in
            Task { @MainActor in
                self?.onAudioSourceDetected(info)
            }
        }
        
        // Observe and dynamically start/stop proxy based on Low Latency Mode preference.
        // This avoids launching the proxy and requesting microphone permissions when low latency direct mode is preferred.
        defaults.$userPreferLowLatencyMode
            .sink { [weak self] preferLowLatency in
                guard let self = self else { return }
                if preferLowLatency {
                    if let proxy = self.virtualProxy {
                        print("[AudioRoutingController] Low Latency Mode enabled. Stopping proxy...")
                        proxy.stop()
                        self.virtualProxy = nil
                    }
                } else {
                    if self.virtualProxy == nil {
                        print("[AudioRoutingController] Normal Mode enabled. Starting proxy...")
                        let proxy = VirtualAudioProxy(outputDevices: self.outputDevices)
                        self.virtualProxy = proxy
                        proxy.startProxy()
                    }
                }
            }
            .store(in: &cancellables)
        
        // Request notification authorization for conflict alerts
        // 競合警告用の通知権限を要求します
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        virtualDeviceStatus = NSLocalizedString("Audio Plugin initialized, waiting for input...", comment: "オーディオプラグインが初期化されました。入力を待機中...")
    }

    /// Sort sources by user prioritized list first, then priority index.
    /// ユーザー優先リスト順、次に優先インデックス順でソースをソートします。
    var rankedSources: [AudioSource] {
        prioritySources.sorted { lhs, rhs in
            let lhsKey = lhs.bundleID ?? lhs.appName
            let rhsKey = rhs.bundleID ?? rhs.appName
            
            let lhsIndex = defaults.userPrioritizedAppList.firstIndex(of: lhsKey) ?? Int.max
            let rhsIndex = defaults.userPrioritizedAppList.firstIndex(of: rhsKey) ?? Int.max
            
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }
            return lhs.priority < rhs.priority
        }
    }

    /// Register/update audio source.
    /// オーディオソースを登録または更新します。
    func addOrUpdateSource(pid: Int,
                           bundleID: String?,
                           appName: String,
                           sampleRate: Double,
                           bitDepth: Int,
                           sourceURL: String? = nil,
                           isNotificationSource: Bool = false) {
        guard !defaults.userPreferMuteNotifications || !isNotificationSource else {
            // If mute notifications is enabled, ignore notification sources.
            // 通知音のミュートが有効な場合、通知音ソースは無視する。
            return
        }

        let key = bundleID ?? appName
        
        // Add to priority defaults if not already registered.
        // 未登録の場合は優先度リストのデフォルトに追加します。
        if !defaults.userPrioritizedAppList.contains(key) {
            var currentPriorities = defaults.userPrioritizedAppList
            currentPriorities.append(key)
            defaults.userPrioritizedAppList = currentPriorities
        }

        if let index = prioritySources.firstIndex(where: { $0.pid == pid && $0.bundleID == bundleID }) {
            prioritySources[index].sampleRate = sampleRate
            prioritySources[index].bitDepth = bitDepth
            prioritySources[index].sourceURL = sourceURL
            
            let display = prioritySources[index].displayName
            virtualDeviceStatus = String(format: NSLocalizedString("Updated %@", comment: "%@ を更新しました"), display)
        } else {
            let priority = (prioritySources.map { $0.priority }.max() ?? 0) + 1
            let source = AudioSource(pid: pid,
                                     bundleID: bundleID,
                                     appName: appName,
                                     sampleRate: sampleRate,
                                     bitDepth: bitDepth,
                                     sourceURL: sourceURL,
                                     isNotificationSource: isNotificationSource,
                                     priority: priority)
            prioritySources.append(source)
            virtualDeviceStatus = String(format: NSLocalizedString("Added %@", comment: "%@ を追加しました"), source.displayName)
        }

        self.routeAudioIfNeeded()
    }

    func removeSource(pid: Int, bundleID: String?) {
        prioritySources.removeAll { $0.pid == pid && $0.bundleID == bundleID }
        virtualDeviceStatus = String(format: NSLocalizedString("Removed source for pid %d", comment: "pid %d のソースを削除しました"), pid)
        self.routeAudioIfNeeded()
    }

    /// Helper to control Apple Music app playback status via AppleScript.
    private func controlMusicApp(action: String) {
        let scriptSource = "tell application \"Music\" to \(action)"
        print("[AudioRoutingController] Executing AppleScript: \(scriptSource)")
        if let script = NSAppleScript(source: scriptSource) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error = error {
                print("[AudioRoutingController] AppleScript error during \(action): \(error)")
            } else {
                print("[AudioRoutingController] AppleScript \(action) command sent successfully.")
            }
        }
    }

    /// Auto routing execution.
    /// 自動ルーティング処理を実行します。
    func routeAudioIfNeeded() {
        // Skip notification sources when switching DAC sample rates.
        // DACのサンプルレートを変更する際は、通知音ソースをスキップします。
        guard !isManualRoutingPaused,
              let source = rankedSources.first(where: { !$0.isNotificationSource }) else {
            virtualDeviceStatus = NSLocalizedString("No active sources", comment: "アクティブなソースがありません")
            return
        }

        let currentRate = activeSampleRate
        let currentBitDepth = activeBitDepth
        let newRate = source.sampleRate
        let newBitDepth = source.bitDepth

        activeSampleRate = newRate
        activeBitDepth = newBitDepth
        
        let routingMsg = String(format: NSLocalizedString("Routing %@ at %@ / %@", comment: "%@ を %@ / %@ でルーティング中"),
                                source.displayName, source.readableSampleRate, source.readableBitDepth)
        virtualDeviceStatus = routingMsg

        // If sample rate or bit depth actually changed, perform a clean pause-switch-play transition
        if currentRate != newRate || currentBitDepth != newBitDepth {
            print("[AudioRoutingController] Format change detected (\(currentRate)Hz/\(currentBitDepth)bit -> \(newRate)Hz/\(newBitDepth)bit). Performing clean transition...")
            
            // 1. Pause Apple Music
            controlMusicApp(action: "pause")
            
            // 2. Wait for playback to pause, then switch hardware and proxy formats
            let pauseDelay = 0.15
            print("[AudioRoutingController] Waiting \(pauseDelay)s for Apple Music to pause and clear audio output buffer...")
            DispatchQueue.main.asyncAfter(deadline: .now() + pauseDelay) { [weak self] in
                guard let self = self else { return }
                
                if !self.defaults.userPreferLowLatencyMode {
                    print("[AudioRoutingController] Low Latency Mode is OFF. Updating VirtualAudioProxy target format...")
                    self.virtualProxy?.prepareBufferedTransition(sampleRate: newRate, bitDepth: newBitDepth)
                } else {
                    print("[AudioRoutingController] Low Latency Mode is ON. Skipping VirtualAudioProxy update.")
                }
                
                if let device = self.outputDevices.selectedOutputDevice ?? self.outputDevices.defaultOutputDevice,
                   let format = self.findBestFormat(for: device, sampleRate: newRate, bitDepth: newBitDepth) {
                    print("[AudioRoutingController] Selected Output Device: \(device.name) (ID: \(device.id))")
                    print("[AudioRoutingController] Target Format: \(format.mSampleRate)Hz / \(format.mBitsPerChannel)bit")
                    
                    self.outputDevices.setFormats(device: device, format: format)
                    self.outputDevices.updateSampleRate(newRate, bitDepth: newBitDepth)
                    self.syncBlackHoleFormat(sampleRate: newRate)
                    print("[AudioRoutingController] Hardware output device formats updated successfully.")
                } else {
                    print("[AudioRoutingController] Warning: Could not find suitable format or selected device.")
                }
                
                // 3. Wait for hardware clock to stabilize, then resume Apple Music
                let stabilizeDelay = 0.8
                print("[AudioRoutingController] Waiting \(stabilizeDelay)s for DAC clock to stabilize before resuming...")
                DispatchQueue.main.asyncAfter(deadline: .now() + stabilizeDelay) { [weak self] in
                    print("[AudioRoutingController] DAC clock stabilized. Resuming Apple Music.")
                    self?.controlMusicApp(action: "play")
                }
            }
        } else {
            // No format change, just update proxy if running
            print("[AudioRoutingController] Format unchanged (\(newRate)Hz/\(newBitDepth)bit). Keeping active configuration.")
            if !defaults.userPreferLowLatencyMode {
                virtualProxy?.prepareBufferedTransition(sampleRate: newRate, bitDepth: newBitDepth)
            }
        }
    }
    
    /// Sync BlackHole virtual device sample rate.
    /// BlackHole仮想デバイスのサンプルレートを同期します。
    private func syncBlackHoleFormat(sampleRate: Double) {
        if let blackHole = coreAudio.allDevices.first(where: { $0.name.localizedCaseInsensitiveContains("BlackHole") }) {
            print("[AudioRoutingController] Syncing BlackHole to \(sampleRate) Hz")
            blackHole.setNominalSampleRate(sampleRate)
        }
    }

    /// Re-order priority list.
    /// 優先順位リストを並び替えます。
    func moveSource(_ source: AudioSource, up: Bool) {
        let key = source.bundleID ?? source.appName
        var currentList = defaults.userPrioritizedAppList
        
        // Ensure the active key is in the priority list.
        // アクティブキーが優先度リストに存在することを確認します。
        if !currentList.contains(key) {
            currentList.append(key)
        }
        
        guard let index = currentList.firstIndex(of: key) else { return }
        let targetIndex = up ? max(index - 1, 0) : min(index + 1, currentList.count - 1)
        if index == targetIndex { return }
        
        currentList.swapAt(index, targetIndex)
        defaults.userPrioritizedAppList = currentList
        routeAudioIfNeeded()
    }

    func toggleManualRoutingPause() {
        isManualRoutingPaused.toggle()
        virtualDeviceStatus = isManualRoutingPaused ?
            NSLocalizedString("Manual routing paused", comment: "手動ルーティング一時停止中") :
            NSLocalizedString("Auto routing enabled", comment: "自動ルーティング有効")
        if !isManualRoutingPaused {
            routeAudioIfNeeded()
        }
    }

    func openAudioMIDISetup() {
        let appURL = URL(fileURLWithPath: "/Applications/Utilities/Audio MIDI Setup.app")
        NSWorkspace.shared.open(appURL)
    }

    func checkForUpdates() {
        UpdateChecker.shared.checkForUpdates(currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0")
    }

    private func findBestFormat(for device: AudioDevice,
                                sampleRate: Double,
                                bitDepth: Int) -> AudioStreamBasicDescription? {
        let streams = device.streams(scope: .output)
        let availableFormats = streams?.first?.availablePhysicalFormats?.compactMap { $0.mFormat }
        
        guard let formats = availableFormats, !formats.isEmpty else {
            return nil
        }
        
        let candidate = formats.min(by: { lhs, rhs in
            let lhsDelta = self.calculateFormatDelta(lhs, targetRate: sampleRate, targetBitDepth: bitDepth)
            let rhsDelta = self.calculateFormatDelta(rhs, targetRate: sampleRate, targetBitDepth: bitDepth)
            return lhsDelta < rhsDelta
        })
        return candidate
    }
    
    private func calculateFormatDelta(_ format: AudioStreamBasicDescription,
                                     targetRate: Double,
                                     targetBitDepth: Int) -> Double {
        let rateDelta = abs(format.mSampleRate - targetRate)
        let bitDepthDelta = abs(Double(Int32(format.mBitsPerChannel) - Int32(targetBitDepth))) * 10
        return rateDelta + bitDepthDelta
    }
    
    /// Trigger system notification when a format conflict occurs.
    /// フォーマット競合が発生した時にシステム通知をトリガーします。
    private func notifyConflict(activeSource: String, activeRate: String, newSource: String, newRate: String) {
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("Audio Conflict Detected / オーディオ競合検知", comment: "")
        content.body = String(format: NSLocalizedString(
            "Conflict: %@ (%@) vs %@ (%@). Prioritizing %@.",
            comment: ""
        ), activeSource, activeRate, newSource, newRate, activeSource)
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    /// Audio Plugin sample rate change callback handler.
    /// Audio Plugin のサンプルレート変更コールバックハンドラ。
    @MainActor
    private func onAudioSourceDetected(_ info: AudioPluginBridge.SampleRateChangeInfo) {
        let bundleID = info.bundleID
        
        // Define known notification system bundles
        // 既知 of 通知音発信バンドルを定義します
        let notificationBundles = [
            "com.apple.notificationcenterui",
            "com.apple.systempreferences",
            "com.tinyspeck.slackmacgap",
            "com.hnc.Discord"
        ]
        
        let isNotification = notificationBundles.contains(bundleID)
        
        // Mute notification handling: ignore if mute is preferred.
        // 通知ミュート処理: ミュートが優先される場合は無視します。
        if isNotification && defaults.userPreferMuteNotifications {
            return
        }
        
        var appName = bundleID.components(separatedBy: ".").last ?? bundleID
        var sourceURL: String? = nil
        
        // Extract browser web site domain name if source is Safari/Chrome/Arc.
        // ソースがSafari/Chrome/Arcの場合は、ブラウザのウェブサイトドメイン名を抽出します。
        let browserBundles = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser"]
        if browserBundles.contains(bundleID) {
            if let siteName = BrowserTabDetector.shared.getActiveTabInfo(for: bundleID) {
                appName = siteName
                sourceURL = siteName // Use siteName as identifier / 識別子としてサイト名を使用します
            }
        }
        
        // Detect format conflict between the incoming source and current active source.
        // 検出されたソースと現在アクティブなソースの間のフォーマット競合を検出します。
        if !isNotification,
           let active = rankedSources.first(where: { !$0.isNotificationSource }),
           active.pid != Int(info.processID),
           active.sampleRate != info.newSampleRate,
           defaults.enableConflictNotifications {
            
            let activeRateStr = String(format: "%.1f kHz", active.sampleRate / 1000)
            let newRateStr = String(format: "%.1f kHz", info.newSampleRate / 1000)
            notifyConflict(
                activeSource: active.displayName,
                activeRate: activeRateStr,
                newSource: appName,
                newRate: newRateStr
            )
        }
        
        self.addOrUpdateSource(
            pid: Int(info.processID),
            bundleID: sourceURL ?? bundleID, // Use site name or bundle ID / サイト名またはバンドルIDを使用
            appName: appName,
            sampleRate: info.newSampleRate,
            bitDepth: Int(info.bitDepth),
            sourceURL: sourceURL,
            isNotificationSource: isNotification
        )
    }
}
