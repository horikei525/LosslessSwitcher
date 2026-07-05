//
//  UpdateChecker.swift
//  LosslessSwitcher
//
//  Created by Antigravity on 2026-07-05.
//
//  Queries the GitHub Releases API to check for application updates.
//  GitHub Releases API を照会して、アプリケーションの更新を確認します。

import Foundation

class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    
    @Published var updateStatus: String = ""
    @Published var hasNewUpdate: Bool = false
    @Published var latestVersionString: String = ""
    
    private init() {}
    
    /// Queries the GitHub API for the latest release version.
    /// 最新のリリースバージョンについて GitHub API を照会します。
    func checkForUpdates(currentVersion: String) {
        updateStatus = NSLocalizedString("Checking for updates...", comment: "アップデートを確認中...")
        
        let urlString = "https://api.github.com/repos/vincentneo/LosslessSwitcher/releases/latest"
        guard let url = URL(string: urlString) else {
            self.updateStatus = NSLocalizedString("Invalid Update URL", comment: "無効なアップデートURL")
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("LosslessSwitcher-UpdateChecker", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            if let error = error {
                DispatchQueue.main.async {
                    self.updateStatus = String(format: NSLocalizedString("Error: %@", comment: "エラー: %@"), error.localizedDescription)
                }
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async {
                    self.updateStatus = NSLocalizedString("No response from server", comment: "サーバーからの応答なし")
                }
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let tagName = json["tag_name"] as? String {
                    
                    // Clean tag name (e.g. "v2.0" -> "2.0", "v2.0-beta1" -> "2.0-beta1")
                    // タグ名をクリーンアップします (例: "v2.0" -> "2.0")
                    let cleanTag = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                    
                    DispatchQueue.main.async {
                        self.latestVersionString = cleanTag
                        
                        // Simple version comparison
                        // 簡易バージョン比較
                        if cleanTag.compare(currentVersion, options: .numeric) == .orderedDescending {
                            self.hasNewUpdate = true
                            self.updateStatus = String(format: NSLocalizedString("New version available: %@", comment: "新しいバージョンが利用可能です: %@"), tagName)
                        } else {
                            self.hasNewUpdate = false
                            self.updateStatus = NSLocalizedString("You are on the latest version", comment: "最新バージョンを使用しています")
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self.updateStatus = NSLocalizedString("Failed to parse version information", comment: "バージョン情報の解析に失敗しました")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.updateStatus = NSLocalizedString("Failed to parse response", comment: "応答のパースに失敗しました")
                }
            }
        }.resume()
    }
}
