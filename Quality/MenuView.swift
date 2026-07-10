//
//  MenuView.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 23/6/25.
//  Updated by Antigravity on 2026-07-05.
//
//  Defines the primary SwiftUI layout for the Menu Bar dropdown.
//  メニューバードロップダウンのプライマリSwiftUIレイアウトを定義します。

import SwiftUI
import CoreAudioTypes

struct AudioFormatItem: Identifiable, Hashable {
    let id: String
    let sampleRate: Double
    let bitDepth: Int
    let format: AudioStreamBasicDescription

    static func == (lhs: AudioFormatItem, rhs: AudioFormatItem) -> Bool {
        return lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct MenuView: View {
    @EnvironmentObject private var outputDevices: OutputDevices
    @EnvironmentObject private var audioRoutingController: AudioRoutingController
    @EnvironmentObject private var defaults: Defaults
    
    @ObservedObject private var updateChecker = UpdateChecker.shared
    
    // Fetch and wrap available formats for manual selection.
    // 手動選択用に利用可能なフォーマットを取得してラップします。
    private var availableFormats: [AudioFormatItem] {
        guard let device = outputDevices.selectedOutputDevice ?? outputDevices.defaultOutputDevice,
              let streams = device.streams(scope: .output),
              let formats = streams.first?.availablePhysicalFormats?.compactMap({ $0.mFormat }) else {
            return []
        }
        
        // Filter duplicate rates/depths and sort.
        // 重複するレート/深度をフィルタリングしてソートします。
        var seen = Set<String>()
        var items = [AudioFormatItem]()
        
        for format in formats {
            let key = "\(format.mSampleRate)-\(format.mBitsPerChannel)"
            if !seen.contains(key) {
                seen.insert(key)
                let item = AudioFormatItem(
                    id: key,
                    sampleRate: format.mSampleRate,
                    bitDepth: Int(format.mBitsPerChannel),
                    format: format
                )
                items.append(item)
            }
        }
        
        return items.sorted { lhs, rhs in
            if lhs.sampleRate != rhs.sampleRate {
                return lhs.sampleRate < rhs.sampleRate
            }
            return lhs.bitDepth < rhs.bitDepth
        }
    }
    
    var body: some View {
        VStack {
            ContentView()
            
            Divider()
            
            Button {
                defaults.userPreferIconStatusBarItem.toggle()
            } label: {
                Text(defaults.userPreferIconStatusBarItem ? "ステータスバー：サンプルレートを表示 / Show Sample Rate" : "ステータスバー：アイコンを表示 / Show Icon")
            }
            
            Button {
                defaults.userPreferBitDepthDetection.toggle()
            } label: {
                HStack {
                    Text("ビット深度の自動検出 / Bit Depth Switching")
                    if defaults.userPreferBitDepthDetection {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Button {
                defaults.userPreferSampleRateMultiples.toggle()
            } label: {
                HStack {
                    Text("最も近い倍数のサンプルレートを優先 / Prefer Closest Multiple")
                    if defaults.userPreferSampleRateMultiples {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Button {
                defaults.userPreferLowLatencyMode.toggle()
            } label: {
                HStack {
                    Text("超低遅延モード (ゲーミング) / Low Latency Mode")
                    if defaults.userPreferLowLatencyMode {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Button {
                defaults.userPreferMuteNotifications.toggle()
            } label: {
                HStack {
                    Text("通知音をミュート / Mute Notification Sounds")
                    if defaults.userPreferMuteNotifications {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Button {
                defaults.enableConflictNotifications.toggle()
            } label: {
                HStack {
                    Text("フォーマット競合時に通知 / Notify on Audio Conflict")
                    if defaults.enableConflictNotifications {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Button {
                audioRoutingController.toggleManualRoutingPause()
            } label: {
                HStack {
                    Text(audioRoutingController.isManualRoutingPaused ? "自動ルーティングを再開 / Resume Auto Routing" : "自動ルーティングを停止 / Pause Auto Routing")
                    if audioRoutingController.isManualRoutingPaused {
                        Image(systemName: "pause.circle")
                    }
                }
            }
            
            Text("仮想デバイスステータス / Virtual Device Status")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(audioRoutingController.virtualDeviceStatus)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            Divider()

            Group {
                Text("優先度ランキング / Active Sources & Priorities")
                    .font(.headline)
                if audioRoutingController.rankedSources.isEmpty {
                    Text("アクティブな音源がありません / No active sources")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(audioRoutingController.rankedSources) { source in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.displayName)
                                    .font(.subheadline)
                                Text("\(source.readableSampleRate) · \(source.readableBitDepth)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            VStack(spacing: 4) {
                                Button(action: {
                                    audioRoutingController.moveSource(source, up: true)
                                }) {
                                    Image(systemName: "arrow.up")
                                }
                                Button(action: {
                                    audioRoutingController.moveSource(source, up: false)
                                }) {
                                    Image(systemName: "arrow.down")
                                }
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                }
            }

            Divider()

            Menu {
                Button {
                    outputDevices.selectedOutputDevice = nil
                    defaults.selectedDeviceUID = nil
                } label: {
                    if outputDevices.selectedOutputDevice == nil {
                        Image(systemName: "checkmark")
                    }
                    Text("デフォルトのデバイス / Default Device")
                }

                ForEach(outputDevices.outputDevices.filter({ $0.name != "LosslessSwitcher Virtual Device" }), id: \.uid) { device in
                    Button {
                        outputDevices.selectedOutputDevice = device
                        defaults.selectedDeviceUID = device.uid
                    } label: {
                        Text(device.name)
                        if outputDevices.selectedOutputDevice?.uid == device.uid {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                Text("出力デバイスの選択 / Selected Device")
            }
            
            // Manual format selector submenu.
            // 手動フォーマット変更サブメニュー。
            Menu {
                if availableFormats.isEmpty {
                    Text("変更可能なフォーマットがありません / No formats available")
                } else {
                    ForEach(availableFormats) { item in
                        Button {
                            if let device = outputDevices.selectedOutputDevice ?? outputDevices.defaultOutputDevice {
                                outputDevices.setFormats(device: device, format: item.format)
                                outputDevices.updateSampleRate(item.sampleRate, bitDepth: item.bitDepth)
                            }
                        } label: {
                            HStack {
                                Text(String(format: "%.1f kHz · %d bit", item.sampleRate / 1000, item.bitDepth))
                                if item.sampleRate == outputDevices.currentSampleRate && item.bitDepth == outputDevices.currentBitDepth {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                Text("手動フォーマット変更 / Set Format Manually")
            }
            
            Menu {
                Text("プラグイン状態 / Plugin Status: \(audioRoutingController.virtualDeviceStatus)")
                    .font(.caption)
                
                Divider()
                
                Text("仮想デバイス設定 / Virtual Device Config")
                    .font(.caption)
                    .fontWeight(.semibold)
                
                Button("プラグインの再初期化 / Re-initialize Plugin") {
                    audioRoutingController.virtualDeviceStatus = "Plugin re-initializing..."
                }
                
                Button("オーディオMIDI設定を開く / Show Audio MIDI Setup") {
                    audioRoutingController.openAudioMIDISetup()
                }
                
                Toggle("通知音デバイスへの設定を防止 / Block Alert Device Registration", isOn: $defaults.blockAlertsOnVirtualDevice)
                
            } label: {
                Text("仮想デバイス設定 / Virtual Device")
            }
            
            Menu {
                Text("バージョン / Version - \(currentVersion)")
                Text("ビルド / Build - \(currentBuild)")
                
                Divider()
                
                Button("アップデートを確認 / Check for Updates") {
                    audioRoutingController.checkForUpdates()
                }
                
                if !updateChecker.updateStatus.isEmpty {
                    Text(updateChecker.updateStatus)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } label: {
                Text("アプリについて / About")
            }
            
            Menu {
                Button("スクリプトを選択... / Select Script...") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.message = "サンプルレート変更時に呼び出すスクリプトを選択してください / Select a script to run on sample rate change."
                    
                    panel.begin { response in
                        let path = panel.url?.path
                        DispatchQueue.main.async { [weak defaults] in
                            defaults?.shellScriptPath = path
                        }
                    }
                }
                
                Button("選択をクリア / Clear Selection") {
                    defaults.shellScriptPath = nil
                }
                
                Text(defaults.shellScriptPath ?? "未選択 / No selection")
                
            } label: {
                Text("スクリプティング / Scripting")
            }
            
            Button {
                NSApp.terminate(self)
            } label: {
                Text("LosslessSwitcherを終了 / Quit")
            }
        }
    }
}
