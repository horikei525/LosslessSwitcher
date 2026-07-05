//
//  BrowserTabDetector.swift
//  LosslessSwitcher
//
//  Created by Antigravity on 2026-07-05.
//
//  Detects active web domains/tabs from browsers using AppleScript.
//  AppleScriptを使用してブラウザからアクティブなウェブドメイン/タブを検出します。

import Foundation
import Cocoa

class BrowserTabDetector {
    static let shared = BrowserTabDetector()
    
    private init() {}
    
    /// Queries the active tab URL and title from running browsers.
    /// 起動中のブラウザからアクティブなタブのURLとタイトルをクエリします。
    /// - Parameter bundleID: The bundle identifier of the browser. / ブラウザのバンドルID。
    /// - Returns: A formatted string containing the website name or domain. / ウェブサイト名またはドメインを含む整形された文字列。
    func getActiveTabInfo(for bundleID: String) -> String? {
        let appName: String
        let scriptSource: String
        
        switch bundleID {
        case "com.apple.Safari":
            appName = "Safari"
            scriptSource = """
            tell application "Safari"
                if (count of windows) > 0 then
                    tell current tab of front window
                        return URL & "|" & name
                    end tell
                end if
            end tell
            """
        case "com.google.Chrome":
            appName = "Google Chrome"
            scriptSource = """
            tell application "Google Chrome"
                if (count of windows) > 0 then
                    tell active tab of front window
                        return URL & "|" & title
                    end tell
                end if
            end tell
            """
        case "company.thebrowser.Browser": // Arc Browser
            appName = "Arc"
            scriptSource = """
            tell application "Arc"
                if (count of windows) > 0 then
                    tell active tab of front window
                        return URL & "|" & title
                    end tell
                end if
            end tell
            """
        default:
            return nil
        }
        
        // Ensure the application is actually running before scripting to avoid launching it.
        // アプリが起動していないのにスクリプトを実行して起動してしまうのを防ぐため、起動中か確認します。
        guard isAppRunning(bundleID: bundleID) else { return nil }
        
        guard let script = NSAppleScript(source: scriptSource) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        
        if let error = error {
            print("[BrowserTabDetector] AppleScript error for \(appName): \(error)")
            return nil
        }
        
        guard let outputString = result.stringValue, !outputString.isEmpty else {
            return nil
        }
        
        return parseTabInfo(outputString: outputString, fallbackAppName: appName)
    }
    
    /// Check if target application is running.
    /// 対象のアプリケーションが実行中か確認します。
    private func isAppRunning(bundleID: String) -> Bool {
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
    
    /// Parses the raw URL|Title string into a readable website name or domain.
    /// 生の URL|Title 文字列を読みやすいウェブサイト名またはドメインにパースします。
    private func parseTabInfo(outputString: String, fallbackAppName: String) -> String {
        let parts = outputString.components(separatedBy: "|")
        guard parts.count >= 2, let urlString = parts.first else {
            return fallbackAppName
        }
        
        guard let url = URL(string: urlString), let host = url.host else {
            return fallbackAppName
        }
        
        // Simplify host (e.g. "www.youtube.com" -> "youtube.com")
        // ホスト名を簡略化します (例: "www.youtube.com" -> "youtube.com")
        var domain = host
        if domain.hasPrefix("www.") {
            domain = String(domain.dropFirst(4))
        }
        
        // Return mapped names for popular media sites.
        // 主要なメディアサイトの表示名をマッピングして返します。
        switch domain {
        case "youtube.com", "m.youtube.com":
            return "YouTube"
        case "tidal.com", "listen.tidal.com":
            return "Tidal"
        case "open.spotify.com", "spotify.com":
            return "Spotify Web"
        case "music.apple.com":
            return "Apple Music Web"
        case "qobuz.com", "play.qobuz.com":
            return "Qobuz Web"
        default:
            return domain
        }
    }
}
