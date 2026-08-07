//
//  MenuView.swift
//  LosslessSwitcher
//
//  Created by Vincent Neo on 23/6/25.
//

import SwiftUI

struct MenuView: View {
    
    @EnvironmentObject private var outputDevices: OutputDevices
    @EnvironmentObject private var defaults: Defaults
    
    var body: some View {
        VStack {
            ContentView()
            
            Divider()
            
            Button {
                defaults.userPreferIconStatusBarItem.toggle()
            } label: {
                Text(defaults.statusBarItemTitle)
            }
            
            Button {
                defaults.userPreferBitDepthDetection.toggle()
            } label: {
                HStack {
                    Text("Bit Depth Switching".localized)
                    if defaults.userPreferBitDepthDetection {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Button {
                defaults.userPreferSampleRateMultiples.toggle()
            } label: {
                HStack {
                    Text("Prefer Closest Sample Rate Multiple".localized)
                    if defaults.userPreferSampleRateMultiples {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Button {
                defaults.userPreferMidSongUpgrades.toggle()
            } label: {
                HStack {
                    Text("Follow Quality Upgrades Mid-Song (Causes Interruption)".localized)
                    if defaults.userPreferMidSongUpgrades {
                        Image(systemName: "checkmark")
                    }
                }
            }
            
            Menu {
                Button {
                    outputDevices.selectedOutputDevice = nil
                    defaults.selectedDeviceUID = nil
                } label: {
                    if outputDevices.selectedOutputDevice == nil {
                        Image(systemName: "checkmark")
                    }
                    Text("Default Device".localized)
                }

                ForEach(outputDevices.outputDevices, id: \.uid) { device in
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
                Text("Selected Device".localized)
            }
            
            Menu {
                Text(String(format: "%@ - %@", "Version".localized, currentVersion))
                Text(String(format: "%@ - %@", "Build".localized, currentBuild))
            } label: {
                Text("About".localized)
            }
            
            Button {
                UpdateChecker.shared.checkForUpdates(manually: true)
            } label: {
                Text("Check for Updates...".localized)
            }
            
            Menu {
                Button("Select Script...".localized) {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.message = "Select a script that should be invoked when sample rate changes.".localized
                    
                    panel.begin { response in
                        let path = panel.url?.path
                        DispatchQueue.main.async { [weak defaults] in
                            defaults?.shellScriptPath = path
                        }
                    }
                }
                
                Button("Clear Selection".localized) {
                    defaults.shellScriptPath = nil
                }
                
                Text(defaults.shellScriptPath ?? "No selection".localized)
                
            } label: {
                Text("Scripting".localized)
            }
            
            Button {
                NSApp.terminate(self)
            } label: {
                Text("Quit LosslessSwitcher".localized)
            }
        }
    }
}
