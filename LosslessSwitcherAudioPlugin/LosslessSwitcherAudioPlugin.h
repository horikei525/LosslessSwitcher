//
//  LosslessSwitcherAudioPlugin.h
//  LosslessSwitcherAudioPlugin
//
//  Created by GitHub Copilot on behalf of the user.
//  
//  This is an Audio Server Plugin that acts as a virtual audio device.
//  It intercepts audio streams and detects sample rate changes in real-time.
//
//  これは仮想オーディオデバイスとして機能する Audio Server Plugin です。
//  オーディオストリームをインターセプトし、サンプルレート変更をリアルタイムで検知します。

#ifndef LosslessSwitcherAudioPlugin_h
#define LosslessSwitcherAudioPlugin_h

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/CoreAudioTypes.h>
#include <dispatch/dispatch.h>
#include <sys/types.h>

#pragma mark - Constants & Structures

// Plugin constants / プラグイン定数
#define kLosslessSwitcherPluginBundleID "com.vincent-neo.LosslessSwitcher.AudioPlugin"
#define kVirtualDeviceName "LosslessSwitcher Virtual Device"
#define kVirtualDeviceUID "com.vincent-neo.losslessswitcher.virtual.device"
#define kInputStreamUID "com.vincent-neo.losslessswitcher.input.stream"
#define kOutputStreamUID "com.vincent-neo.losslessswitcher.output.stream"

// Structure to track audio source information
// オーディオソース情報を追跡するためのストラクチャ
struct AudioSourceInfo {
    pid_t processID;
    char bundleID[256];
    AudioStreamBasicDescription format;
    uint32_t sampleRate;
    uint32_t bitDepth;
    
    AudioSourceInfo() : processID(0), sampleRate(0), bitDepth(0) {
        memset(bundleID, 0, sizeof(bundleID));
        memset(&format, 0, sizeof(AudioStreamBasicDescription));
    }
};

// Callback for communicating sample rate changes to the host app
// ホストアプリへのサンプルレート変更通知用コールバック
typedef void (*SampleRateChangeCallback)(pid_t clientPID,
                                        const char* bundleID,
                                        Float64 newSampleRate,
                                        UInt32 bitDepth);

// Device object structure
// デバイスオブジェクト構造
typedef struct {
    AudioServerPlugInDriverRef driverRef;
    AudioServerPlugInHostRef hostRef;
    AudioObjectID deviceID;
    AudioObjectID inputStreamID;
    AudioObjectID outputStreamID;
    
    // access control is handled globally via os_unfair_lock
    
    // Current stream info / 現在のストリーム情報
    AudioStreamBasicDescription currentFormat;
    AudioSourceInfo activeSource;
    
    // Callback to notify Swift side / Swift側への通知コールバック
    SampleRateChangeCallback sampleRateCallback;
    void* callbackUserData;
    
} LosslessSwitcherDevice;

#pragma mark - Plugin Interface Functions

// Main entry points for the Audio Server Plugin
// Audio Server Plugin のメインエントリーポイント

extern "C" {

void* AudioServerPlugInDriverEntry(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

void LosslessSwitcherPlugin_RegisterSampleRateCallback(
    SampleRateChangeCallback callback,
    void* userData);

}

#endif /* LosslessSwitcherAudioPlugin_h */
