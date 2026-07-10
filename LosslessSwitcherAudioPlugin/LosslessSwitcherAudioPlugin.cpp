//
//  LosslessSwitcherAudioPlugin.cpp
//  LosslessSwitcherAudioPlugin
//
//  Created by GitHub Copilot on behalf of the user.
//
//  Implementation of the Audio Server Plugin driver for LosslessSwitcher.
//  ロスレススイッチャー用 Audio Server Plugin ドライバの実装。

#include "LosslessSwitcherAudioPlugin.h"
#include <stdio.h>
#include <string.h>
#include <CoreAudio/AudioHardware.h>
#include <libproc.h>
#include <os/log.h>
#include <mach/mach_time.h>

#pragma mark - Global State

// Global device object / グローバルデバイスオブジェクト
static LosslessSwitcherDevice g_device = {};
static SampleRateChangeCallback g_sampleRateCallback = nullptr;
static void* g_callbackUserData = nullptr;
static dispatch_once_t g_initOnce = 0;
#include <os/lock.h>
static os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;
static bool g_canBeDefaultSystemDevice = true;
static bool g_readInitialized = false;

#pragma mark - Helper Functions

// Get process name from PID
// PID からプロセス名を取得
static void GetProcessNameFromPID(pid_t pid, char* outName, size_t nameSize) {
    if (proc_name(pid, outName, (uint32_t)nameSize) <= 0) {
        snprintf(outName, nameSize, "Unknown (PID: %d)", pid);
    }
}

// Get bundle ID from PID (simplified placeholder, Swift side will resolve actual bundle ID using Cocoa)
// PID からバンドルIDを取得します（簡易的なプレースホルダー。Swift側でCocoaを使用して解決します）
static void GetBundleIDFromPID(pid_t pid, char* outBundleID, size_t bundleIDSize) {
    snprintf(outBundleID, bundleIDSize, "pid.%d", pid);
}

// Notify Swift side of sample rate change
// サンプルレート変更を Swift 側に通知
static void NotifySampleRateChange(pid_t clientPID,
                                   const char* bundleID,
                                   Float64 newSampleRate,
                                   UInt32 bitDepth) {
    // Notify in-process callbacks if any
    if (g_sampleRateCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            g_sampleRateCallback(clientPID, bundleID, newSampleRate, bitDepth);
        });
    }
    
    // Broadcast via Distributed Notification Center to reach the user companion app
    CFMutableDictionaryRef userInfo = CFDictionaryCreateMutable(kCFAllocatorDefault, 4, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (userInfo) {
        CFNumberRef pidNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &clientPID);
        CFStringRef bundleStr = CFStringCreateWithCString(kCFAllocatorDefault, bundleID ? bundleID : "unknown", kCFStringEncodingUTF8);
        CFNumberRef rateNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &newSampleRate);
        CFNumberRef depthNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &bitDepth);
        
        if (pidNum) CFDictionarySetValue(userInfo, CFSTR("pid"), pidNum);
        if (bundleStr) CFDictionarySetValue(userInfo, CFSTR("bundleID"), bundleStr);
        if (rateNum) CFDictionarySetValue(userInfo, CFSTR("sampleRate"), rateNum);
        if (depthNum) CFDictionarySetValue(userInfo, CFSTR("bitDepth"), depthNum);
        
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDistributedCenter(),
            CFSTR("com.vincent-neo.LosslessSwitcher.SampleRateChanged"),
            nullptr, // object
            userInfo,
            true // deliverImmediately
        );
        
        if (pidNum) CFRelease(pidNum);
        if (bundleStr) CFRelease(bundleStr);
        if (rateNum) CFRelease(rateNum);
        if (depthNum) CFRelease(depthNum);
        CFRelease(userInfo);
    }
    
    os_log(OS_LOG_DEFAULT, "[LosslessSwitcherPlugin] Sample Rate Changed: PID=%d, Rate=%.1f Hz, BitDepth=%u bits",
           clientPID, newSampleRate, bitDepth);
}

#pragma mark - Plugin Initialization

static void BlockAlertsChangedCallback(CFNotificationCenterRef center,
                                       void* observer,
                                       CFStringRef name,
                                       const void* object,
                                       CFDictionaryRef userInfo) {
    Boolean blockAlerts = false;
    if (userInfo) {
        CFBooleanRef val = (CFBooleanRef)CFDictionaryGetValue(userInfo, CFSTR("blockAlerts"));
        if (val) {
            blockAlerts = CFBooleanGetValue(val);
        }
    }
    
    os_unfair_lock_lock(&g_lock);
    g_canBeDefaultSystemDevice = !blockAlerts;
    os_log(OS_LOG_DEFAULT, "[LosslessSwitcherPlugin] Block System Alerts notification received: %s", blockAlerts ? "YES" : "NO");
    os_unfair_lock_unlock(&g_lock);
    
    // Notify CoreAudio Host that the property changed
    if (g_device.hostRef && g_device.deviceID != 0) {
        AudioObjectPropertyAddress address = { kAudioDevicePropertyDeviceCanBeDefaultSystemDevice, kAudioObjectPropertyScopeGlobal, 0 };
        g_device.hostRef->PropertiesChanged(g_device.hostRef, g_device.deviceID, 1, &address);
    }
}

OSStatus LosslessSwitcherPlugin_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    os_log(OS_LOG_DEFAULT, "[LosslessSwitcherPlugin] Initialize called");
    
    dispatch_once(&g_initOnce, ^{
        g_device.driverRef = inDriver;
        g_device.hostRef = inHost;
        g_device.deviceID = kAudioObjectSystemObject + 1;  // Unique device ID
        g_device.inputStreamID = g_device.deviceID + 1;
        g_device.outputStreamID = g_device.deviceID + 2;
        
        // Initialize default format (44.1kHz, 2ch, Float32)
        // デフォルトフォーマットを初期化 (44.1kHz, 2ch, Float32)
        g_device.currentFormat.mSampleRate = 44100.0;
        g_device.currentFormat.mFormatID = kAudioFormatLinearPCM;
        g_device.currentFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        g_device.currentFormat.mBytesPerPacket = 8;
        g_device.currentFormat.mFramesPerPacket = 1;
        g_device.currentFormat.mBytesPerFrame = 8;
        g_device.currentFormat.mChannelsPerFrame = 2;
        g_device.currentFormat.mBitsPerChannel = 32;
        
        // Register for Block Alerts setting changes from Swift companion app
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDistributedCenter(),
            nullptr,
            BlockAlertsChangedCallback,
            CFSTR("com.vincent-neo.LosslessSwitcher.BlockAlertsChanged"),
            nullptr,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );
        
        os_log(OS_LOG_DEFAULT, "[LosslessSwitcherPlugin] Initialized with device ID: %u", g_device.deviceID);
    });
    
    return noErr;
}

OSStatus LosslessSwitcherPlugin_Finalize(AudioServerPlugInDriverRef inDriver) {
    os_log(OS_LOG_DEFAULT, "[LosslessSwitcherPlugin] Finalize called");
    return noErr;
}

#pragma mark - Property Access

OSStatus LosslessSwitcherPlugin_GetPropertyData(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientPID,
    const AudioObjectPropertyAddress* inAddress,
    UInt32 inQualifierDataSize,
    const void* inQualifierData,
    UInt32 inDataSize,
    UInt32* outDataSize,
    void* outData) {
    
    if (!inAddress || !outDataSize || !outData) {
        return kAudioHardwareUnknownPropertyError;
    }
    
    OSStatus result = kAudioHardwareUnknownPropertyError;
    
    os_unfair_lock_lock(&g_lock);
    
    os_log(OS_LOG_DEFAULT, "[LosslessSwitcherPlugin] GetPropertyData: objectID=%u, selector='%c%c%c%c' (%u)",
           inObjectID,
           (char)((inAddress->mSelector >> 24) & 0xFF),
           (char)((inAddress->mSelector >> 16) & 0xFF),
           (char)((inAddress->mSelector >> 8) & 0xFF),
           (char)(inAddress->mSelector & 0xFF),
           inAddress->mSelector);
    
    // 1. Properties for the Plug-In Object (kAudioObjectSystemObject or plugin ID)
    if (inObjectID == kAudioObjectSystemObject) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyClass:
                if (inDataSize >= sizeof(AudioClassID)) {
                    *outDataSize = sizeof(AudioClassID);
                    *(AudioClassID*)outData = kAudioPlugInClassID;
                    result = noErr;
                }
                break;
            case kAudioObjectPropertyOwner:
                if (inDataSize >= sizeof(AudioObjectID)) {
                    *outDataSize = sizeof(AudioObjectID);
                    *(AudioObjectID*)outData = kAudioObjectUnknown;
                    result = noErr;
                }
                break;
            case kAudioObjectPropertyManufacturer:
                if (inDataSize >= sizeof(CFStringRef)) {
                    *outDataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFStringCreateCopy(nullptr, CFSTR("LosslessSwitcher"));
                    result = noErr;
                }
                break;
            case kAudioPlugInPropertyDeviceList:
            case kAudioObjectPropertyOwnedObjects:
                if (inDataSize >= sizeof(AudioObjectID)) {
                    *outDataSize = sizeof(AudioObjectID);
                    *(AudioObjectID*)outData = g_device.deviceID;
                    result = noErr;
                }
                break;
            default:
                break;
        }
    }
    
    // 2. Properties for the Device Object
    else if (inObjectID == g_device.deviceID) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyClass:
                if (inDataSize >= sizeof(AudioClassID)) {
                    *outDataSize = sizeof(AudioClassID);
                    *(AudioClassID*)outData = kAudioDeviceClassID;
                    result = noErr;
                }
                break;
            case kAudioObjectPropertyOwner:
                if (inDataSize >= sizeof(AudioObjectID)) {
                    *outDataSize = sizeof(AudioObjectID);
                    *(AudioObjectID*)outData = kAudioObjectSystemObject;
                    result = noErr;
                }
                break;
            case kAudioObjectPropertyName:
                if (inDataSize >= sizeof(CFStringRef)) {
                    *outDataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFStringCreateCopy(nullptr, CFSTR("LosslessSwitcher Virtual Device"));
                    result = noErr;
                }
                break;
            case kAudioObjectPropertyManufacturer:
                if (inDataSize >= sizeof(CFStringRef)) {
                    *outDataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFStringCreateCopy(nullptr, CFSTR("LosslessSwitcher"));
                    result = noErr;
                }
                break;
            case kAudioDevicePropertyClockDomain:
                if (inDataSize >= sizeof(UInt32)) {
                    *outDataSize = sizeof(UInt32);
                    *(UInt32*)outData = 0;
                    result = noErr;
                }
                break;
            case kAudioDevicePropertyStreamConfiguration: {
                UInt32 numBuffers = 0;
                if (inAddress->mScope == kAudioObjectPropertyScopeInput || inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                    numBuffers = 1;
                }
                UInt32 expectedSize = sizeof(AudioBufferList) + (numBuffers > 0 ? (numBuffers - 1) : 0) * sizeof(AudioBuffer);
                if (inDataSize >= expectedSize) {
                    *outDataSize = expectedSize;
                    AudioBufferList* list = (AudioBufferList*)outData;
                    list->mNumberBuffers = numBuffers;
                    if (numBuffers > 0) {
                        list->mBuffers[0].mNumberChannels = 2;
                        list->mBuffers[0].mDataByteSize = 0;
                        list->mBuffers[0].mData = nullptr;
                    }
                    result = noErr;
                }
                break;
            }
            case kAudioDevicePropertyDeviceUID:
                if (inDataSize >= sizeof(CFStringRef)) {
                    *outDataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFStringCreateCopy(nullptr, CFSTR("LosslessSwitcherVirtualDeviceUID"));
                    result = noErr;
                }
                break;
            case kAudioDevicePropertyModelUID:
                if (inDataSize >= sizeof(CFStringRef)) {
                    *outDataSize = sizeof(CFStringRef);
                    *(CFStringRef*)outData = CFStringCreateCopy(nullptr, CFSTR("LosslessSwitcherVirtualDeviceModelUID"));
                    result = noErr;
                }
                break;
            case kAudioDevicePropertyTransportType:
                if (inDataSize >= sizeof(UInt32)) {
                    *outDataSize = sizeof(UInt32);
                    *(UInt32*)outData = kAudioDeviceTransportTypeVirtual;
                    result = noErr;
                }
                break;
            case kAudioDevicePropertyNominalSampleRate:
                if (inDataSize >= sizeof(Float64)) {
                    *outDataSize = sizeof(Float64);
                    *(Float64*)outData = g_device.currentFormat.mSampleRate;
                    result = noErr;
                }
                break;
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                Float64 rates[] = { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };
                UInt32 numRates = sizeof(rates) / sizeof(Float64);
                UInt32 expectedSize = numRates * sizeof(Float64);
                if (inDataSize >= expectedSize) {
                    *outDataSize = expectedSize;
                    memcpy(outData, rates, expectedSize);
                    result = noErr;
                }
                break;
            }
            case kAudioDevicePropertyStreams: {
                UInt32 numStreams = 0;
                AudioObjectID streams[2];
                if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
                    numStreams = 1;
                    streams[0] = g_device.inputStreamID;
                } else if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                    numStreams = 1;
                    streams[0] = g_device.outputStreamID;
                } else if (inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                    numStreams = 2;
                    streams[0] = g_device.inputStreamID;
                    streams[1] = g_device.outputStreamID;
                }
                UInt32 expectedSize = numStreams * sizeof(AudioObjectID);
                if (inDataSize >= expectedSize) {
                    *outDataSize = expectedSize;
                    if (numStreams > 0) {
                        memcpy(outData, streams, expectedSize);
                    }
                    result = noErr;
                }
                break;
            }
            case kAudioObjectPropertyOwnedObjects: {
                UInt32 expectedSize = 2 * sizeof(AudioObjectID);
                if (inDataSize >= expectedSize) {
                    *outDataSize = expectedSize;
                    AudioObjectID* owned = (AudioObjectID*)outData;
                    owned[0] = g_device.inputStreamID;
                    owned[1] = g_device.outputStreamID;
                    result = noErr;
                }
                break;
            }
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                if (inDataSize >= sizeof(UInt32)) {
                    *outDataSize = sizeof(UInt32);
                    *(UInt32*)outData = 1;
                    result = noErr;
                }
                break;
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                if (inDataSize >= sizeof(UInt32)) {
                    *outDataSize = sizeof(UInt32);
                    *(UInt32*)outData = g_canBeDefaultSystemDevice ? 1 : 0;
                    result = noErr;
                }
                break;
            case kAudioDevicePropertyDeviceIsRunning:
                if (inDataSize >= sizeof(UInt32)) {
                    *outDataSize = sizeof(UInt32);
                    *(UInt32*)outData = 1; // Device is always running / ready
                    result = noErr;
                }
                break;
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
                if (inDataSize >= sizeof(UInt32)) {
                    *outDataSize = sizeof(UInt32);
                    *(UInt32*)outData = 0;
                    result = noErr;
                }
                break;
            case kAudioDevicePropertyBufferFrameSizeRange:
                if (inDataSize >= sizeof(AudioValueRange)) {
                    *outDataSize = sizeof(AudioValueRange);
                    AudioValueRange* range = (AudioValueRange*)outData;
                    range->mMinimum = 32.0;
                    range->mMaximum = 2048.0;
                    result = noErr;
                }
                break;
            case kAudioDevicePropertyBufferFrameSize:
                if (inDataSize >= sizeof(UInt32)) {
                    *outDataSize = sizeof(UInt32);
                    *(UInt32*)outData = 512;
                    result = noErr;
                }
                break;
            case kAudioObjectPropertyControlList:
                *outDataSize = 0;
                result = noErr;
                break;
            case kAudioDevicePropertyZeroTimeStampPeriod:
                if (inDataSize >= sizeof(UInt32)) {
                    *outDataSize = sizeof(UInt32);
                    *(UInt32*)outData = 512;
                    result = noErr;
                }
                break;
            case kAudioDevicePropertyIsHidden:
                if (inDataSize >= sizeof(UInt32)) {
                    *outDataSize = sizeof(UInt32);
                    *(UInt32*)outData = 0;
                    result = noErr;
                }
                break;
            case kAudioDevicePropertyIcon:
                if (inDataSize >= sizeof(CFURLRef)) {
                    *outDataSize = sizeof(CFURLRef);
                    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("com.vincent-neo.LosslessSwitcherAudioPlugin"));
                    if (bundle) {
                        CFURLRef iconURL = CFBundleCopyResourceURL(bundle, CFSTR("AppIcon"), CFSTR("icns"), nullptr);
                        if (iconURL) {
                            *(CFURLRef*)outData = iconURL;
                            result = noErr;
                        }
                    }
                }
                break;
            case kAudioDevicePropertyStreamFormat:
                if (inDataSize >= sizeof(AudioStreamBasicDescription)) {
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    memcpy(outData, &g_device.currentFormat, sizeof(AudioStreamBasicDescription));
                    result = noErr;
                }
                break;
            default:
                break;
        }
    }
    
    // 3. Properties for the Stream Objects
    else if (inObjectID == g_device.inputStreamID || inObjectID == g_device.outputStreamID) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyClass:
                if (inDataSize >= sizeof(AudioClassID)) {
                    *outDataSize = sizeof(AudioClassID);
                    *(AudioClassID*)outData = kAudioStreamClassID;
                    result = noErr;
                }
                break;
            case kAudioObjectPropertyOwner:
                if (inDataSize >= sizeof(AudioObjectID)) {
                    *outDataSize = sizeof(AudioObjectID);
                    *(AudioObjectID*)outData = g_device.deviceID;
                    result = noErr;
                }
                break;
            case kAudioStreamPropertyDirection:
                if (inDataSize >= sizeof(UInt32)) {
                    *outDataSize = sizeof(UInt32);
                    *(UInt32*)outData = (inObjectID == g_device.inputStreamID) ? 1 : 0;
                    result = noErr;
                }
                break;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                if (inDataSize >= sizeof(AudioStreamBasicDescription)) {
                    *outDataSize = sizeof(AudioStreamBasicDescription);
                    memcpy(outData, &g_device.currentFormat, sizeof(AudioStreamBasicDescription));
                    result = noErr;
                }
                break;
            case kAudioStreamPropertyStartingChannel:
                if (inDataSize >= sizeof(UInt32)) {
                    *outDataSize = sizeof(UInt32);
                    *(UInt32*)outData = 1;
                    result = noErr;
                }
                break;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                UInt32 expectedSize = 24 * sizeof(AudioStreamRangedDescription);
                if (inDataSize >= expectedSize) {
                    *outDataSize = expectedSize;
                    AudioStreamRangedDescription* formats = (AudioStreamRangedDescription*)outData;
                    Float64 rates[] = { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };
                    UInt32 bits[] = { 32, 24, 16, 32 };
                    UInt32 flags[] = {
                        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                        kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                        kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                        kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                    };
                    UInt32 bytesPerFrame[] = { 8, 6, 4, 8 };
                    
                    int idx = 0;
                    for (int r = 0; r < 6; ++r) {
                        for (int f = 0; f < 4; ++f) {
                            formats[idx].mFormat.mSampleRate = rates[r];
                            formats[idx].mFormat.mFormatID = kAudioFormatLinearPCM;
                            formats[idx].mFormat.mFormatFlags = flags[f];
                            formats[idx].mFormat.mBytesPerPacket = bytesPerFrame[f];
                            formats[idx].mFormat.mFramesPerPacket = 1;
                            formats[idx].mFormat.mBytesPerFrame = bytesPerFrame[f];
                            formats[idx].mFormat.mChannelsPerFrame = 2;
                            formats[idx].mFormat.mBitsPerChannel = bits[f];
                            
                            formats[idx].mSampleRateRange.mMinimum = rates[r];
                            formats[idx].mSampleRateRange.mMaximum = rates[r];
                            idx++;
                        }
                    }
                    result = noErr;
                }
                break;
            }
            case kAudioObjectPropertyOwnedObjects:
                *outDataSize = 0;
                result = noErr;
                break;
            case kAudioStreamPropertyIsActive:
                if (inDataSize >= sizeof(UInt32)) {
                    *outDataSize = sizeof(UInt32);
                    *(UInt32*)outData = 1; // Always active
                    result = noErr;
                }
                break;
            case kAudioStreamPropertyLatency:
                if (inDataSize >= sizeof(UInt32)) {
                    *outDataSize = sizeof(UInt32);
                    *(UInt32*)outData = 0;
                    result = noErr;
                }
                break;
            case kAudioStreamPropertyTerminalType:
                if (inDataSize >= sizeof(UInt32)) {
                    *outDataSize = sizeof(UInt32);
                    *(UInt32*)outData = (inObjectID == g_device.inputStreamID) ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
                    result = noErr;
                }
                break;
            default:
                break;
        }
    }
    
    os_log(OS_LOG_DEFAULT, "[LosslessSwitcherPlugin] GetPropertyData finished: result=%d", (int)result);
    os_unfair_lock_unlock(&g_lock);
    
    return result;
}

OSStatus LosslessSwitcherPlugin_SetPropertyData(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientPID,
    const AudioObjectPropertyAddress* inAddress,
    UInt32 inQualifierDataSize,
    const void* inQualifierData,
    UInt32 inDataSize,
    const void* inData) {
    
    if (!inAddress || !inData) {
        return kAudioHardwareUnknownPropertyError;
    }
    
    OSStatus result = kAudioHardwareUnknownPropertyError;
    
    os_unfair_lock_lock(&g_lock);
    
    if (inObjectID == g_device.deviceID) {
        switch (inAddress->mSelector) {
            case kAudioDevicePropertyNominalSampleRate: {
                if (inDataSize >= sizeof(Float64)) {
                    Float64 newSampleRate = *(Float64*)inData;
                    Float64 oldSampleRate = g_device.currentFormat.mSampleRate;
                    
                    // Only process if sample rate actually changed
                    // サンプルレートが実際に変更された場合のみ処理
                    if (abs(newSampleRate - oldSampleRate) > 0.1) {
                        g_device.currentFormat.mSampleRate = newSampleRate;
                        g_readInitialized = false;
                        
                        // Extract bit depth from format
                        UInt32 bitDepth = g_device.currentFormat.mBitsPerChannel;
                        
                        // Get process info
                        char bundleID[256] = {0};
                        GetBundleIDFromPID(inClientPID, bundleID, sizeof(bundleID));
                        
                        // Update active source
                        g_device.activeSource.processID = inClientPID;
                        strncpy(g_device.activeSource.bundleID, bundleID, sizeof(g_device.activeSource.bundleID) - 1);
                        g_device.activeSource.sampleRate = (uint32_t)newSampleRate;
                        g_device.activeSource.bitDepth = bitDepth;
                        memcpy(&g_device.activeSource.format, &g_device.currentFormat, sizeof(AudioStreamBasicDescription));
                        
                        // Notify CoreAudio Host
                        if (g_device.hostRef) {
                            AudioObjectPropertyAddress address = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0 };
                            g_device.hostRef->PropertiesChanged(g_device.hostRef, g_device.deviceID, 1, &address);
                            
                            AudioObjectPropertyAddress streamAddress = { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, 0 };
                            g_device.hostRef->PropertiesChanged(g_device.hostRef, g_device.inputStreamID, 1, &streamAddress);
                            g_device.hostRef->PropertiesChanged(g_device.hostRef, g_device.outputStreamID, 1, &streamAddress);
                        }
                        
                        // Notify Swift side
                        NotifySampleRateChange(inClientPID, bundleID, newSampleRate, bitDepth);
                    }
                    result = noErr;
                }
                break;
            }
            
            default:
                break;
        }
    } else if (inObjectID == g_device.inputStreamID || inObjectID == g_device.outputStreamID) {
        switch (inAddress->mSelector) {
            case kAudioStreamPropertyPhysicalFormat:
            case kAudioStreamPropertyVirtualFormat: {
                if (inDataSize >= sizeof(AudioStreamBasicDescription)) {
                    AudioStreamBasicDescription newFormat = *(AudioStreamBasicDescription*)inData;
                    
                    // Verify if the requested format is supported
                    // サポートされているフォーマットか検証
                    bool formatSupported = false;
                    Float64 rates[] = { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };
                    for (int r = 0; r < 6; ++r) {
                        if (abs(newFormat.mSampleRate - rates[r]) < 0.1) {
                            formatSupported = true;
                            break;
                        }
                    }
                    
                    if (formatSupported) {
                        g_device.currentFormat = newFormat;
                        g_readInitialized = false;
                        
                        // Notify Host that properties changed
                        if (g_device.hostRef) {
                            AudioObjectPropertyAddress streamAddress = { kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, 0 };
                            g_device.hostRef->PropertiesChanged(g_device.hostRef, g_device.inputStreamID, 1, &streamAddress);
                            g_device.hostRef->PropertiesChanged(g_device.hostRef, g_device.outputStreamID, 1, &streamAddress);
                            
                            AudioObjectPropertyAddress deviceAddress = { kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 0 };
                            g_device.hostRef->PropertiesChanged(g_device.hostRef, g_device.deviceID, 1, &deviceAddress);
                        }
                        
                        // Notify Swift app of the format change
                        char bundleID[256] = {0};
                        GetBundleIDFromPID(inClientPID, bundleID, sizeof(bundleID));
                        NotifySampleRateChange(inClientPID, bundleID, newFormat.mSampleRate, newFormat.mBitsPerChannel);
                        
                        result = noErr;
                    } else {
                        result = kAudioDeviceUnsupportedFormatError;
                    }
                }
                break;
            }
            default:
                break;
        }
    }
    
    os_unfair_lock_unlock(&g_lock);
    
    return result;
}

#pragma mark - COM Interface & Properties Helper

static HRESULT LosslessSwitcherPlugin_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (!outInterface) return E_INVALIDARG;
    
    CFUUIDRef requestUUID = CFUUIDCreateFromUUIDBytes(nullptr, inUUID);
    
    if (CFEqual(requestUUID, kAudioServerPlugInDriverInterfaceUUID) || CFEqual(requestUUID, CFUUIDGetConstantUUIDWithBytes(nullptr, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46))) { // IUnknown
        *outInterface = inDriver;
        CFRelease(requestUUID);
        return S_OK;
    }
    
    *outInterface = nullptr;
    CFRelease(requestUUID);
    return E_NOINTERFACE;
}

static ULONG LosslessSwitcherPlugin_AddRef(void* inDriver) {
    return 1;
}

static ULONG LosslessSwitcherPlugin_Release(void* inDriver) {
    return 1;
}

static OSStatus LosslessSwitcherPlugin_InitializeInterface(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    return LosslessSwitcherPlugin_Initialize(inDriver, inHost);
}

static OSStatus LosslessSwitcherPlugin_GetPropertyDataSize(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress* inAddress,
    UInt32 inQualifierDataSize,
    const void* inQualifierData,
    UInt32* outDataSize) {
    
    if (!inAddress || !outDataSize) {
        return kAudioHardwareUnknownPropertyError;
    }
    
    os_log(OS_LOG_DEFAULT, "[LosslessSwitcherPlugin] GetPropertyDataSize: objectID=%u, selector='%c%c%c%c' (%u)",
           inObjectID,
           (char)((inAddress->mSelector >> 24) & 0xFF),
           (char)((inAddress->mSelector >> 16) & 0xFF),
           (char)((inAddress->mSelector >> 8) & 0xFF),
           (char)(inAddress->mSelector & 0xFF),
           inAddress->mSelector);
           
    OSStatus result = kAudioHardwareUnknownPropertyError;
    
    if (inObjectID == kAudioObjectSystemObject) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyClass:
                *outDataSize = sizeof(AudioClassID);
                result = noErr;
                break;
            case kAudioObjectPropertyOwner:
                *outDataSize = sizeof(AudioObjectID);
                result = noErr;
                break;
            case kAudioObjectPropertyManufacturer:
                *outDataSize = sizeof(CFStringRef);
                result = noErr;
                break;
            case kAudioPlugInPropertyDeviceList:
            case kAudioObjectPropertyOwnedObjects:
                *outDataSize = sizeof(AudioObjectID);
                result = noErr;
                break;
            default:
                break;
        }
    }
    
    else if (inObjectID == g_device.deviceID) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyClass:
                *outDataSize = sizeof(AudioClassID);
                result = noErr;
                break;
            case kAudioObjectPropertyOwner:
                *outDataSize = sizeof(AudioObjectID);
                result = noErr;
                break;
            case kAudioObjectPropertyName:
                *outDataSize = sizeof(CFStringRef);
                result = noErr;
                break;
            case kAudioObjectPropertyManufacturer:
                *outDataSize = sizeof(CFStringRef);
                result = noErr;
                break;
            case kAudioDevicePropertyClockDomain:
                *outDataSize = sizeof(UInt32);
                result = noErr;
                break;
            case kAudioDevicePropertyStreamConfiguration: {
                UInt32 numBuffers = 0;
                if (inAddress->mScope == kAudioObjectPropertyScopeInput || inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                    numBuffers = 1;
                }
                *outDataSize = sizeof(AudioBufferList) + (numBuffers > 0 ? (numBuffers - 1) : 0) * sizeof(AudioBuffer);
                result = noErr;
                break;
            }
            case kAudioDevicePropertyDeviceUID:
                *outDataSize = sizeof(CFStringRef);
                result = noErr;
                break;
            case kAudioDevicePropertyModelUID:
                *outDataSize = sizeof(CFStringRef);
                result = noErr;
                break;
            case kAudioDevicePropertyTransportType:
                *outDataSize = sizeof(UInt32);
                result = noErr;
                break;
            case kAudioDevicePropertyNominalSampleRate:
                *outDataSize = sizeof(Float64);
                result = noErr;
                break;
            case kAudioDevicePropertyAvailableNominalSampleRates:
                *outDataSize = 6 * sizeof(Float64);
                result = noErr;
                break;
            case kAudioDevicePropertyStreams: {
                UInt32 numStreams = 0;
                if (inAddress->mScope == kAudioObjectPropertyScopeInput || inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                    numStreams = 1;
                } else if (inAddress->mScope == kAudioObjectPropertyScopeGlobal) {
                    numStreams = 2;
                }
                *outDataSize = numStreams * sizeof(AudioObjectID);
                result = noErr;
                break;
            }
            case kAudioObjectPropertyOwnedObjects:
                *outDataSize = 2 * sizeof(AudioObjectID);
                result = noErr;
                break;
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
                *outDataSize = sizeof(UInt32);
                result = noErr;
                break;
            case kAudioDevicePropertyBufferFrameSizeRange:
                *outDataSize = sizeof(AudioValueRange);
                result = noErr;
                break;
            case kAudioDevicePropertyBufferFrameSize:
                *outDataSize = sizeof(UInt32);
                result = noErr;
                break;
            case kAudioObjectPropertyControlList:
                *outDataSize = 0;
                result = noErr;
                break;
            case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyIsHidden:
                *outDataSize = sizeof(UInt32);
                result = noErr;
                break;
            case kAudioDevicePropertyIcon:
                *outDataSize = sizeof(CFURLRef);
                result = noErr;
                break;
            case kAudioDevicePropertyStreamFormat:
                *outDataSize = sizeof(AudioStreamBasicDescription);
                result = noErr;
                break;
            default:
                break;
        }
    }
    
    else if (inObjectID == g_device.inputStreamID || inObjectID == g_device.outputStreamID) {
        switch (inAddress->mSelector) {
            case kAudioObjectPropertyClass:
                *outDataSize = sizeof(AudioClassID);
                result = noErr;
                break;
            case kAudioObjectPropertyOwner:
                *outDataSize = sizeof(AudioObjectID);
                result = noErr;
                break;
            case kAudioStreamPropertyDirection:
                *outDataSize = sizeof(UInt32);
                result = noErr;
                break;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                *outDataSize = sizeof(AudioStreamBasicDescription);
                result = noErr;
                break;
            case kAudioStreamPropertyStartingChannel:
                *outDataSize = sizeof(UInt32);
                result = noErr;
                break;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                *outDataSize = 24 * sizeof(AudioStreamRangedDescription);
                result = noErr;
                break;
            case kAudioObjectPropertyOwnedObjects:
                *outDataSize = 0;
                result = noErr;
                break;
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyLatency:
            case kAudioStreamPropertyTerminalType:
                *outDataSize = sizeof(UInt32);
                result = noErr;
                break;
            default:
                break;
        }
    }
    
    os_log(OS_LOG_DEFAULT, "[LosslessSwitcherPlugin] GetPropertyDataSize finished: result=%d, size=%u", (int)result, *outDataSize);
    return result;
}

static Boolean LosslessSwitcherPlugin_HasProperty(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress* inAddress) {
    
    if (!inAddress) return false;
    
    if (inObjectID == kAudioObjectSystemObject) {
        return (inAddress->mSelector == kAudioObjectPropertyClass ||
                inAddress->mSelector == kAudioObjectPropertyOwner ||
                inAddress->mSelector == kAudioObjectPropertyManufacturer ||
                inAddress->mSelector == kAudioPlugInPropertyDeviceList ||
                inAddress->mSelector == kAudioObjectPropertyOwnedObjects);
    }
    
    if (inObjectID == g_device.deviceID) {
        return (inAddress->mSelector == kAudioObjectPropertyClass ||
                inAddress->mSelector == kAudioObjectPropertyOwner ||
                inAddress->mSelector == kAudioObjectPropertyName ||
                inAddress->mSelector == kAudioObjectPropertyManufacturer ||
                inAddress->mSelector == kAudioDevicePropertyClockDomain ||
                inAddress->mSelector == kAudioDevicePropertyStreamConfiguration ||
                inAddress->mSelector == kAudioDevicePropertyDeviceUID ||
                inAddress->mSelector == kAudioDevicePropertyModelUID ||
                inAddress->mSelector == kAudioDevicePropertyTransportType ||
                inAddress->mSelector == kAudioDevicePropertyNominalSampleRate ||
                inAddress->mSelector == kAudioDevicePropertyAvailableNominalSampleRates ||
                inAddress->mSelector == kAudioDevicePropertyStreams ||
                inAddress->mSelector == kAudioDevicePropertyBufferFrameSize ||
                inAddress->mSelector == kAudioObjectPropertyControlList ||
                inAddress->mSelector == kAudioDevicePropertyZeroTimeStampPeriod ||
                inAddress->mSelector == kAudioDevicePropertyIsHidden ||
                inAddress->mSelector == kAudioDevicePropertyIcon ||
                inAddress->mSelector == kAudioDevicePropertyStreamFormat ||
                inAddress->mSelector == kAudioObjectPropertyOwnedObjects ||
                inAddress->mSelector == kAudioDevicePropertyDeviceIsAlive ||
                inAddress->mSelector == kAudioDevicePropertyDeviceIsRunning ||
                inAddress->mSelector == kAudioDevicePropertyDeviceCanBeDefaultDevice ||
                inAddress->mSelector == kAudioDevicePropertyDeviceCanBeDefaultSystemDevice ||
                inAddress->mSelector == kAudioDevicePropertyLatency ||
                inAddress->mSelector == kAudioDevicePropertySafetyOffset ||
                inAddress->mSelector == kAudioDevicePropertyBufferFrameSizeRange);
    }
    
    if (inObjectID == g_device.inputStreamID || inObjectID == g_device.outputStreamID) {
        return (inAddress->mSelector == kAudioObjectPropertyClass ||
                inAddress->mSelector == kAudioObjectPropertyOwner ||
                inAddress->mSelector == kAudioStreamPropertyDirection ||
                inAddress->mSelector == kAudioStreamPropertyVirtualFormat ||
                inAddress->mSelector == kAudioStreamPropertyPhysicalFormat ||
                inAddress->mSelector == kAudioStreamPropertyStartingChannel ||
                inAddress->mSelector == kAudioStreamPropertyAvailableVirtualFormats ||
                inAddress->mSelector == kAudioStreamPropertyAvailablePhysicalFormats ||
                inAddress->mSelector == kAudioObjectPropertyOwnedObjects ||
                inAddress->mSelector == kAudioStreamPropertyIsActive ||
                inAddress->mSelector == kAudioStreamPropertyLatency ||
                inAddress->mSelector == kAudioStreamPropertyTerminalType);
    }
    
    return false;
}

static OSStatus LosslessSwitcherPlugin_IsPropertySettable(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inObjectID,
    pid_t inClientProcessID,
    const AudioObjectPropertyAddress* inAddress,
    Boolean* outIsSettable) {
    
    if (!inAddress || !outIsSettable) return kAudioHardwareUnknownPropertyError;
    
    if (inObjectID == g_device.deviceID) {
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
            *outIsSettable = true;
            return noErr;
        }
    }
    
    if (inObjectID == g_device.inputStreamID || inObjectID == g_device.outputStreamID) {
        if (inAddress->mSelector == kAudioStreamPropertyPhysicalFormat ||
            inAddress->mSelector == kAudioStreamPropertyVirtualFormat) {
            *outIsSettable = true;
            return noErr;
        }
    }
    
    *outIsSettable = false;
    return noErr;
}

#pragma mark - Client Operations

static OSStatus LosslessSwitcherPlugin_AddDeviceClient(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceID,
    const AudioServerPlugInClientInfo* inClientInfo) {
    
    os_unfair_lock_lock(&g_lock);
    os_log(OS_LOG_DEFAULT, "[LosslessSwitcherPlugin] AddDeviceClient: deviceID=%u, clientPID=%d, bundle=%s",
           inDeviceID, inClientInfo->mProcessID,
           inClientInfo->mBundleID ? CFStringGetCStringPtr(inClientInfo->mBundleID, kCFStringEncodingUTF8) : "None");
    os_unfair_lock_unlock(&g_lock);
    return noErr;
}

static OSStatus LosslessSwitcherPlugin_RemoveDeviceClient(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceID,
    const AudioServerPlugInClientInfo* inClientInfo) {
    
    os_unfair_lock_lock(&g_lock);
    os_log(OS_LOG_DEFAULT, "[LosslessSwitcherPlugin] RemoveDeviceClient: deviceID=%u, clientPID=%d", inDeviceID, inClientInfo->mProcessID);
    os_unfair_lock_unlock(&g_lock);
    return noErr;
}

#pragma mark - IO Operations

static OSStatus LosslessSwitcherPlugin_StartIO(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceID,
    UInt32 inClientID) {
    
    os_unfair_lock_lock(&g_lock);
    os_log(OS_LOG_DEFAULT, "[LosslessSwitcherPlugin] StartIO: deviceID=%u, clientID=%u", inDeviceID, inClientID);
    os_unfair_lock_unlock(&g_lock);
    return noErr;
}

static OSStatus LosslessSwitcherPlugin_StopIO(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceID,
    UInt32 inClientID) {
    
    os_unfair_lock_lock(&g_lock);
    os_log(OS_LOG_DEFAULT, "[LosslessSwitcherPlugin] StopIO: deviceID=%u, clientID=%u", inDeviceID, inClientID);
    g_readInitialized = false;
    os_unfair_lock_unlock(&g_lock);
    return noErr;
}

static OSStatus LosslessSwitcherPlugin_GetZeroTimeStamp(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceID,
    UInt32 inClientID,
    Float64* outSampleTime,
    UInt64* outHostTime,
    UInt64* outSeed) {
    
    if (outSampleTime) *outSampleTime = 0.0;
    if (outHostTime) *outHostTime = mach_absolute_time();
    if (outSeed) *outSeed = 1;
    return noErr;
}

static OSStatus LosslessSwitcherPlugin_WillDoIOOperation(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceID,
    UInt32 inClientID,
    UInt32 inOperationID,
    Boolean* outWillDo,
    Boolean* outWillDoInPlace) {
    
    if (outWillDo) *outWillDo = true;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return noErr;
}

static OSStatus LosslessSwitcherPlugin_BeginIOOperation(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceID,
    UInt32 inClientID,
    UInt32 inOperationID,
    UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    
    return noErr;
}

#define RING_BUFFER_SIZE_BYTES (524288) // 512 KB
static uint8_t g_ringBuffer[RING_BUFFER_SIZE_BYTES] = {0};
static uint32_t g_ringBufferWriteIndex = 16384; // Start with offset
static uint32_t g_ringBufferReadIndex = 0;

static OSStatus LosslessSwitcherPlugin_DoIOOperation(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceID,
    AudioObjectID inStreamObjectID,
    UInt32 inClientID,
    UInt32 inOperationID,
    UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
    void* ioMainBuffer,
    void* ioSecondaryBuffer) {
    
    os_unfair_lock_lock(&g_lock);
    uint32_t bytesPerFrame = g_device.currentFormat.mBytesPerFrame;
    if (bytesPerFrame == 0) bytesPerFrame = 8; // Fallback
    
    if (inStreamObjectID == g_device.outputStreamID && ioMainBuffer && inIOBufferFrameSize > 0) {
        uint8_t* src = (uint8_t*)ioMainBuffer;
        uint32_t bytesToWrite = inIOBufferFrameSize * bytesPerFrame;
        uint32_t writeIdx = g_ringBufferWriteIndex;
        
        for (uint32_t i = 0; i < bytesToWrite; ++i) {
            g_ringBuffer[writeIdx] = src[i];
            writeIdx = (writeIdx + 1) % RING_BUFFER_SIZE_BYTES;
        }
        g_ringBufferWriteIndex = writeIdx;
    }
    
    else if (inStreamObjectID == g_device.inputStreamID && ioMainBuffer && inIOBufferFrameSize > 0) {
        uint8_t* dst = (uint8_t*)ioMainBuffer;
        uint32_t bytesToRead = inIOBufferFrameSize * bytesPerFrame;
        uint32_t readIdx = g_ringBufferReadIndex;
        
        // Initialize read index to safety offset exactly once per active capture stream to prevent latency accumulation
        if (!g_readInitialized) {
            uint32_t safetyOffset = 1024 * bytesPerFrame;
            readIdx = (g_ringBufferWriteIndex + RING_BUFFER_SIZE_BYTES - safetyOffset) % RING_BUFFER_SIZE_BYTES;
            g_readInitialized = true;
        }
        
        for (uint32_t i = 0; i < bytesToRead; ++i) {
            dst[i] = g_ringBuffer[readIdx];
            readIdx = (readIdx + 1) % RING_BUFFER_SIZE_BYTES;
        }
        g_ringBufferReadIndex = readIdx;
    }
    
    os_unfair_lock_unlock(&g_lock);
    return noErr;
}

static OSStatus LosslessSwitcherPlugin_EndIOOperation(
    AudioServerPlugInDriverRef inDriver,
    AudioObjectID inDeviceID,
    UInt32 inClientID,
    UInt32 inOperationID,
    UInt32 inIOBufferFrameSize,
    const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    
    return noErr;
}

#pragma mark - Callback Registration

void LosslessSwitcherPlugin_RegisterSampleRateCallback(
    SampleRateChangeCallback callback,
    void* userData) {
    
    os_unfair_lock_lock(&g_lock);
    g_sampleRateCallback = callback;
    g_callbackUserData = userData;
    os_log(OS_LOG_DEFAULT, "[LosslessSwitcherPlugin] Callback registered");
    os_unfair_lock_unlock(&g_lock);
}

#pragma mark - Interface Table & Entry Point

static AudioServerPlugInDriverInterface gAudioServerPlugInDriverInterface = {
    nullptr,                                // _reserved
    LosslessSwitcherPlugin_QueryInterface,
    LosslessSwitcherPlugin_AddRef,
    LosslessSwitcherPlugin_Release,
    LosslessSwitcherPlugin_InitializeInterface,
    nullptr,                                // CreateDevice
    nullptr,                                // DestroyDevice
    LosslessSwitcherPlugin_AddDeviceClient,
    LosslessSwitcherPlugin_RemoveDeviceClient,
    nullptr,                                // PerformDeviceConfigurationChange
    nullptr,                                // AbortDeviceConfigurationChange
    LosslessSwitcherPlugin_HasProperty,
    LosslessSwitcherPlugin_IsPropertySettable,
    LosslessSwitcherPlugin_GetPropertyDataSize,
    LosslessSwitcherPlugin_GetPropertyData,
    LosslessSwitcherPlugin_SetPropertyData,
    LosslessSwitcherPlugin_StartIO,
    LosslessSwitcherPlugin_StopIO,
    LosslessSwitcherPlugin_GetZeroTimeStamp,
    LosslessSwitcherPlugin_WillDoIOOperation,
    LosslessSwitcherPlugin_BeginIOOperation,
    LosslessSwitcherPlugin_DoIOOperation,
    LosslessSwitcherPlugin_EndIOOperation
};

static AudioServerPlugInDriverInterface* gAudioServerPlugInDriverInterfacePtr = &gAudioServerPlugInDriverInterface;

extern "C" {

void* AudioServerPlugInDriverEntry(
    CFAllocatorRef inAllocator,
    CFUUIDRef inRequestedTypeUUID) {
    
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return &gAudioServerPlugInDriverInterfacePtr;
    }
    return nullptr;
}

} // extern "C"
