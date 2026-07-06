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

#pragma mark - Global State

// Global device object / グローバルデバイスオブジェクト
static LosslessSwitcherDevice g_device = {};
static SampleRateChangeCallback g_sampleRateCallback = nullptr;
static void* g_callbackUserData = nullptr;
static dispatch_once_t g_initOnce = 0;
#include <os/lock.h>
static os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;

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
    if (g_sampleRateCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            g_sampleRateCallback(clientPID, bundleID, newSampleRate, bitDepth);
        });
    }
    
    os_log(OS_LOG_DEFAULT, "[LosslessSwitcherPlugin] Sample Rate Changed: PID=%d, Rate=%.1f Hz, BitDepth=%u bits",
           clientPID, newSampleRate, bitDepth);
}

#pragma mark - Plugin Initialization

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
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                if (inDataSize >= sizeof(UInt32)) {
                    *outDataSize = sizeof(UInt32);
                    *(UInt32*)outData = 1;
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
                UInt32 expectedSize = 6 * sizeof(AudioStreamRangedDescription);
                if (inDataSize >= expectedSize) {
                    *outDataSize = expectedSize;
                    AudioStreamRangedDescription* formats = (AudioStreamRangedDescription*)outData;
                    Float64 rates[] = { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };
                    for (int i = 0; i < 6; ++i) {
                        formats[i].mFormat.mSampleRate = rates[i];
                        formats[i].mFormat.mFormatID = kAudioFormatLinearPCM;
                        formats[i].mFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
                        formats[i].mFormat.mBytesPerPacket = 8;
                        formats[i].mFormat.mFramesPerPacket = 1;
                        formats[i].mFormat.mBytesPerFrame = 8;
                        formats[i].mFormat.mChannelsPerFrame = 2;
                        formats[i].mFormat.mBitsPerChannel = 32;
                        
                        formats[i].mSampleRateRange.mMinimum = rates[i];
                        formats[i].mSampleRateRange.mMaximum = rates[i];
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
                *outDataSize = sizeof(UInt32);
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
                *outDataSize = 6 * sizeof(AudioStreamRangedDescription);
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
    
    *outIsSettable = false;
    return noErr;
}

#pragma mark - IO Operations

OSStatus LosslessSwitcherPlugin_ReadRawAudioStream(
    AudioServerPlugInDriverRef inDriver,
    const AudioObjectPropertyAddress* inAddress,
    const AudioStreamBasicDescription* inFormat,
    const AudioBufferList* outBufferList,
    const AudioServerPlugInIOCycleInfo* ioContext) {
    
    if (!outBufferList || outBufferList->mNumberBuffers == 0) {
        return noErr;
    }
    for (UInt32 i = 0; i < outBufferList->mNumberBuffers; ++i) {
        if (outBufferList->mBuffers[i].mData) {
            memset(outBufferList->mBuffers[i].mData, 0, outBufferList->mBuffers[i].mDataByteSize);
        }
    }
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
    nullptr,
    LosslessSwitcherPlugin_QueryInterface,
    LosslessSwitcherPlugin_AddRef,
    LosslessSwitcherPlugin_Release,
    LosslessSwitcherPlugin_InitializeInterface,
    nullptr, // CreateDevice
    nullptr, // DestroyDevice
    nullptr, // AddDevice
    nullptr, // RemoveDevice
    nullptr, // StartIO
    nullptr, // StopIO
    LosslessSwitcherPlugin_HasProperty,
    LosslessSwitcherPlugin_IsPropertySettable,
    LosslessSwitcherPlugin_GetPropertyDataSize,
    LosslessSwitcherPlugin_GetPropertyData,
    LosslessSwitcherPlugin_SetPropertyData,
    nullptr, // GetZeroTimeStamp
    nullptr, // WillDoIOOperation
    nullptr, // BeginIOOperation
    nullptr, // DoIOOperation
    nullptr  // EndIOOperation
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
