import Cocoa
import Foundation

let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as! String
let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as! String

// MARK: - Localization Support

enum Language {
    case en
    case ja
    
    static var current: Language {
        if let preferred = Locale.preferredLanguages.first, preferred.hasPrefix("ja") {
            return .ja
        }
        return .en
    }
}

func localizedString(_ key: String) -> String {
    let translations: [String: [Language: String]] = [
        "Requires Privileges": [
            .en: "Requires Privileges",
            .ja: "管理者権限が必要です"
        ],
        "LosslessSwitcher requires Administrator privileges in order to detect each song's lossless sample rate in the Music app.": [
            .en: "LosslessSwitcher requires Administrator privileges in order to detect each song's lossless sample rate in the Music app.",
            .ja: "Musicアプリで各曲のロスレスサンプルレートを検出するためには、LosslessSwitcherに管理者権限が必要です。"
        ],
        "LosslessSwitcher could not check if your account has Administrator privileges. If your account lacks Administrator privileges, sample rate detection will not work.": [
            .en: "LosslessSwitcher could not check if your account has Administrator privileges. If your account lacks Administrator privileges, sample rate detection will not work.",
            .ja: "アカウントに管理者権限があるか確認できませんでした。管理者権限がない場合、サンプルレートの検出は動作しません。"
        ],
        "Bit Depth Switching": [
            .en: "Bit Depth Switching",
            .ja: "ビット深度の切り替え"
        ],
        "Prefer Closest Sample Rate Multiple": [
            .en: "Prefer Closest Sample Rate Multiple",
            .ja: "最も近いサンプルレートの倍数を優先"
        ],
        "Default Device": [
            .en: "Default Device",
            .ja: "デフォルトのデバイス"
        ],
        "Selected Device": [
            .en: "Selected Device",
            .ja: "選択されたデバイス"
        ],
        "About": [
            .en: "About",
            .ja: "このアプリについて"
        ],
        "Version": [
            .en: "Version",
            .ja: "バージョン"
        ],
        "Build": [
            .en: "Build",
            .ja: "ビルド"
        ],
        "Scripting": [
            .en: "Scripting",
            .ja: "スクリプト処理"
        ],
        "Select Script...": [
            .en: "Select Script...",
            .ja: "スクリプトを選択..."
        ],
        "Clear Selection": [
            .en: "Clear Selection",
            .ja: "選択解除"
        ],
        "No selection": [
            .en: "No selection",
            .ja: "未選択"
        ],
        "Quit LosslessSwitcher": [
            .en: "Quit LosslessSwitcher",
            .ja: "LosslessSwitcherを終了"
        ],
        "Select a script that should be invoked when sample rate changes.": [
            .en: "Select a script that should be invoked when sample rate changes.",
            .ja: "サンプルレートが変更されたときに呼び出すスクリプトを選択してください。"
        ],
        "Show Sample Rate": [
            .en: "Show Sample Rate",
            .ja: "サンプルレートを表示"
        ],
        "Show Icon": [
            .en: "Show Icon",
            .ja: "アイコンを表示"
        ],
        "Update Available": [
            .en: "Update Available",
            .ja: "アップデートがあります"
        ],
        "A new version (%@) is available. Your current version is %@. Would you like to download it?": [
            .en: "A new version (%@) is available. Your current version is %@. Would you like to download it?",
            .ja: "新しいバージョン (%@) が利用可能です。現在のバージョンは %@ です。ダウンロードしますか？"
        ],
        "Download": [
            .en: "Download",
            .ja: "ダウンロード"
        ],
        "Later": [
            .en: "Later",
            .ja: "後で"
        ],
        "Up to Date": [
            .en: "Up to Date",
            .ja: "最新の状態です"
        ],
        "LosslessSwitcher is up to date (v%@ is the latest version).": [
            .en: "LosslessSwitcher is up to date (v%@ is the latest version).",
            .ja: "LosslessSwitcherは最新の状態です (v%@ が最新バージョンです)。"
        ],
        "Check Failed": [
            .en: "Check Failed",
            .ja: "チェックに失敗しました"
        ],
        "Could not check for updates: %@": [
            .en: "Could not check for updates: %@",
            .ja: "アップデートの確認ができませんでした: %@"
        ],
        "OK": [
            .en: "OK",
            .ja: "OK"
        ],
        "Check for Updates...": [
            .en: "Check for Updates...",
            .ja: "アップデートを確認..."
        ],
        "Checking for updates...": [
            .en: "Checking for updates...",
            .ja: "アップデートを確認中..."
        ],
        "Unknown": [
            .en: "Unknown",
            .ja: "不明"
        ],
        "No releases found on GitHub.": [
            .en: "No releases found on GitHub.",
            .ja: "GitHub上にリリースが見つかりませんでした。"
        ]
    ]
    
    let lang = Language.current
    if let entry = translations[key], let val = entry[lang] {
        return val
    }
    return key
}

extension String {
    var localized: String {
        return localizedString(self)
    }
}

// MARK: - Update Checker

struct GitHubRelease: Codable {
    let tagName: String
    let htmlUrl: String
    
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
    }
}

class UpdateChecker: ObservableObject {
    @Published var isChecking = false
    
    static let shared = UpdateChecker()
    
    private init() {}
    
    func checkForUpdates(manually: Bool = false) {
        guard !isChecking else { return }
        isChecking = true
        
        guard let url = URL(string: "https://api.github.com/repos/horikei525/LosslessSwitcher/releases/latest") else {
            isChecking = false
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("LosslessSwitcher-UpdateChecker", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            defer {
                DispatchQueue.main.async {
                    self.isChecking = false
                }
            }
            
            if let error = error {
                if manually {
                    self.showErrorAlert(error: error.localizedDescription)
                }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                if manually {
                    let errorMsg = httpResponse.statusCode == 404 ? "No releases found on GitHub.".localized : "HTTP Status \(httpResponse.statusCode)"
                    self.showErrorAlert(error: errorMsg)
                }
                return
            }
            
            guard let data = data else {
                if manually {
                    self.showErrorAlert(error: "No data received".localized)
                }
                return
            }
            
            do {
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                let latest = release.tagName.replacingOccurrences(of: "v", with: "")
                let current = currentVersion
                
                let hasUpdate = self.isVersion(latest, newerThan: current)
                
                if hasUpdate {
                    self.showUpdateAlert(latest: latest, urlString: release.htmlUrl)
                } else if manually {
                    self.showUpToDateAlert()
                }
            } catch {
                if manually {
                    self.showErrorAlert(error: error.localizedDescription)
                }
            }
        }.resume()
    }
    
    private func isVersion(_ version1: String, newerThan version2: String) -> Bool {
        if version1 == version2 { return false }
        
        let clean1 = version1.components(separatedBy: CharacterSet.decimalDigits.inverted.subtracting(CharacterSet(charactersIn: "."))).joined()
        let clean2 = version2.components(separatedBy: CharacterSet.decimalDigits.inverted.subtracting(CharacterSet(charactersIn: "."))).joined()
        
        let v1Components = clean1.split(separator: ".").compactMap { Int($0) }
        let v2Components = clean2.split(separator: ".").compactMap { Int($0) }
        
        let count = max(v1Components.count, v2Components.count)
        for i in 0..<count {
            let v1 = i < v1Components.count ? v1Components[i] : 0
            let v2 = i < v2Components.count ? v2Components[i] : 0
            if v1 > v2 {
                return true
            } else if v1 < v2 {
                return false
            }
        }
        
        let v1IsBeta = version1.lowercased().contains("beta") || version1.lowercased().contains("alpha")
        let v2IsBeta = version2.lowercased().contains("beta") || version2.lowercased().contains("alpha")
        
        if v1IsBeta && !v2IsBeta {
            return false
        }
        if !v1IsBeta && v2IsBeta {
            return true
        }
        
        return version1.compare(version2, options: .numeric) == .orderedDescending
    }
    
    private func showUpdateAlert(latest: String, urlString: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Update Available".localized
            alert.informativeText = String(format: "A new version (%@) is available. Your current version is %@. Would you like to download it?".localized, latest, currentVersion)
            alert.addButton(withTitle: "Download".localized)
            alert.addButton(withTitle: "Later".localized)
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                if let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
    
    private func showUpToDateAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Up to Date".localized
            alert.informativeText = String(format: "LosslessSwitcher is up to date (v%@ is the latest version).".localized, currentVersion)
            alert.addButton(withTitle: "OK".localized)
            alert.runModal()
        }
    }
    
    private func showErrorAlert(error: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Check Failed".localized
            alert.informativeText = String(format: "Could not check for updates: %@".localized, error)
            alert.addButton(withTitle: "OK".localized)
            alert.runModal()
        }
    }
}
