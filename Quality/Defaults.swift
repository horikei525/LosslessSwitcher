//
//  Defaults.swift
//  Quality
//
//  Created by Vincent Neo on 23/4/22.
//

import Foundation

class Defaults: ObservableObject {
    static let shared = Defaults()
    private let kUserPreferIconStatusBarItem = "com.vincent-neo.LosslessSwitcher-Key-UserPreferIconStatusBarItem"
    private let kSelectedDeviceUID = "com.vincent-neo.LosslessSwitcher-Key-SelectedDeviceUID"
    private let kUserPreferBitDepthDetection = "com.vincent-neo.LosslessSwitcher-Key-BitDepthDetection"
    private let kShellScriptPath = "KeyShellScriptPath"
    private let kUserPreferSampleRateMultiples = "PreferSampleRateMultiples"
    private let kUserPreferLowLatencyMode = "PreferLowLatencyMode"
    private let kUserPreferMuteNotifications = "PreferMuteNotifications"
    private let kUserPreferAutoUpdateCheck = "PreferAutoUpdateCheck"
    private let kUserPrioritizedAppList = "com.vincent-neo.LosslessSwitcher-Key-UserPrioritizedAppList"
    private let kEnableConflictNotifications = "com.vincent-neo.LosslessSwitcher-Key-EnableConflictNotifications"
    private let kBlockAlertsOnVirtualDevice = "com.vincent-neo.LosslessSwitcher-Key-BlockAlertsOnVirtualDevice"
    
    private init() {
        UserDefaults.standard.register(defaults: [
            kUserPreferIconStatusBarItem : true,
            kUserPreferBitDepthDetection : false,
            kUserPreferSampleRateMultiples : false,
            kUserPreferLowLatencyMode : true,
            kUserPreferMuteNotifications : false,
            kUserPreferAutoUpdateCheck : true,
            kUserPrioritizedAppList : ["com.apple.Music", "com.spotify.client", "company.thebrowser.Browser", "com.google.Chrome", "com.apple.Safari"],
            kEnableConflictNotifications : true,
            kBlockAlertsOnVirtualDevice : false
        ])
        
        self.shellScriptPath = UserDefaults.standard.string(forKey: kShellScriptPath)
        self.userPreferIconStatusBarItem = UserDefaults.standard.bool(forKey: kUserPreferIconStatusBarItem)
        self.userPreferBitDepthDetection = UserDefaults.standard.bool(forKey: kUserPreferBitDepthDetection)
        self.userPreferSampleRateMultiples = UserDefaults.standard.bool(forKey: kUserPreferSampleRateMultiples)
        self.userPreferLowLatencyMode = UserDefaults.standard.bool(forKey: kUserPreferLowLatencyMode)
        self.userPreferMuteNotifications = UserDefaults.standard.bool(forKey: kUserPreferMuteNotifications)
        self.userPreferAutoUpdateCheck = UserDefaults.standard.bool(forKey: kUserPreferAutoUpdateCheck)
        self.userPrioritizedAppList = UserDefaults.standard.stringArray(forKey: kUserPrioritizedAppList) ?? []
        self.enableConflictNotifications = UserDefaults.standard.bool(forKey: kEnableConflictNotifications)
        self.blockAlertsOnVirtualDevice = UserDefaults.standard.bool(forKey: kBlockAlertsOnVirtualDevice)
        
        // Post initial state to the plugin on startup
        let userInfo = ["blockAlerts": self.blockAlertsOnVirtualDevice] as NSDictionary
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.vincent-neo.LosslessSwitcher.BlockAlertsChanged"),
            object: nil,
            userInfo: userInfo as? [AnyHashable : Any],
            deliverImmediately: true
        )
    }
    
    @Published var userPreferIconStatusBarItem: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferIconStatusBarItem)
        }
    }
    
    var selectedDeviceUID: String? {
        get {
            return UserDefaults.standard.string(forKey: kSelectedDeviceUID)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: kSelectedDeviceUID)
        }
    }
    
    @Published var shellScriptPath: String? {
        willSet {
            UserDefaults.standard.setValue(newValue, forKey: kShellScriptPath)
        }
    }
    
    @Published var userPreferSampleRateMultiples: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferSampleRateMultiples)
        }
    }
    
    @Published var userPreferLowLatencyMode: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferLowLatencyMode)
        }
    }
    
    @Published var userPreferMuteNotifications: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferMuteNotifications)
        }
    }
    
    @Published var userPreferAutoUpdateCheck: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPreferAutoUpdateCheck)
        }
    }
    
    @Published var userPrioritizedAppList: [String] {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kUserPrioritizedAppList)
        }
    }
    
    @Published var enableConflictNotifications: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kEnableConflictNotifications)
        }
    }
    
    @Published var blockAlertsOnVirtualDevice: Bool {
        willSet {
            UserDefaults.standard.set(newValue, forKey: kBlockAlertsOnVirtualDevice)
            let userInfo = ["blockAlerts": newValue] as NSDictionary
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.vincent-neo.LosslessSwitcher.BlockAlertsChanged"),
                object: nil,
                userInfo: userInfo as? [AnyHashable : Any],
                deliverImmediately: true
            )
        }
    }
    
    @Published var userPreferBitDepthDetection: Bool
    
    
    @MainActor func setPreferBitDepthDetection(newValue: Bool) {
        UserDefaults.standard.set(newValue, forKey: kUserPreferBitDepthDetection)
        self.userPreferBitDepthDetection = newValue
    }
    
    @MainActor func setShellScriptPath(newValue: String?) {
        self.shellScriptPath = newValue
    }
    
    @MainActor func setPreferSampleRateMultiple(newValue: Bool) {
        self.userPreferSampleRateMultiples = newValue
    }

    var statusBarItemTitle: String {
        let title = self.userPreferIconStatusBarItem ? "Show Sample Rate" : "Show Icon"
        return title
    }
}
