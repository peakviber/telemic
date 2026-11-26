// Telemic — an input-only virtual microphone (Core Audio AudioServerPlugIn).
//
// Audio never "plays" through any app on the host: a receiver sends PCM to this
// plug-in over a loopback UDP socket, and the plug-in hands it straight to apps
// that record from the "Telemic" device. Screen-capture tools that collect
// per-app audio output (e.g. UU Remote via ScreenCaptureKit) therefore can't see it.
//
// Loopback protocol (127.0.0.1:47811, UDP), 8-byte header then payload:
//   "RMIC" | type(1) | pad(3) | payload
//   type 1: PCM, float32, mono, 48 kHz, native endian
//   type 2: built-in test tone on      type 3: test tone off

#include <CoreAudio/AudioServerPlugIn.h>
#include <arpa/inet.h>
#include <mach/mach_time.h>
#include <math.h>
#include <netinet/in.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#pragma mark - Constants

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_Stream = 3,
};

#define kDeviceName         "Telemic"
#define kManufacturer       "Telemic"
#define kDeviceUID          "Telemic_Device_UID"
#define kModelUID           "Telemic_Model_UID"
#define kSampleRate         48000.0
#define kZeroPeriod         16384u
#define kLoopbackPort       47811

#define kRingFrames         (48000u * 2u)    // 2 s of capacity
#define kPrebufferFrames    (48u * 40u)      // start after 40 ms buffered
#define kMaxLatencyFrames   (48u * 250u)     // skip ahead above 250 ms

static os_log_t gLog;

#pragma mark - State

static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;

static Float64 gTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gNumberTimeStamps = 0;
static UInt32 gIOCount = 0;
static pthread_mutex_t gIOMutex = PTHREAD_MUTEX_INITIALIZER;

// Single-producer (receiver thread) / single-consumer (IO thread) ring buffer.
static float gRing[kRingFrames];
static _Atomic UInt64 gWritePos = 0;
static _Atomic UInt64 gReadPos = 0;
static bool gPlaying = false;   // IO thread only

static _Atomic bool gTone = false;
static double gTonePhase = 0;   // IO thread only

static pthread_t gReceiver;

#pragma mark - Ring buffer

static void RingWrite(const float* src, UInt32 frames) {
    UInt64 w = atomic_load_explicit(&gWritePos, memory_order_relaxed);
    UInt64 r = atomic_load_explicit(&gReadPos, memory_order_acquire);
    UInt64 space = kRingFrames - (w - r);
    if (frames > space) frames = (UInt32)space;   // full: drop the excess
    for (UInt32 i = 0; i < frames; i++) gRing[(w + i) % kRingFrames] = src[i];
    atomic_store_explicit(&gWritePos, w + frames, memory_order_release);
}

// Real-time safe: no locks, no allocation.
static void RingRead(float* dst, UInt32 frames) {
    UInt64 w = atomic_load_explicit(&gWritePos, memory_order_acquire);
    UInt64 r = atomic_load_explicit(&gReadPos, memory_order_relaxed);
    UInt64 fill = w - r;

    if (fill > kMaxLatencyFrames) {               // too much backlog: catch up
        r = w - kPrebufferFrames;
        fill = kPrebufferFrames;
    }
    if (!gPlaying && fill >= kPrebufferFrames) gPlaying = true;

    UInt32 n = 0;
    if (gPlaying) {
        n = (fill < frames) ? (UInt32)fill : frames;
        for (UInt32 i = 0; i < n; i++) dst[i] = gRing[(r + i) % kRingFrames];
        r += n;
        if (n < frames) gPlaying = false;         // underrun: rebuffer
    }
    for (UInt32 i = n; i < frames; i++) dst[i] = 0.0f;
    atomic_store_explicit(&gReadPos, r, memory_order_release);
}

#pragma mark - Loopback receiver

static void* ReceiverMain(void* arg) {
    (void)arg;
    int s = -1;
    while (s < 0) {
        s = socket(AF_INET, SOCK_DGRAM, 0);
        if (s < 0) { sleep(2); continue; }
        int one = 1;
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in addr = {0};
        addr.sin_family = AF_INET;
        addr.sin_port = htons(kLoopbackPort);
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(s, (struct sockaddr*)&addr, sizeof addr) != 0) {
            os_log_error(gLog, "bind 127.0.0.1:%d failed, retrying", kLoopbackPort);
            close(s); s = -1; sleep(2);
        }
    }
    os_log(gLog, "listening on 127.0.0.1:%d", kLoopbackPort);

    static uint8_t pkt[16384];
    static float frames[4096];
    for (;;) {
        ssize_t n = recv(s, pkt, sizeof pkt, 0);
        if (n < 8 || memcmp(pkt, "RMIC", 4) != 0) continue;
        switch (pkt[4]) {
            case 1: {
                size_t count = (size_t)(n - 8) / sizeof(float);
                if (count > 4096) count = 4096;
                memcpy(frames, pkt + 8, count * sizeof(float));
                RingWrite(frames, (UInt32)count);
                break;
            }
            case 2: atomic_store(&gTone, true);  os_log(gLog, "test tone on");  break;
            case 3: atomic_store(&gTone, false); os_log(gLog, "test tone off"); break;
        }
    }
    return NULL;
}

#pragma mark - Formats

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = 4;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = 4;
    f.mChannelsPerFrame = 1;
    f.mBitsPerChannel = 32;
    return f;
}

#pragma mark - Property access

#define RET_VALUE(T, val) do { \
    if (outData) { \
        if (inDataSize < sizeof(T)) return kAudioHardwareBadPropertySizeError; \
        *(T*)outData = (val); \
    } \
    *outSize = sizeof(T); \
    return kAudioHardwareNoError; \
} while (0)

#define RET_IDS(arr, count) do { \
    UInt32 n_ = (count); \
    if (outData) { \
        UInt32 cap_ = inDataSize / sizeof(AudioObjectID); \
        if (cap_ < n_) n_ = cap_; \
        if (n_) memcpy(outData, (arr), n_ * sizeof(AudioObjectID)); \
    } \
    *outSize = n_ * sizeof(AudioObjectID); \
    return kAudioHardwareNoError; \
} while (0)

// outData == NULL means "size only".
static OSStatus Prop(AudioObjectID obj, const AudioObjectPropertyAddress* a,
                     UInt32 qSize, const void* qData,
                     UInt32 inDataSize, UInt32* outSize, void* outData) {
    static const AudioObjectID kDeviceList[] = { kObjectID_Device };
    static const AudioObjectID kStreamList[] = { kObjectID_Stream };
    static const AudioObjectID kNone[] = { 0 };

    switch (obj) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:   RET_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:       RET_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner:       RET_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RET_VALUE(CFStringRef, CFSTR(kManufacturer));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:  RET_IDS(kDeviceList, 1);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID found = kAudioObjectUnknown;
            if (outData) {
                if (qSize != sizeof(CFStringRef) || qData == NULL) return kAudioHardwareBadPropertySizeError;
                CFStringRef uid = *(const CFStringRef*)qData;
                if (uid && CFStringCompare(uid, CFSTR(kDeviceUID), 0) == kCFCompareEqualTo) found = kObjectID_Device;
            }
            RET_VALUE(AudioObjectID, found);
        }
        case kAudioPlugInPropertyResourceBundle: RET_VALUE(CFStringRef, CFSTR(""));
        }
        break;

    case kObjectID_Device: {
        bool inputOrGlobal = a->mScope != kAudioObjectPropertyScopeOutput;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:   RET_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:       RET_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:       RET_VALUE(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName:        RET_VALUE(CFStringRef, CFSTR(kDeviceName));
        case kAudioObjectPropertyManufacturer: RET_VALUE(CFStringRef, CFSTR(kManufacturer));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams:
            if (inputOrGlobal) RET_IDS(kStreamList, 1);
            RET_IDS(kNone, 0);
        case kAudioObjectPropertyControlList: RET_IDS(kNone, 0);
        case kAudioDevicePropertyDeviceUID:   RET_VALUE(CFStringRef, CFSTR(kDeviceUID));
        case kAudioDevicePropertyModelUID:    RET_VALUE(CFStringRef, CFSTR(kModelUID));
        case kAudioDevicePropertyTransportType: RET_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: RET_IDS(kDeviceList, 1);
        case kAudioDevicePropertyClockDomain: RET_VALUE(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: RET_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: RET_VALUE(UInt32, gIOCount > 0 ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: RET_VALUE(UInt32, a->mScope == kAudioObjectPropertyScopeInput ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RET_VALUE(UInt32, 0);
        case kAudioDevicePropertyLatency:     RET_VALUE(UInt32, 0);
        case kAudioDevicePropertySafetyOffset: RET_VALUE(UInt32, 0);
        case kAudioDevicePropertyNominalSampleRate: RET_VALUE(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange r = { kSampleRate, kSampleRate };
            RET_VALUE(AudioValueRange, r);
        }
        case kAudioDevicePropertyIsHidden:    RET_VALUE(UInt32, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: RET_VALUE(UInt32, kZeroPeriod);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (outData) {
                if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
                ((UInt32*)outData)[0] = 1;
                ((UInt32*)outData)[1] = 1;
            }
            *outSize = 2 * sizeof(UInt32);
            return kAudioHardwareNoError;
        }
        }
        break;
    }

    case kObjectID_Stream:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:   RET_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:       RET_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner:       RET_VALUE(AudioObjectID, kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects: RET_IDS(kNone, 0);
        case kAudioStreamPropertyIsActive:    RET_VALUE(UInt32, 1);
        case kAudioStreamPropertyDirection:   RET_VALUE(UInt32, 1);   // 1 = input
        case kAudioStreamPropertyTerminalType: RET_VALUE(UInt32, kAudioStreamTerminalTypeMicrophone);
        case kAudioStreamPropertyStartingChannel: RET_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency:     RET_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            RET_VALUE(AudioStreamBasicDescription, StreamFormat());
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription d;
            d.mFormat = StreamFormat();
            d.mSampleRateRange.mMinimum = kSampleRate;
            d.mSampleRateRange.mMaximum = kSampleRate;
            RET_VALUE(AudioStreamRangedDescription, d);
        }
        }
        break;
    }
    return kAudioHardwareUnknownPropertyError;
}

#pragma mark - Driver interface

static HRESULT QueryInterface(void* drv, REFIID uuid, LPVOID* out);
static ULONG AddRef(void* drv);
static ULONG Release(void* drv);
static OSStatus Initialize(AudioServerPlugInDriverRef drv, AudioServerPlugInHostRef host);
static OSStatus CreateDevice(AudioServerPlugInDriverRef drv, CFDictionaryRef desc, const AudioServerPlugInClientInfo* ci, AudioObjectID* outID);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef drv, AudioObjectID dev);
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef drv, AudioObjectID dev, const AudioServerPlugInClientInfo* ci);
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef drv, AudioObjectID dev, const AudioServerPlugInClientInfo* ci);
static OSStatus PerformConfigChange(AudioServerPlugInDriverRef drv, AudioObjectID dev, UInt64 action, void* info);
static OSStatus AbortConfigChange(AudioServerPlugInDriverRef drv, AudioObjectID dev, UInt64 action, void* info);
static Boolean HasProperty(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a);
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a, Boolean* out);
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a, UInt32 qSize, const void* qData, UInt32* outSize);
static OSStatus GetPropertyData(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a, UInt32 qSize, const void* qData, UInt32 inSize, UInt32* outSize, void* outData);
static OSStatus SetPropertyData(AudioServerPlugInDriverRef drv, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a, UInt32 qSize, const void* qData, UInt32 inSize, const void* inData);
static OSStatus StartIO(AudioServerPlugInDriverRef drv, AudioObjectID dev, UInt32 client);
static OSStatus StopIO(AudioServerPlugInDriverRef drv, AudioObjectID dev, UInt32 client);
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef drv, AudioObjectID dev, UInt32 client, Float64* outSample, UInt64* outHost, UInt64* outSeed);
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef drv, AudioObjectID dev, UInt32 client, UInt32 op, Boolean* outWill, Boolean* outInPlace);
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef drv, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle);
static OSStatus DoIOOperation(AudioServerPlugInDriverRef drv, AudioObjectID dev, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle, void* mainBuf, void* secondaryBuf);
static OSStatus EndIOOperation(AudioServerPlugInDriverRef drv, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    QueryInterface, AddRef, Release,
    Initialize, CreateDevice, DestroyDevice,
    AddDeviceClient, RemoveDeviceClient,
    PerformConfigChange, AbortConfigChange,
    HasProperty, IsPropertySettable, GetPropertyDataSize, GetPropertyData, SetPropertyData,
    StartIO, StopIO, GetZeroTimeStamp,
    WillDoIOOperation, BeginIOOperation, DoIOOperation, EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// Factory named in Info.plist (CFPlugInFactories).
__attribute__((visibility("default")))
void* Telemic_Create(CFAllocatorRef allocator, CFUUIDRef requestedType) {
    (void)allocator;
    if (CFEqual(requestedType, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

static HRESULT QueryInterface(void* drv, REFIID uuid, LPVOID* out) {
    if (drv != gDriverRef || out == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID)) {
        gRefCount++;
        *out = gDriverRef;
        r = S_OK;
    }
    CFRelease(req);
    return r;
}

static ULONG AddRef(void* drv) { (void)drv; return ++gRefCount; }
static ULONG Release(void* drv) { (void)drv; if (gRefCount) gRefCount--; return gRefCount; }

static OSStatus Initialize(AudioServerPlugInDriverRef drv, AudioServerPlugInHostRef host) {
    (void)drv;
    gLog = os_log_create("com.peakviber.telemic.driver", "driver");
    gHost = host;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    Float64 hostTicksPerSecond = 1e9 * (Float64)tb.denom / (Float64)tb.numer;
    gTicksPerFrame = hostTicksPerSecond / kSampleRate;
    pthread_create(&gReceiver, NULL, ReceiverMain, NULL);
    os_log(gLog, "Telemic driver initialized");
    return kAudioHardwareNoError;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* ci, AudioObjectID* outID) {
    (void)d; (void)desc; (void)ci; (void)outID;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID dev) {
    (void)d; (void)dev;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo* ci) {
    (void)d; (void)dev; (void)ci; return kAudioHardwareNoError;
}
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo* ci) {
    (void)d; (void)dev; (void)ci; return kAudioHardwareNoError;
}
static OSStatus PerformConfigChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void* info) {
    (void)d; (void)dev; (void)action; (void)info; return kAudioHardwareNoError;
}
static OSStatus AbortConfigChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void* info) {
    (void)d; (void)dev; (void)action; (void)info; return kAudioHardwareNoError;
}

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a) {
    (void)d; (void)pid;
    UInt32 size = 0;
    return Prop(obj, a, 0, NULL, 0, &size, NULL) == kAudioHardwareNoError;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a, Boolean* out) {
    (void)d; (void)pid;
    UInt32 size = 0;
    OSStatus err = Prop(obj, a, 0, NULL, 0, &size, NULL);
    if (err) return err;
    *out = (obj == kObjectID_Device && a->mSelector == kAudioDevicePropertyNominalSampleRate) ||
           (obj == kObjectID_Stream && (a->mSelector == kAudioStreamPropertyVirtualFormat ||
                                        a->mSelector == kAudioStreamPropertyPhysicalFormat));
    return kAudioHardwareNoError;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a, UInt32 qSize, const void* qData, UInt32* outSize) {
    (void)d; (void)pid;
    return Prop(obj, a, qSize, qData, 0, outSize, NULL);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a, UInt32 qSize, const void* qData, UInt32 inSize, UInt32* outSize, void* outData) {
    (void)d; (void)pid;
    if (outData == NULL) return kAudioHardwareIllegalOperationError;
    return Prop(obj, a, qSize, qData, inSize, outSize, outData);
}

// Only one format exists, so "setting" it to that format is a no-op.
static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a, UInt32 qSize, const void* qData, UInt32 inSize, const void* inData) {
    (void)d; (void)pid; (void)qSize; (void)qData;
    if (obj == kObjectID_Device && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inSize != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *(const Float64*)inData == kSampleRate ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    }
    if (obj == kObjectID_Stream && (a->mSelector == kAudioStreamPropertyVirtualFormat ||
                                    a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inSize != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription* f = inData;
        return (f->mSampleRate == kSampleRate && f->mChannelsPerFrame == 1 &&
                f->mFormatID == kAudioFormatLinearPCM && f->mBitsPerChannel == 32)
            ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)dev; (void)client;
    pthread_mutex_lock(&gIOMutex);
    if (gIOCount == 0) {
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        // Start fresh: drop anything queued while nobody was listening.
        atomic_store(&gReadPos, atomic_load(&gWritePos));
        gPlaying = false;
    }
    gIOCount++;
    pthread_mutex_unlock(&gIOMutex);
    return kAudioHardwareNoError;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)dev; (void)client;
    pthread_mutex_lock(&gIOMutex);
    if (gIOCount) gIOCount--;
    pthread_mutex_unlock(&gIOMutex);
    return kAudioHardwareNoError;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, Float64* outSample, UInt64* outHost, UInt64* outSeed) {
    (void)d; (void)dev; (void)client;
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gTicksPerFrame * kZeroPeriod;
    UInt64 next = gAnchorHostTime + (UInt64)((gNumberTimeStamps + 1) * ticksPerPeriod);
    if (next <= now) gNumberTimeStamps++;
    *outSample = (Float64)(gNumberTimeStamps * kZeroPeriod);
    *outHost = gAnchorHostTime + (UInt64)(gNumberTimeStamps * ticksPerPeriod);
    *outSeed = 1;
    return kAudioHardwareNoError;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, Boolean* outWill, Boolean* outInPlace) {
    (void)d; (void)dev; (void)client;
    *outWill = (op == kAudioServerPlugInIOOperationReadInput);
    *outInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle) {
    (void)d; (void)dev; (void)client; (void)op; (void)frames; (void)cycle;
    return kAudioHardwareNoError;
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle, void* mainBuf, void* secondaryBuf) {
    (void)d; (void)dev; (void)stream; (void)client; (void)cycle; (void)secondaryBuf;
    if (op != kAudioServerPlugInIOOperationReadInput || mainBuf == NULL) return kAudioHardwareNoError;
    float* out = mainBuf;
    if (atomic_load_explicit(&gTone, memory_order_relaxed)) {
        const double step = 2.0 * M_PI * 440.0 / kSampleRate;
        for (UInt32 i = 0; i < frames; i++) {
            out[i] = 0.2f * (float)sin(gTonePhase);
            gTonePhase += step;
            if (gTonePhase > 2.0 * M_PI) gTonePhase -= 2.0 * M_PI;
        }
    } else {
        RingRead(out, frames);
    }
    return kAudioHardwareNoError;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle) {
    (void)d; (void)dev; (void)client; (void)op; (void)frames; (void)cycle;
    return kAudioHardwareNoError;
}
