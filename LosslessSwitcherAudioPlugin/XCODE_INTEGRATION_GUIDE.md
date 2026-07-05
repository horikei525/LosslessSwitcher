# Audio Server Plugin - Xcode Integration Guide

## Overview / 概要

This guide explains how to integrate the Audio Server Plugin (C++) into the Xcode project.

このガイドでは、Audio Server Plugin (C++) を Xcode プロジェクトに統合する方法を説明します。

## Steps / 手順

### Step 1: Create a New Plugin Target / ステップ1: 新しいプラグインターゲットを作成

1. Xcode を開き、`Quality.xcodeproj` をクリック
2. **File > New > Target...**
3. **macOS > Bundle** を選択
4. 設定：
   - Product Name: `LosslessSwitcherAudioPlugin`
   - Organization: `Vincent Neo` (or your organization)
   - Language: C++

### Step 2: Configure Build Settings / ステップ 2: ビルド設定を構成

1. ターゲット `LosslessSwitcherAudioPlugin` を選択
2. **Build Settings** タブを開く
3. 以下を設定：
   - **Product Name**: `LosslessSwitcherAudioPlugin`
   - **Product Type**: `com.apple.product-type.bundle`
   - **Wrapper Extension**: `driver` (Audio Server Plugin extension)
   - **FRAMEWORK_SEARCH_PATHS**: 
     - `/System/Library/Frameworks`
     - `/System/Library/PrivateFrameworks`
   - **HEADER_SEARCH_PATHS**:
     - `$(SDKROOT)/System/Library/Frameworks/CoreAudio.framework/Headers`
   - **Deployment Target**: macOS 10.13 or later

### Step 3: Add Source Files / ステップ 3: ソースファイルを追加

1. **LosslessSwitcherAudioPlugin** ターゲットの Build Phases > Compile Sources に以下を追加：
   - `LosslessSwitcherAudioPlugin.cpp`
   - `LosslessSwitcherAudioPlugin.h`

### Step 4: Add Frameworks / ステップ 4: フレームワークを追加

1. **Build Phases > Link Binary With Libraries** に以下を追加：
   - `CoreAudio.framework` (Public)
   - `CoreFoundation.framework` (Public)
   - `AppKit.framework` (Public)
   - `Security.framework` (Public)

### Step 5: Module Map Configuration / ステップ 5: モジュールマップ設定

Core Audio のプライベートヘッダーを利用するため、ブリッジングヘッダーが必要です：

**LosslessSwitcherAudioPlugin-Bridging-Header.h:**
```cpp
//
//  LosslessSwitcherAudioPlugin-Bridging-Header.h
//

#ifndef LosslessSwitcherAudioPlugin_Bridging_Header_h
#define LosslessSwitcherAudioPlugin_Bridging_Header_h

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/CoreAudioTypes.h>

#include "LosslessSwitcherAudioPlugin.h"

#endif /* LosslessSwitcherAudioPlugin_Bridging_Header_h */
```

Build Settings で **Bridging Header** を設定：
```
LosslessSwitcherAudioPlugin/LosslessSwitcherAudioPlugin-Bridging-Header.h
```

### Step 6: Install Location / ステップ 6: インストール場所

Audio Server Plugin を macOS が認識するため、特定の場所にコピーする必要があります：

1. **Build Phases > New Copy Files Phase** を作成
2. 設定：
   - **Destination**: `Wrapper`
   - **Subpath**: 空のまま（もしくは `.`)

または、ビルド後スクリプトで：

```bash
# Copy the plugin to CoreAudio plugin directory
cp -r "${BUILT_PRODUCTS_DIR}/${EXECUTABLE_PATH}" \
    "${HOME}/Library/Audio/Plug-Ins/HAL/"
```

### Step 7: Update Main App Target / ステップ 7: メインアプリターゲットを更新

1. **Quality** ターゲットの **Build Phases** を開く
2. **Link Binary With Libraries** に **LosslessSwitcherAudioPlugin.framework** を追加
3. **Compile Sources** に **AudioPluginBridge.swift** が含まれていることを確認

### Step 8: Build & Test / ステップ 8: ビルドとテスト

```bash
# Full rebuild
xcodebuild clean build -scheme Quality

# Run the app
open -a /Applications/LosslessSwitcher.app

# Check Audio MIDI Setup to see if the virtual device appears
# Audio MIDI設定を開いて、仮想デバイスが表示されるか確認してください
open /Applications/Utilities/Audio\ MIDI\ Setup.app
```

## Troubleshooting / トラブルシューティング

### Plugin not appearing in Audio MIDI Setup
プラグインが Audio MIDI 設定に表示されない場合

- [ ] コンパイルエラーがないか確認
- [ ] プラグインがコピーされているか確認：
  ```bash
  ls -la ~/Library/Audio/Plug-Ins/HAL/
  ```
- [ ] CoreAudio を再起動：
  ```bash
  sudo killall -9 coreaudiod
  ```

### Build errors related to CoreAudio headers
CoreAudio ヘッダーに関連するビルドエラー

- [ ] Xcode Command Line Tools を更新：
  ```bash
  sudo xcode-select --install
  ```
- [ ] HEADER_SEARCH_PATHS が正しく設定されているか確認

### Swift interop issues
Swift 相互運用性の問題

- [ ] Module map が正しく設定されているか確認
- [ ] Bridging header パスが正しいか確認

## Project Structure After Integration / 統合後のプロジェクト構造

```
LosslessSwitcher/
├── LosslessSwitcherAudioPlugin/        # Audio Server Plugin Target
│   ├── LosslessSwitcherAudioPlugin.h
│   ├── LosslessSwitcherAudioPlugin.cpp
│   ├── LosslessSwitcherAudioPlugin-Bridging-Header.h
│   └── Info.plist
├── Quality/                             # Main App Target
│   ├── AudioPluginBridge.swift         # Swift <-> C++ bridge
│   ├── AudioRoutingController.swift    # Updated with plugin support
│   ├── MenuView.swift
│   └── ... (other files)
└── Quality.xcodeproj/
```

## Next Steps / 次のステップ

1. ✅ Audio Server Plugin プロジェクト構造完成
2. 🔄 C++ プラグインコアの拡張実装
3. 🔄 メニューバー UI に優先度設定画面を追加
4. 🔄 BlackHole との統合（オプション）
5. 🔄 エンドツーエンドテスト実施

---

**Note / 注記:**
macOS Monterey 以降、プラグインの署名とノータリゼーションが必須です。
詳細は Apple の [Code Signing Guide](https://developer.apple.com/documentation/security/code_signing) を参照してください。
