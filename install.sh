#!/bin/bash

# LosslessSwitcher Audio Plugin Installer
# LosslessSwitcher オーディオプラグイン インストーラー

# Exit immediately if a command exits with a non-zero status.
# エラーが発生した場合にスクリプトを即座に終了します。
set -e

echo "=== LosslessSwitcher Audio Plugin Installation ==="
echo "=== LosslessSwitcher オーディオプラグインのインストール ==="

# 1. Build the Audio Plugin and App using xcodebuild
# 1. xcodebuild を使用してオーディオプラグインとアプリをビルドします
echo "Building targets... / アプリとオーディオプラグインをビルド中..."
xcodebuild -project Quality.xcodeproj -scheme LosslessSwitcher -configuration Release -derivedDataPath build
xcodebuild -project Quality.xcodeproj -scheme LosslessSwitcherAudioPlugin -configuration Release -derivedDataPath build

# 2. Check if the build product exists
# 2. ビルド生成物が存在するか確認します
PLUGIN_PATH="build/Build/Products/Release/LosslessSwitcherAudioPlugin.driver"
if [ ! -d "$PLUGIN_PATH" ]; then
    echo "Error: Build output not found at $PLUGIN_PATH"
    echo "エラー: ビルド出力が $PLUGIN_PATH に見つかりませんでした。"
    exit 1
fi

# 2b. Copy App Icon into the plugin's resources
# 2b. アプリのアイコンをプラグインのリソースにコピーします
echo "Copying App Icon to plugin resources... / アプリのアイコンをプラグインリソースにコピー中..."
mkdir -p "$PLUGIN_PATH/Contents/Resources"
APP_ICON_PATH="build/Build/Products/Release/LosslessSwitcher.app/Contents/Resources/AppIcon.icns"
if [ -f "$APP_ICON_PATH" ]; then
    cp "$APP_ICON_PATH" "$PLUGIN_PATH/Contents/Resources/"
else
    echo "Warning: AppIcon.icns not found at $APP_ICON_PATH, fallback to default icon"
    echo "警告: AppIcon.icns が $APP_ICON_PATH に見つかりません。デフォルトのアイコンにフォールバックします。"
fi

# 3. Create the global HAL plug-ins directory if it doesn't exist
# 3. グローバルな HAL プラグインディレクトリが存在しない場合は作成します（管理者権限が必要）
echo "Creating destination directory if needed... / 必要に応じてコピー先ディレクトリを作成中..."
sudo mkdir -p /Library/Audio/Plug-Ins/HAL/

# 4. Copy the plug-in to the system-wide HAL directory
# 4. プラグインをシステム全体の HAL ディレクトリにコピーします
echo "Installing plugin to /Library/Audio/Plug-Ins/HAL/... / プラグインをインストール中..."
sudo cp -R "$PLUGIN_PATH" /Library/Audio/Plug-Ins/HAL/

# 5. Restart coreaudiod daemon to load the new plugin
# 5. 新しいプラグインをロードするために coreaudiod デーモンを再起動します
echo "Restarting CoreAudio daemon (coreaudiod)... / CoreAudio デーモンを再起動中..."
sudo killall -9 coreaudiod

echo "--------------------------------------------------"
echo "Installation complete successfully!"
echo "Please open 'Audio MIDI Setup' app to verify the virtual device."
echo "インストールが正常に完了しました！"
echo "「オーディオMIDI設定」アプリを開き、仮想デバイスを確認してください。"
echo "--------------------------------------------------"
