// Copied from react-native-davoice (TTSNPM ios/SpeechBridge/SpeechBridge.m); only the React imports changed (DVRNShim.h).
// SpeechBridge.m
#import "SpeechBridge.h"
#import "DVRNShim.h"
#import <AudioToolbox/AudioToolbox.h>

// Import your Swift classes (names as in your project)
#import <DaVoiceTTS/DaVoiceTTS-Swift.h>   // DaVoiceTTS + STT live here in your setup

#import <AVFAudio/AVFAudio.h>
#import <Speech/Speech.h>

static const BOOL SBBridgeDebugLogsEnabled = NO;

static void SBDebugLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void SBDebugLog(NSString *format, ...)
{
  if (!SBBridgeDebugLogsEnabled) return;
  va_list args;
  va_start(args, format);
  NSLogv(format, args);
  va_end(args);
}

// Stable on-disk location for a downloaded http(s) asset, keyed by URL. Metro asset
// URLs carry a content hash, so the same URL means the same bytes and the file can be
// reused across calls and launches instead of re-downloading (e.g. on every wake-word
// ping sound in a debug build) every time.
static NSString *SBCachedFilePathForRemoteAsset(NSString *urlString) {
  NSString *ext = [NSURL URLWithString:urlString].pathExtension;
  if (ext.length == 0) ext = @"wav";
  unsigned long long h = 1469598103934665603ULL;  // FNV-1a: deterministic across launches
  for (NSUInteger i = 0; i < urlString.length; i++) {
    h ^= (unsigned long long)[urlString characterAtIndex:i];
    h *= 1099511628211ULL;
  }
  NSString *name = [NSString stringWithFormat:@"rn_asset_%016llx.%@", h, ext];
  return [NSTemporaryDirectory() stringByAppendingPathComponent:name];
}

static NSData *SB_Base64Decode(NSString *b64) {
  if (!b64 || (id)b64 == [NSNull null]) return nil;
  return [[NSData alloc] initWithBase64EncodedString:b64 options:0];
}

static BOOL SBHasMicPermission(void) {
  AVAudioSessionRecordPermission permission = [[AVAudioSession sharedInstance] recordPermission];
  return permission == AVAudioSessionRecordPermissionGranted;
}

static BOOL SBHasSpeechRecognitionPermission(void) {
  SFSpeechRecognizerAuthorizationStatus status = [SFSpeechRecognizer authorizationStatus];
  return status == SFSpeechRecognizerAuthorizationStatusAuthorized;
}

static NSString *SBNowString(void) {
  static NSDateFormatter *formatter = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ";
  });
  return [formatter stringFromDate:[NSDate date]];
}

static NSString *SBBoolString(BOOL value) {
  return value ? @"YES" : @"NO";
}

// Make a mono Float32 AVAudioPCMBuffer from raw PCM payload (i16 or f32).
// We accept either interleaved or non-interleaved input and mixdown to mono
// (DaVoiceTTS.playBuffer will resample / normalize as needed).
static AVAudioPCMBuffer *SB_MakeMonoF32Buffer(NSData *raw,
                                              double sampleRate,
                                              NSString *fmt,      // "i16" | "f32"
                                              NSInteger channels, // >= 1
                                              BOOL interleaved)
{
  if (!raw || raw.length == 0 || channels < 1) return nil;

  // Target: mono float32, non-interleaved
  AVAudioFormat *dstFmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:1];
  NSUInteger frameCount = 0;

  if ([fmt.lowercaseString isEqualToString:@"i16"]) {
    // Each sample is 2 bytes
    const NSUInteger bytesPerSample = 2;
    if (raw.length % (bytesPerSample * channels) != 0) return nil;
    frameCount = raw.length / (bytesPerSample * channels);

    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:dstFmt frameCapacity:(AVAudioFrameCount)frameCount];
    buf.frameLength = (AVAudioFrameCount)frameCount;

    const int16_t *in = (const int16_t *)raw.bytes;
    float *out = buf.floatChannelData[0];
    const float scale = 1.0f / 32768.0f;

    if (interleaved || channels == 1) {
      // Interleaved: [c0,c1,.., c0,c1,..]
      for (NSUInteger f = 0; f < frameCount; ++f) {
        int64_t acc = 0;
        for (NSInteger ch = 0; ch < channels; ++ch) {
          acc += in[f*channels + ch];
        }
        out[f] = (float)(acc / (double)channels) * scale;
      }
    } else {
      // Non-interleaved planar i16 (rare): [all c0][all c1]…
      const NSUInteger planeLen = frameCount;
      for (NSUInteger f = 0; f < frameCount; ++f) {
        int64_t acc = 0;
        for (NSInteger ch = 0; ch < channels; ++ch) {
          acc += in[ch*planeLen + f];
        }
        out[f] = (float)(acc / (double)channels) * scale;
      }
    }
    return buf;
  }

  // f32 path
  if (![fmt.lowercaseString isEqualToString:@"f32"]) return nil;
  const NSUInteger bytesPerSample = 4;
  if (raw.length % (bytesPerSample * channels) != 0) return nil;
  frameCount = raw.length / (bytesPerSample * channels);

  AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:dstFmt frameCapacity:(AVAudioFrameCount)frameCount];
  buf.frameLength = (AVAudioFrameCount)frameCount;

  const float *in = (const float *)raw.bytes;
  float *out = buf.floatChannelData[0];

  if (interleaved || channels == 1) {
    for (NSUInteger f = 0; f < frameCount; ++f) {
      double acc = 0.0;
      for (NSInteger ch = 0; ch < channels; ++ch) {
        acc += in[f*channels + ch];
      }
      out[f] = (float)(acc / (double)channels);
    }
  } else {
    // Planar f32: [all c0][all c1]…
    const NSUInteger planeLen = frameCount;
    for (NSUInteger f = 0; f < frameCount; ++f) {
      double acc = 0.0;
      for (NSInteger ch = 0; ch < channels; ++ch) {
        acc += in[ch*planeLen + f];
      }
      out[f] = (float)(acc / (double)channels);
    }
  }
  return buf;
}

// The STT/DaVoiceTTS core is main-queue affine: it schedules its own internal
// polling on the main queue and mutates AVAudioEngine/task state without a lock
// guarding every access, so every touch of self.stt from this bridge must also
// stay on main -- mixing threads here races that internal state. -methodQueue
// below keeps every RCT_EXPORT_METHOD call on main already; this guard exists
// so a future call site added off that path (a completion handler, a hop to a
// background queue, etc.) fails loudly instead of silently reintroducing that
// race. DEBUG asserts at the violating frame; release logs once via NSLog
// rather than RCTLogError, since RCTLogError is a no-op in a release build
// with no log function installed (RCTLog.mm gates on RCT_DEBUG || logFunction).
static void SBReportOffMainQueueSTTAccess(const char *where)
{
  NSLog(@"[SpeechBridge] self.stt accessed off the main queue in %s. STT/DaVoiceTTS "
        @"is main-queue-affine; see -methodQueue.", where);
}

// dispatch_assert_queue, not [NSThread isMainThread]: a dispatch_sync from main onto
// another serial queue runs on the main THREAD while off the main QUEUE, which
// isMainThread would incorrectly pass.
#if DEBUG
  #define SBAssertSTTOnMainQueue() dispatch_assert_queue(dispatch_get_main_queue())
#else
  #define SBAssertSTTOnMainQueue() \
    do { \
      if (![NSThread isMainThread]) { SBReportOffMainQueueSTTAccess(__PRETTY_FUNCTION__); } \
    } while (0)
#endif

@interface SpeechBridge () <STTDelegate>
@property (nonatomic, strong, nullable) STT *stt;
@property (nonatomic, strong, nullable) DaVoiceTTS *tts;
@property (nonatomic, assign) BOOL hasListeners;
@property (atomic, assign) BOOL initializing;
@property (atomic, assign) BOOL initialized;

// used only to gate TTS init until STT engine is “hot”
@property (atomic, assign) BOOL sttEngineHot;
// retained so we can re-license a fresh STT instance after destroyAll
@property (nonatomic, copy, nullable) NSString *lastLicenseKey;
@end

@implementation SpeechBridge

// Explicit accessors so the main-queue guard covers every read and write of
// self.stt. Explicit accessors disable autosynthesis, hence the @synthesize.
@synthesize stt = _stt;

- (STT *)stt
{
  SBAssertSTTOnMainQueue();
  return _stt;
}

- (void)setStt:(STT *)stt
{
  SBAssertSTTOnMainQueue();
  _stt = stt;
}

// Single teardown path for the STT instance.
//
// Every call site used to be `[self.stt destroySpeech:nil]; self.stt = nil;`, which
// cleared the ivar only after the teardown call had already started, so other
// main-queue work could observe a half-destroyed STT through self.stt in between.
// Clearing the ivar first closes that window; the strong local keeps the instance
// alive for the duration of the call.
//
// The completion is deliberately nil, matching every existing call site. Passing a
// block that captures the instance would hand its lifetime to the framework: the
// final release would then happen wherever the framework drops the block, so
// -[STT dealloc] and the AVAudioEngine teardown inside it could run off the main
// queue -- the exact affinity violation this file exists to prevent, and it would
// not trip the guard above, because dealloc does not go through the property.
- (void)tearDownSTT
{
  SBAssertSTTOnMainQueue();
  STT *dyingSTT = _stt;
  if (!dyingSTT) { return; }
  _stt = nil;
  @try {
    [dyingSTT destroySpeech:nil];
  } @catch (__unused id e) {}
}

RCT_EXPORT_MODULE(SpeechBridge)

// We emit the union of STT + TTS events
- (NSArray<NSString *> *)supportedEvents
{
  return @[
    // STT events
    @"onSpeechResults",
    @"onSpeechStart",
    @"onSpeechPartialResults",
    @"onSpeechError",
    @"onSpeechEnd",
    @"onSpeechRecognized",
    @"onSpeechVolumeChanged",
    // TTS event
    @"onFinishedSpeaking"
  ];
}

+ (BOOL)requiresMainQueueSetup { return YES; }
- (dispatch_queue_t)methodQueue { return dispatch_get_main_queue(); }
- (void)startObserving { self.hasListeners = YES; }
- (void)stopObserving  { self.hasListeners = NO;  }

- (void)dealloc
{
  // dealloc is not guaranteed to run on the main queue -- the last release can come
  // from a bridge invalidation on any thread -- and [DaVoiceTTS destroy] /
  // [STT destroySpeech:] are the same main-affine calls SBAssertSTTOnMainQueue exists
  // to keep on main. Exempting dealloc from that rule would put full audio teardown
  // off main at the one site where it is least recoverable, so hop instead. Only the
  // locals are captured, never self, so this is safe from inside dealloc; the
  // destroy order stays TTS then STT.
  DaVoiceTTS *dyingTTS = _tts;
  STT *dyingSTT = _stt;
  _tts = nil;
  _stt = nil;
  if (!dyingTTS && !dyingSTT) { return; }

  void (^teardown)(void) = ^{
    @try { [dyingTTS destroy]; } @catch (__unused id e) {}
    @try { [dyingSTT destroySpeech:nil]; } @catch (__unused id e) {}
  };
  if ([NSThread isMainThread]) {
    teardown();
  } else {
    dispatch_async(dispatch_get_main_queue(), teardown);
  }
}

#pragma mark - STTDelegate (forward all events)

- (void)stt:(STT *)stt didEmitEvent:(NSString *)name body:(NSDictionary *)body
{
  // Ignore events from an STT we have already torn down. A dying instance stays our
  // delegate until it deallocs, so without this check a trailing onSpeechStart from
  // the old instance could latch sttEngineHot while the NEW recognizer (created by a
  // fresh initAll()/initWithoutModel() racing the old instance's teardown) has not
  // actually started -- reporting init success to JS before voice input is live.
  // Compared against the ivar directly, not self.stt: this is invoked from the
  // framework's own callback thread and must not trip the main-queue guard.
  if (stt != _stt) { return; }
  // Use the first onSpeechStart as the “engine hot” latch.
  if ([name isEqualToString:@"onSpeechStart"] && !self.sttEngineHot) {
    self.sttEngineHot = YES;
  }
  if (self.hasListeners) {
    [self sendEventWithName:name body:body ?: @{}];
  }
}

#pragma mark - Helpers

- (NSURL *)resolveLocalURLFromPathOrURL:(NSString *)pathOrURL
{
  if (!pathOrURL || (id)pathOrURL == [NSNull null] || pathOrURL.length == 0) return nil;
  // ✅ Handle http(s): download to tmp and return file URL
  if ([pathOrURL hasPrefix:@"http://"] || [pathOrURL hasPrefix:@"https://"]) {
    NSURL *remoteURL = [NSURL URLWithString:pathOrURL];
    if (!remoteURL) return nil;

    NSData *data = [NSData dataWithContentsOfURL:remoteURL];
    if (!data) return nil;

    // keep extension if possible
    NSString *ext = remoteURL.pathExtension.length ? remoteURL.pathExtension : @"bin";
    NSString *tempName = [NSString stringWithFormat:@"rn_asset_%f.%@", [[NSDate date] timeIntervalSince1970], ext];
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:tempName];

    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
    if (![data writeToFile:tempPath atomically:YES]) return nil;

    return [NSURL fileURLWithPath:tempPath];
  }

  // Already a file URL
  if ([pathOrURL hasPrefix:@"file://"]) {
    return [NSURL URLWithString:pathOrURL];
  }

  // RN bundled asset path: asset:/xxx  -> copy from bundle to tmp so we get a file URL
  if ([pathOrURL hasPrefix:@"asset:/"]) {
    NSString *assetName = [pathOrURL stringByReplacingOccurrencesOfString:@"asset:/" withString:@""];
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:[assetName stringByDeletingPathExtension]
                                                           ofType:[assetName pathExtension]];
    if (!bundlePath) return nil;

    NSString *ext = [assetName pathExtension];
    if (ext.length == 0) ext = @"bin";

    NSString *tempName = [NSString stringWithFormat:@"asset_%f.%@", [[NSDate date] timeIntervalSince1970], ext];
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:tempName];

    // overwrite if exists
    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

    NSError *copyError = nil;
    [[NSFileManager defaultManager] copyItemAtPath:bundlePath toPath:tempPath error:&copyError];
    if (copyError) return nil;

    return [NSURL fileURLWithPath:tempPath];
  }

  // Otherwise: assume direct local path
  return [NSURL fileURLWithPath:pathOrURL];
}

- (void)ensureSTT
{
  if (!self.stt) {
    self.stt = [STT new];
    self.stt.delegate = self;
    if (self.lastLicenseKey) {
      [self.stt setLicenseWithLicenseKey:self.lastLicenseKey];
    }
  }
}

- (void)wireTTSFinishedCallback
{
  if (!self.tts) return;

  __weak typeof(self) weakSelf = self;
  self.tts.onLastUtteranceFinished = ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.hasListeners) return;

    // Match the old, working behavior
    dispatch_async(dispatch_get_main_queue(), ^{
      [strongSelf sendEventWithName:@"onFinishedSpeaking" body:@{}];
    });
  };
}

// Ticks on a private queue, delivers the verdict on main.
//
// The tick only reads self.sttEngineHot (atomic) and a clock -- no UIKit, no self.stt
// -- so it has no reason to occupy the main queue, while timeoutMs defaults to
// 7200000ms above, meaning an engine that never reports hot would otherwise leave a
// 50ms main-queue timer running for two hours. The completion is different: it is
// only ever invoked from initAll()/initWithoutModel(), where it writes
// self.initializing/self.initialized and resolves/rejects the caller's JS promise, so
// it is hopped back to main to keep that state single-threaded and to respect
// SBAssertSTTOnMainQueue on any self.stt access inside a caller's completion.
- (void)waitForSTTEngineHotWithTimeoutMs:(NSNumber *)timeoutMs
                              completion:(void (^)(BOOL ok))completion
{
  NSNumber *t = timeoutMs ?: @(7200000);
  if (t.doubleValue <= 0) t = @(7200000);

  CFTimeInterval deadline = CACurrentMediaTime() + MAX(0.1, t.doubleValue / 1000.0);

  static dispatch_queue_t pollQueue;
  static dispatch_once_t pollQueueOnce;
  dispatch_once(&pollQueueOnce, ^{
    pollQueue = dispatch_queue_create("com.davoice.SpeechBridge.enginehot", DISPATCH_QUEUE_SERIAL);
  });

  void (^deliver)(BOOL) = ^(BOOL ok) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(ok); });
  };

  __weak typeof(self) weakSelf = self;
  __block void (^poll)(void) = ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) {
      poll = nil;
      deliver(NO);
      return;
    }
    if (strongSelf.sttEngineHot) {
      poll = nil;
      deliver(YES);
      return;
    }
    if (CACurrentMediaTime() >= deadline) {
      poll = nil;
      deliver(NO);
      return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   pollQueue, poll);
  };

  dispatch_async(pollQueue, poll);
}

RCT_EXPORT_METHOD(hasMicPermissions:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  resolve(@(SBHasMicPermission()));
}

RCT_EXPORT_METHOD(requestMicPermissions:(nonnull NSNumber *)wait_timeout
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  dispatch_async(dispatch_get_main_queue(), ^{
    AVAudioSession *audioSession = [AVAudioSession sharedInstance];
    AVAudioSessionRecordPermission permission = audioSession.recordPermission;
    if (permission == AVAudioSessionRecordPermissionGranted) {
      resolve(@YES);
      return;
    }

    if (permission == AVAudioSessionRecordPermissionDenied) {
      resolve(@NO);
      return;
    }

    NSTimeInterval timeoutSeconds = MAX(wait_timeout.doubleValue, 0.0) / 1000.0;
    __block BOOL didResolve = NO;
    void (^finish)(BOOL) = ^(BOOL granted) {
      if (didResolve) return;
      didResolve = YES;
      resolve(@(granted));
    };

    if (timeoutSeconds > 0.0) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSeconds * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        finish(SBHasMicPermission());
      });
    }

    [audioSession requestRecordPermission:^(BOOL granted) {
      dispatch_async(dispatch_get_main_queue(), ^{
        finish(granted);
      });
    }];
  });
}

RCT_EXPORT_METHOD(hasSpeechRecognitionPermissions:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  resolve(@(SBHasSpeechRecognitionPermission()));
}

RCT_EXPORT_METHOD(requestSpeechRecognitionPermissions:(nonnull NSNumber *)wait_timeout
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  dispatch_async(dispatch_get_main_queue(), ^{
    SFSpeechRecognizerAuthorizationStatus status = [SFSpeechRecognizer authorizationStatus];
    if (status == SFSpeechRecognizerAuthorizationStatusAuthorized) {
      resolve(@YES);
      return;
    }

    if (status == SFSpeechRecognizerAuthorizationStatusDenied ||
        status == SFSpeechRecognizerAuthorizationStatusRestricted) {
      resolve(@NO);
      return;
    }

    NSTimeInterval timeoutSeconds = MAX(wait_timeout.doubleValue, 0.0) / 1000.0;
    __block BOOL didResolve = NO;
    void (^finish)(BOOL) = ^(BOOL granted) {
      if (didResolve) return;
      didResolve = YES;
      resolve(@(granted));
    };

    if (timeoutSeconds > 0.0) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSeconds * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        finish(SBHasSpeechRecognitionPermission());
      });
    }

    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus updatedStatus) {
      dispatch_async(dispatch_get_main_queue(), ^{
        finish(updatedStatus == SFSpeechRecognizerAuthorizationStatusAuthorized);
      });
    }];
  });
}

#pragma mark - Unified API

RCT_EXPORT_METHOD(setLicense:(NSString *)licenseKey
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (licenseKey == nil || (id)licenseKey == [NSNull null] || licenseKey.length == 0) {
    reject(@"invalid_args", @"Missing licenseKey", nil);
    return;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    self.lastLicenseKey = licenseKey;
    BOOL ttsOk = [DaVoiceTTS activateLicenseWithLicenseKey:licenseKey];
    // Keep licensing side-effect free. initAll()/the explicit STT APIs create
    // STT through ensureSTT(), which reapplies lastLicenseKey at that point.
    BOOL sttOk = self.stt ? [self.stt setLicenseWithLicenseKey:licenseKey] : YES;
    resolve(@(ttsOk && sttOk));
  });
}

RCT_EXPORT_METHOD(isLicenseValid:(NSString *)licenseKey
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (licenseKey == nil || (id)licenseKey == [NSNull null] || licenseKey.length == 0) {
    reject(@"invalid_args", @"Missing licenseKey", nil);
    return;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    BOOL ok = [LicenseManager isLicenseValidWithLicenseKey:licenseKey];
    resolve(@(ok));
  });
}

/// Stores the speech library's routing config before STT/TTS initialization.
/// DaVoice will prefer this config and only fall back to the wakeword library when absent.
RCT_EXPORT_METHOD(setAudioRoutingConfig:(NSString *)jsonConfig
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (jsonConfig.length == 0) {
    reject(@"AudioRoutingConfigError", @"Audio routing config JSON is empty", nil);
    return;
  }

  BOOL accepted = [DaVoiceAudioRoutingConfig setAudioRoutingConfigJSONString:jsonConfig];
  if (!accepted) {
    reject(@"AudioRoutingConfigError",
           @"Audio routing config must be valid JSON with a top-level 'default' object",
           nil);
    return;
  }

  SBDebugLog(@"[SpeechBridge] stored direct audio routing config before initialization");
  resolve(@"ok");
}

RCT_EXPORT_METHOD(clearAudioRoutingConfig:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  [DaVoiceAudioRoutingConfig clearAudioRoutingConfig];
  resolve(@"ok");
}

/// initAll({ locale: "en-US", model: "/path/model.onnx", timeoutMs?: 8000 })
#pragma mark - Speaker verification (live multi-speaker)

// JS arrays of {id, json} -> NSArray<NSDictionary<NSString*,NSString*>*> with
// string values only (json may be the JSON itself or a path to it).
static NSArray<NSDictionary<NSString *, NSString *> *> *SBSpeakerItems(id raw) {
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *out = [NSMutableArray array];
  if (![raw isKindOfClass:[NSArray class]]) return out;
  for (id item in (NSArray *)raw) {
    if (![item isKindOfClass:[NSDictionary class]]) continue;
    NSMutableDictionary<NSString *, NSString *> *d = [NSMutableDictionary dictionary];
    [(NSDictionary *)item enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
      if ([k isKindOfClass:[NSString class]] && [v isKindOfClass:[NSString class]]) d[k] = v;
    }];
    [out addObject:d];
  }
  return out;
}

static BOOL SBNonEmptyString(id v) {
  return [v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0;
}

// Starts STT from initAll-style options: `speakers` (array) replaces the set;
// otherwise `onboardingJsonPath` (+ optional `speakerId`, default "default") adds
// one speaker; otherwise the current set (if any) is kept.
- (void)startSTTWithLocale:(NSString *)locale opts:(NSDictionary *)opts
{
  NSArray *speakers = SBSpeakerItems(opts[@"speakers"]);
  id onboardingJsonPath = opts[@"onboardingJsonPath"];
  id speakerId = opts[@"speakerId"];
  if (speakers.count > 0) {
    [self.stt startSpeechWithLocaleStr:locale speakers:speakers];
  } else if (SBNonEmptyString(onboardingJsonPath)) {
    [self.stt startSpeechWithLocaleStr:locale
                    onboardingJsonPath:onboardingJsonPath
                             speakerId:(SBNonEmptyString(speakerId) ? speakerId : @"default")];
  } else {
    [self.stt startSpeechWithLocaleStr:locale];
  }
}

RCT_EXPORT_METHOD(addSpeaker:(NSString *)speakerId
                  jsonOrPath:(NSString *)jsonOrPath
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  [self ensureSTT];
  NSError *error = nil;
  if (![self.stt addSpeakerWithId:(speakerId ?: @"default") jsonOrPath:(jsonOrPath ?: @"") error:&error]) {
    reject(@"sv_add_failed", error.localizedDescription ?: @"addSpeaker failed", error);
    return;
  }
  resolve([self.stt getSpeakerIds]);
}

RCT_EXPORT_METHOD(setSpeakers:(NSArray *)speakers
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  [self ensureSTT];
  NSError *error = nil;
  if (![self.stt setSpeakers:SBSpeakerItems(speakers) error:&error]) {
    reject(@"sv_set_failed", error.localizedDescription ?: @"setSpeakers failed", error);
    return;
  }
  resolve([self.stt getSpeakerIds]);
}

RCT_EXPORT_METHOD(removeSpeaker:(NSString *)speakerId
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (!self.stt) { resolve(@(NO)); return; }
  resolve(@([self.stt removeSpeakerWithId:(speakerId ?: @"")]));
}

RCT_EXPORT_METHOD(getSpeakerIds:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  resolve(self.stt ? [self.stt getSpeakerIds] : @[]);
}

RCT_EXPORT_METHOD(startSpeechWithSVSpeakers:(NSString *)locale
                  speakers:(NSArray *)speakers
                  timeoutMs:(nonnull NSNumber *)timeoutMs
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  [self ensureSTT];
  self.sttEngineHot = NO;
  [self.stt startSpeechWithLocaleStr:locale speakers:SBSpeakerItems(speakers)];
  [self waitForSTTEngineHotWithTimeoutMs:timeoutMs completion:^(BOOL ok) {
    if (!ok) {
      reject(@"stt_start_timeout", @"STT did not become ready before timeout", nil);
      return;
    }
    resolve(@{@"ok": @(YES)});
  }];
}

RCT_EXPORT_METHOD(initAll:(NSDictionary *)opts
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.initializing) { resolve(@"already_initializing"); return; }
    if (self.initialized)  { resolve(@"already_initialized");  return; }

    self.initializing = YES;
    self.sttEngineHot = NO;

    NSString *locale = opts[@"locale"] ?: @"en-US";
    NSString *modelPath = opts[@"model"];
    NSNumber *timeoutMs = opts[@"timeoutMs"];
    if (modelPath.length == 0) {
      self.initializing = NO;
      reject(@"invalid_args", @"Missing 'model' in initAll()", nil);
      return;
    }

    // 1) STT first
    if (!self.stt) {
      self.stt = [STT new];
      self.stt.delegate = self;
      if (self.lastLicenseKey) {
        [self.stt setLicenseWithLicenseKey:self.lastLicenseKey];
      }
    }
    [self startSTTWithLocale:locale opts:opts];

    // 2) TTS next
    NSURL *modelURL = nil;

    // ✅ BACKWARD COMPAT: plain "letters.onnx" (no slashes, no scheme) -> DO EXACTLY THIS.
    // Do NOT resolve, do NOT check existence here. Native core will search.
    BOOL isBareOnnxName =
      (modelPath != nil) &&
      ([modelPath rangeOfString:@"/"].location == NSNotFound) &&
      ([modelPath rangeOfString:@"://"].location == NSNotFound) &&
      ![modelPath hasPrefix:@"file://"] &&
      [[modelPath lowercaseString] hasSuffix:@".onnx"];

    // ✅ Bare .dm name (no slashes, no scheme) — try resolution first, fall back to bare name.
    BOOL isBareDmName =
      (modelPath != nil) &&
      ([modelPath rangeOfString:@"/"].location == NSNotFound) &&
      ([modelPath rangeOfString:@"://"].location == NSNotFound) &&
      ![modelPath hasPrefix:@"file://"] &&
      [[modelPath lowercaseString] hasSuffix:@".dm"];

    if (isBareOnnxName) {
      modelURL = [NSURL fileURLWithPath:modelPath];
    } else {
      modelURL = [self resolveLocalURLFromPathOrURL:modelPath];

      // ✅ Fallback for bare .dm: if resolution failed, let native core search (same as .onnx behavior).
      if (!modelURL && isBareDmName) {
        SBDebugLog(@"[TTS] INIT: bare .dm name could not be resolved, falling back to bare path: %@", modelPath);
        modelURL = [NSURL fileURLWithPath:modelPath];
      }

      if (!modelURL) {
        self.initializing = NO;
        [self tearDownSTT];
        reject(@"bad_model", [NSString stringWithFormat:@"Could not resolve model path: %@", modelPath], nil);
        return;
      }

      // Verify file exists for local file URLs (skip for bare .dm fallback — native core will search)
      if (!isBareDmName && modelURL.isFileURL && ![[NSFileManager defaultManager] fileExistsAtPath:modelURL.path]) {
        self.initializing = NO;
        [self tearDownSTT];
        reject(@"model_missing", [NSString stringWithFormat:@"Model file missing: %@", modelURL.path], nil);
        return;
      }
    }
    SBDebugLog(@"[TTS] INIT: modelURL ==  %@", modelURL);

    if (self.tts) {
      @try { [self.tts stopSpeaking]; [self.tts destroy]; } @catch (__unused id e) {}
      self.tts = nil;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSError *err = nil;
      DaVoiceTTS *tts = [[DaVoiceTTS alloc] initWithModel:modelURL error:&err];

      dispatch_async(dispatch_get_main_queue(), ^{
        if (err || !tts) {
          self.initializing = NO;
          self.sttEngineHot = NO;
          [self tearDownSTT];
          reject(@"tts_init_failed", err.localizedDescription ?: @"TTS init failed", err);
          return;
        }

        self.tts = tts;
        [self wireTTSFinishedCallback];
        [self waitForSTTEngineHotWithTimeoutMs:timeoutMs completion:^(BOOL ok) {
          if (!ok) {
            self.initializing = NO;
            reject(@"stt_init_timeout", @"STT did not become ready before timeout", nil);
            return;
          }
          self.initialized  = YES;
          self.initializing = NO;
          resolve(@"initialized");
        }];
      });
    });
  });
}

RCT_EXPORT_METHOD(initWithoutModel:(NSDictionary *)opts
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.initializing) { resolve(@"already_initializing"); return; }
    if (!self.tts) {
      reject(@"no_tts", @"initWithoutModel() requires a successful initAll() first", nil);
      return;
    }
    if (self.initialized && self.stt) {
      resolve(@"already_initialized");
      return;
    }

    self.initializing = YES;
    self.sttEngineHot = NO;

    NSString *locale = opts[@"locale"] ?: @"en-US";
    NSNumber *timeoutMs = opts[@"timeoutMs"];

    [self tearDownSTT];

    [self ensureSTT];
    [self startSTTWithLocale:locale opts:opts];

    [self waitForSTTEngineHotWithTimeoutMs:timeoutMs completion:^(BOOL ok) {
      if (!ok) {
        self.initializing = NO;
        self.initialized = NO;
        self.sttEngineHot = NO;
        [self tearDownSTT];
        reject(@"stt_init_timeout", @"STT did not become ready before timeout", nil);
        return;
      }
      self.initialized = YES;
      self.initializing = NO;
      resolve(@"initialized_without_model");
    }];
  });
}

// --- SpeechRecognitionLite pause/unpause (counter-based) ---

RCT_EXPORT_METHOD(pauseSpeechRecognitionLite:(RCTResponseSenderBlock)callback)
{
  // No-op if STT isn't initialized yet (avoid JS error spam).
  if (!self.stt) { if (callback) callback(@[@(YES)]); return; }
  [self.stt pauseSpeechRecognitionLite];
  if (callback) callback(@[@(YES)]);
}

RCT_EXPORT_METHOD(pauseSpeechRecognitionLiteAsync:(nonnull NSNumber *)timeoutMs
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (!self.stt) { resolve(@{@"ok": @(YES), @"reason": @""}); return; }

  NSNumber *t = timeoutMs ?: @(500);
  if (t.doubleValue <= 0) t = @(500);
  CFTimeInterval startedAt = CACurrentMediaTime();
  SBDebugLog(@"[SpeechBridge] %@ pauseSpeechRecognitionLiteAsync begin timeoutMs=%@ stt=%@", SBNowString(), t, self.stt);

  if ([(id)self.stt respondsToSelector:@selector(pauseSpeechRecognitionLiteAndWait:completion:)]) {
    [(id)self.stt pauseSpeechRecognitionLiteAndWait:t completion:^(BOOL ok, NSString * _Nullable reason) {
      SBDebugLog(@"[SpeechBridge] %@ pauseSpeechRecognitionLiteAsync resolved elapsedMs=%.1f ok=%@ reason=%@",
                 SBNowString(),
                 (CACurrentMediaTime() - startedAt) * 1000.0,
                 SBBoolString(ok),
                 reason ?: @"");
      resolve(@{@"ok": @(ok), @"reason": reason ?: @""});
    }];
    return;
  }

  SBDebugLog(@"[SpeechBridge] %@ pauseSpeechRecognitionLiteAsync fallback no-wait", SBNowString());
  [self.stt pauseSpeechRecognitionLite];
  resolve(@{@"ok": @(YES), @"reason": @"bridge_fallback_no_wait_method"});
}

RCT_EXPORT_METHOD(unPauseSpeechRecognitionLite:(nonnull NSNumber *)times
                  callback:(RCTResponseSenderBlock)callback)
{
  // No-op if STT isn't initialized yet (avoid JS error spam).
  if (!self.stt) { if (callback) callback(@[@(YES)]); return; }
  [self.stt unPauseSpeechRecognitionLite:times];
  if (callback) callback(@[@(YES)]);
}

RCT_EXPORT_METHOD(unPauseSpeechRecognitionLiteWithPreFetch:(nonnull NSNumber *)times
                  preFetchMs:(nonnull NSNumber *)preFetch
                  callback:(RCTResponseSenderBlock)callback)
{
  // No-op if STT isn't initialized yet (avoid JS error spam).
  if (!self.stt) { if (callback) callback(@[@(YES)]); return; }
  [self.stt unPauseSpeechRecognitionLite:times preFetch:preFetch];
  if (callback) callback(@[@(YES)]);
}

RCT_EXPORT_METHOD(unPauseSpeechRecognitionLiteAsync:(nonnull NSNumber *)times
                  preFetchMs:(nonnull NSNumber *)preFetch
                  timeoutMs:(nonnull NSNumber *)timeoutMs
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (!self.stt) { resolve(@{@"ok": @(YES), @"reason": @""}); return; }

  NSNumber *t = timeoutMs ?: @(500);
  if (t.doubleValue <= 0) t = @(500);
  NSNumber *pf = preFetch ?: @(0);
  if (pf.doubleValue < 0) pf = @(0);
  CFTimeInterval startedAt = CACurrentMediaTime();
  SBDebugLog(@"[SpeechBridge] %@ unPauseSpeechRecognitionLiteAsync begin times=%@ preFetchMs=%@ timeoutMs=%@ stt=%@ initialized=%@ initializing=%@",
             SBNowString(),
             times,
             pf,
             t,
             self.stt,
             SBBoolString(self.initialized),
             SBBoolString(self.initializing));

  if ([(id)self.stt respondsToSelector:@selector(unPauseSpeechRecognitionLiteAndWait:preFetch:timeoutMs:completion:)]) {
    [(id)self.stt unPauseSpeechRecognitionLiteAndWait:times
                                             preFetch:pf
                                            timeoutMs:t
                                           completion:^(BOOL ok, NSString * _Nullable reason) {
      SBDebugLog(@"[SpeechBridge] %@ unPauseSpeechRecognitionLiteAsync resolved elapsedMs=%.1f ok=%@ reason=%@",
                 SBNowString(),
                 (CACurrentMediaTime() - startedAt) * 1000.0,
                 SBBoolString(ok),
                 reason ?: @"");
      resolve(@{@"ok": @(ok), @"reason": reason ?: @""});
    }];
    return;
  }

  SBDebugLog(@"[SpeechBridge] %@ unPauseSpeechRecognitionLiteAsync fallback no-wait", SBNowString());
  [self.stt unPauseSpeechRecognitionLite:times preFetch:pf];
  resolve(@{@"ok": @(YES), @"reason": @"bridge_fallback_no_wait_method"});
}

// Promise-based pause that resolves ONLY when iOS is actually settled in playback (mic released)
RCT_EXPORT_METHOD(pauseMicrophoneAsync:(nonnull NSNumber *)timeoutMs
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (!self.stt) { resolve(@{@"ok": @(NO), @"reason": @"no_stt"}); return; }

  // Default if caller passes null/0
  NSNumber *t = timeoutMs ?: @(500);
  if (t.doubleValue <= 0) t = @(500);

  // STT.swift will do the main-queue polling internally
  [self.stt pauseMicrophoneAndWait:t completion:^(BOOL ok, NSString * _Nullable reason) {
    resolve(@{@"ok": @(ok), @"reason": reason ?: @""});
  }];
}

// Promise-based unpause that resolves ONLY when engine+task are live again
RCT_EXPORT_METHOD(unPauseMicrophoneAsync:(nonnull NSNumber *)timeoutMs
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (!self.stt) { resolve(@{@"ok": @(NO), @"reason": @"no_stt"}); return; }

  NSNumber *t = timeoutMs ?: @(500);
  if (t.doubleValue <= 0) t = @(500);

  [self.stt unPauseMicrophoneAndWait:t completion:^(BOOL ok, NSString * _Nullable reason) {
    resolve(@{@"ok": @(ok), @"reason": reason ?: @""});
  }];
}

// ADD — pause mic
RCT_EXPORT_METHOD(pauseMicrophone:(RCTResponseSenderBlock)callback)
{
  if (!self.stt) { if (callback) callback(@[@(NO)]); return; }
  [self.stt pauseMicrophone];   // ← no colon
  if (callback) callback(@[@(YES)]);
}


// ADD — unpause mic
RCT_EXPORT_METHOD(unPauseMicrophone:(RCTResponseSenderBlock)callback)
{
  if (!self.stt) { if (callback) callback(@[@(NO)]); return; }
  [self.stt unPauseMicrophone]; // ← no colon
  if (callback) callback(@[@(YES)]);
}


RCT_EXPORT_METHOD(destroyAll:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self.tts && !self.stt && !self.initialized && !self.initializing) {
      resolve(@"already_destroyed");
      return;
    }
    // prevent re-entry during destroy
    self.initializing = YES;

    // Destroy in reverse order: TTS -> STT
    @try { [self.tts stopSpeaking]; [self.tts destroy]; } @catch (__unused id e) {}
    self.tts = nil;

    [self tearDownSTT];

    self.sttEngineHot = NO;
    self.initialized  = NO;
    self.initializing = NO;
    resolve(@"destroyed");
  });
}

RCT_EXPORT_METHOD(destroyWihtouModel:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!self.tts) {
      reject(@"no_tts", @"destroyWihtouModel() requires a successful initAll() first", nil);
      return;
    }

    if (!self.stt && !self.initialized && !self.initializing) {
      resolve(@"already_destroyed_without_model");
      return;
    }

    self.initializing = YES;

    [self tearDownSTT];

    self.sttEngineHot = NO;
    self.initialized = NO;
    self.initializing = NO;
    resolve(@"destroyed_without_model");
  });
}

RCT_EXPORT_METHOD(destroyWithoutModel:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  [self destroyWihtouModel:resolve rejecter:reject];
}

#pragma mark - Convenience passthroughs (optional)

RCT_EXPORT_METHOD(startSpeech:(NSString *)locale
                  callback:(RCTResponseSenderBlock)callback)
{
  [self ensureSTT];
  self.sttEngineHot = NO;
  [self.stt startSpeechWithLocaleStr:locale];
  if (callback) callback(@[@(NO)]);
}

RCT_EXPORT_METHOD(startSpeechAsync:(NSString *)locale
                  timeoutMs:(nonnull NSNumber *)timeoutMs
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  [self ensureSTT];
  self.sttEngineHot = NO;
  [self.stt startSpeechWithLocaleStr:locale];
  [self waitForSTTEngineHotWithTimeoutMs:timeoutMs completion:^(BOOL ok) {
    if (!ok) {
      reject(@"stt_start_timeout", @"STT did not become ready before timeout", nil);
      return;
    }
    resolve(@{@"ok": @(YES)});
  }];
}

RCT_EXPORT_METHOD(startSpeechWithSVOnboardingJson:(NSString *)locale
                  onboardingJsonPath:(NSString *)onboardingJsonPath
                  callback:(RCTResponseSenderBlock)callback)
{
  [self ensureSTT];
  self.sttEngineHot = NO;
  if (onboardingJsonPath && (id)onboardingJsonPath != [NSNull null] && onboardingJsonPath.length > 0) {
    [self.stt startSpeechWithLocaleStr:locale onboardingJsonPath:onboardingJsonPath];
  } else {
    [self.stt startSpeechWithLocaleStr:locale];
  }
  if (callback) callback(@[@(NO)]);
}

RCT_EXPORT_METHOD(startSpeechWithSVOnboardingJsonAsync:(NSString *)locale
                  onboardingJsonPath:(NSString *)onboardingJsonPath
                  timeoutMs:(nonnull NSNumber *)timeoutMs
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  [self ensureSTT];
  self.sttEngineHot = NO;
  if (onboardingJsonPath && (id)onboardingJsonPath != [NSNull null] && onboardingJsonPath.length > 0) {
    [self.stt startSpeechWithLocaleStr:locale onboardingJsonPath:onboardingJsonPath];
  } else {
    [self.stt startSpeechWithLocaleStr:locale];
  }
  [self waitForSTTEngineHotWithTimeoutMs:timeoutMs completion:^(BOOL ok) {
    if (!ok) {
      reject(@"stt_start_timeout", @"STT did not become ready before timeout", nil);
      return;
    }
    resolve(@{@"ok": @(YES)});
  }];
}

RCT_EXPORT_METHOD(stopSpeech:(RCTResponseSenderBlock)callback)
{
  if (!self.stt) { if (callback) callback(@[@(NO)]); return; }
  [self.stt stopSpeech:^(BOOL ok) { if (callback) callback(@[@(NO)]); }];
}

RCT_EXPORT_METHOD(cancelSpeech:(RCTResponseSenderBlock)callback)
{
  if (!self.stt) { if (callback) callback(@[@(NO)]); return; }
  [self.stt cancelSpeech:^(BOOL ok) { if (callback) callback(@[@(NO)]); }];
}

// Which recognition languages work on-device (same keys as Android).
RCT_EXPORT_METHOD(getOnDeviceLanguages:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  resolve([STT getOnDeviceLanguages]);
}

RCT_EXPORT_METHOD(isSpeechAvailable:(RCTResponseSenderBlock)callback)
{
  [self ensureSTT];
  [self.stt isSpeechAvailable:^(BOOL ok){
    if (callback) callback(@[@(ok ? 1 : 0), [NSNull null]]);
  }];
}

RCT_EXPORT_METHOD(isRecognizing:(RCTResponseSenderBlock)callback)
{
  BOOL running = self.stt ? [self.stt isRecognizing] : NO;
  if (callback) callback(@[@(running ? 1 : 0)]);
}

// Read-only diagnostics: captures AVAudioSession + STT/event-delivery state without
// mutating anything, so it can be polled at any point in the lifecycle to compare a
// healthy session against a stuck one.
RCT_EXPORT_METHOD(sttHealthSnapshot:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  AVAudioSession *s = [AVAudioSession sharedInstance];
  NSMutableArray *inputs = [NSMutableArray array];
  for (AVAudioSessionPortDescription *p in s.currentRoute.inputs) { [inputs addObject:p.portType]; }
  NSMutableArray *outputs = [NSMutableArray array];
  for (AVAudioSessionPortDescription *p in s.currentRoute.outputs) { [outputs addObject:p.portType]; }
  resolve(@{
    // didEmitEvent: drops every STT callback when hasListeners is NO, and latches
    // sttEngineHot before that gate -- so the engine can report itself hot while JS
    // receives nothing. bridgePtr identifies which SpeechBridge instance is emitting,
    // to catch the case where JS subscribed to a different instance than the one
    // holding self.stt.
    @"hasListeners": @(self.hasListeners),
    @"sttEngineHot": @(self.sttEngineHot),
    @"bridgePtr": [NSString stringWithFormat:@"%p", self],
    @"hasStt": @(self.stt != nil),
    @"recognizing": @(self.stt ? [self.stt isRecognizing] : NO),
    @"initialized": @(self.initialized),
    @"initializing": @(self.initializing),
    @"category": s.category ?: @"",
    @"mode": s.mode ?: @"",
    @"categoryOptions": @(s.categoryOptions),
    @"inputAvailable": @(s.inputAvailable),
    @"sampleRate": @(s.sampleRate),
    @"inputChannels": @(s.inputNumberOfChannels),
    @"inputLatency": @(s.inputLatency),
    @"otherAudioPlaying": @(s.isOtherAudioPlaying),
    @"routeInputs": inputs,
    @"routeOutputs": outputs,
  });
}

RCT_EXPORT_METHOD(setAECEnabled:(BOOL)enabled
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  [self ensureSTT];
  if (!self.stt) {
    reject(@"no_stt", @"Call initAll first", nil);
    return;
  }

  [self.stt setAECEnabled:enabled];
  resolve(@(YES));
}

RCT_EXPORT_METHOD(getAllVoices:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  resolve(self.tts ? ([self.tts getAllVoices] ?: @[]) : @[]);
}

RCT_EXPORT_METHOD(getVoiceAbilities:(NSString *)name
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  resolve(self.tts && name ? ([self.tts getVoiceAbilities:name] ?: @[]) : @[]);
}

RCT_EXPORT_METHOD(setExternalVoicesPath:(NSString *)path
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  DaVoiceTTS *tts = self.tts;
  if (!tts) { resolve(@[]); return; }
  NSString *folder = (path && (id)path != [NSNull null] && path.length) ? path : nil;
  if ([folder hasPrefix:@"file://"]) folder = [NSURL URLWithString:folder].path;
  [tts setExternalVoicesPath:folder completion:^(NSArray<NSString *> *names) { resolve(names ?: @[]); }];
}

// Reference audio (wav/mp3/m4a/...) -> packed .emd at outputPath, using the
// voice encoder embedder_<code>.dm. Runs off the bridge queue (takes seconds).
RCT_EXPORT_METHOD(createVoiceClone:(NSString *)inputAudio
                  outputPath:(NSString *)outputPath
                  embedder:(NSString *)embedder
                  volume:(double)volume
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (!inputAudio || !outputPath || !embedder || (id)outputPath == [NSNull null]) {
    reject(@"invalid_args", @"createVoiceClone(inputAudio, outputPath, embedder, volume)", nil);
    return;
  }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    BOOL remoteInput = [inputAudio hasPrefix:@"http://"] || [inputAudio hasPrefix:@"https://"];
    BOOL remoteEmbedder = [embedder hasPrefix:@"http://"] || [embedder hasPrefix:@"https://"];
    NSURL *inputURL = [self resolveLocalURLFromPathOrURL:inputAudio];
    NSURL *embedderURL = [self resolveLocalURLFromPathOrURL:embedder];
    NSString *output = [outputPath hasPrefix:@"file://"] ? [NSURL URLWithString:outputPath].path : outputPath;
    NSError *error = nil;
    NSDictionary *result = (inputURL && embedderURL)
      ? [DaVoiceTTS createVoiceClone:inputURL.path outputPath:output embedderPath:embedderURL.path volume:volume error:&error]
      : nil;
    if (remoteInput && inputURL) [[NSFileManager defaultManager] removeItemAtURL:inputURL error:nil];
    if (remoteEmbedder && embedderURL) [[NSFileManager defaultManager] removeItemAtURL:embedderURL error:nil];
    if (result) resolve(result);
    else reject(@"voice_clone_failed", error.localizedDescription ?: @"Could not resolve the input audio or embedder path", error);
  });
}

RCT_EXPORT_METHOD(changeVoice:(NSString *)name
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (!self.tts || !name) { resolve(@(-1)); return; }
  [self.tts changeVoice:name completion:^(NSInteger result) { resolve(@(result)); }];
}

RCT_EXPORT_METHOD(speak:(NSString *)text
                  speakerId:(nonnull NSNumber *)speakerId
                  speed:(nonnull NSNumber *)speed
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (!self.tts) { reject(@"no_tts", @"Call initAll first", nil); return; }

  float s = speed ? speed.floatValue : 1.0f;
  if (!isfinite(s) || s <= 0.0f) s = 1.0f;

  // NOTE: core native not changed yet; we'll actually apply speed in the Swift core next.
  // Always forward 3 args (text, sid, speed)
  [self.tts speak:text sid:speakerId.intValue speed:s];
  resolve(@"Speaking");
}

RCT_EXPORT_METHOD(stopSpeaking:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (!self.tts) { reject(@"no_tts", @"Call initAll first", nil); return; }
  [self.tts stopSpeaking];
  resolve(@"Stopped");
}

/// playWav(pathOrURL: string, markAsLast?: boolean)
RCT_EXPORT_METHOD(playWav:(NSString *)pathOrURL
                  markAsLast:(nonnull NSNumber *)markAsLast
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (!self.tts) {
    reject(@"no_tts", @"Call initAll first", nil);
    return;
  }

  if (pathOrURL == nil || pathOrURL.length == 0) {
    reject(@"bad_path", @"Empty pathOrURL", nil);
    return;
  }

  // Steps 5 and 6 below (verify + queue on the TTS engine), shared by every branch,
  // including the http(s) one after its asynchronous download completes.
  __weak typeof(self) weakSelf = self;
  void (^playLocalFile)(NSURL *) = ^(NSURL *fileURL) {
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.tts) {
      reject(@"no_tts", @"TTS went away before playback", nil);
      return;
    }
    if (!fileURL || ![[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]) {
      reject(@"file_missing", [NSString stringWithFormat:@"File missing: %@", fileURL.path], nil);
      return;
    }
    SBDebugLog(@"[TTS] Playing file via DaVoiceTTS: %@", fileURL.path);
    [strongSelf.tts playWav:fileURL markAsLastUtterance:markAsLast.boolValue];
    resolve(@"queued");
  };

  // 1️⃣ Handle http(s) URLs — download to a cached temporary file first.
  //
  // This used to be a synchronous [NSData dataWithContentsOfURL:] on this module's
  // method queue, which is the main queue (see -methodQueue). In a debug build every
  // require()'d asset (e.g. a wake-word ping sound) resolves to a Metro dev-server
  // URL, so each ping blocked the UI for the whole request; on a slow or dropped link
  // to the Metro host that meant a frozen app for as long as pings kept arriving.
  // Download off the main queue with a bounded timeout, cache by URL so each asset is
  // fetched once, then hop back to the method queue to play it.
  if ([pathOrURL hasPrefix:@"http://"] || [pathOrURL hasPrefix:@"https://"]) {
    NSURL *remoteURL = [NSURL URLWithString:pathOrURL];
    if (!remoteURL) {
      reject(@"bad_url", @"Invalid remote URL", nil);
      return;
    }

    NSString *cachedPath = SBCachedFilePathForRemoteAsset(pathOrURL);
    if ([[NSFileManager defaultManager] fileExistsAtPath:cachedPath]) {
      playLocalFile([NSURL fileURLWithPath:cachedPath]);
      return;
    }

    SBDebugLog(@"[TTS] Downloading asset from URL: %@", pathOrURL);
    dispatch_queue_t methodQueue = [self methodQueue];
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 8.0;
    config.timeoutIntervalForResource = 15.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLSessionDataTask *task = [session dataTaskWithURL:remoteURL
                                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      [session finishTasksAndInvalidate];
      NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
          ? ((NSHTTPURLResponse *)response).statusCode : 200;
      BOOL downloaded = (error == nil && data.length > 0 && status < 400);
      BOOL written = downloaded && [data writeToFile:cachedPath atomically:YES];
      dispatch_async(methodQueue, ^{
        if (!downloaded) {
          NSString *why = error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)status];
          reject(@"download_failed",
                 [NSString stringWithFormat:@"Failed to download remote asset (%@)", why],
                 error);
          return;
        }
        if (!written) {
          reject(@"write_failed", @"Failed to write temporary file", nil);
          return;
        }
        SBDebugLog(@"[TTS] Downloaded to cached file: %@", cachedPath);
        playLocalFile([NSURL fileURLWithPath:cachedPath]);
      });
    }];
    [task resume];
    return;
  }

  NSURL *fileURL = nil;

  // 2️⃣ Handle bundled asset:/ paths (copied from main bundle)
  if ([pathOrURL hasPrefix:@"asset:/"]) {
    NSString *assetName = [pathOrURL stringByReplacingOccurrencesOfString:@"asset:/" withString:@""];
    SBDebugLog(@"[TTS] Detected bundled asset: %@", assetName);
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:[assetName stringByDeletingPathExtension]
                                                           ofType:[assetName pathExtension]];
    if (!bundlePath) {
      reject(@"asset_missing", [NSString stringWithFormat:@"Asset not found in bundle: %@", assetName], nil);
      return;
    }
    // Copy to temp file so we have a writable/accessible URL
    NSString *tempName = [NSString stringWithFormat:@"asset_%f.wav", [[NSDate date] timeIntervalSince1970]];
    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:tempName];
    NSError *copyError = nil;
    [[NSFileManager defaultManager] copyItemAtPath:bundlePath toPath:tempPath error:&copyError];
    if (copyError) {
      reject(@"asset_copy_failed", copyError.localizedDescription, copyError);
      return;
    }
    fileURL = [NSURL fileURLWithPath:tempPath];
    SBDebugLog(@"[TTS] Copied bundled asset to temp: %@", tempPath);
  }

  // 3️⃣ Handle file:// URLs
  else if ([pathOrURL hasPrefix:@"file://"]) {
    fileURL = [NSURL URLWithString:pathOrURL];
  }

  // 4️⃣ Otherwise assume direct local path
  else {
    fileURL = [NSURL fileURLWithPath:pathOrURL];
  }

  // 5️⃣ + 6️⃣ Verify existence and play through the TTS engine (queued)
  playLocalFile(fileURL);
}

/// playBuffer(desc: { base64, sampleRate, channels?, interleaved?, format: "i16" | "f32", markAsLast? })
RCT_EXPORT_METHOD(playBuffer:(NSDictionary *)desc
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (!self.tts) { reject(@"no_tts", @"Call initAll first", nil); return; }

  // Validate inputs
  NSString *b64 = [RCTConvert NSString:desc[@"base64"]];
  NSNumber *srN = [RCTConvert NSNumber:desc[@"sampleRate"]];
  NSString *fmt = [RCTConvert NSString:desc[@"format"]];
  NSNumber *chN = desc[@"channels"] ? [RCTConvert NSNumber:desc[@"channels"]] : @(1);
  NSNumber *ilN = desc[@"interleaved"] ? [RCTConvert NSNumber:desc[@"interleaved"]] : @(YES);
  NSNumber *markLastN = desc[@"markAsLast"] ? [RCTConvert NSNumber:desc[@"markAsLast"]] : @(YES);

  if (!b64 || !srN || !fmt) {
    reject(@"invalid_args", @"Missing one of base64/sampleRate/format", nil);
    return;
  }

  NSData *raw = SB_Base64Decode(b64);
  if (!raw) { reject(@"bad_base64", @"Could not decode base64 payload", nil); return; }

  AVAudioPCMBuffer *buf = SB_MakeMonoF32Buffer(raw, srN.doubleValue, fmt, chN.integerValue, ilN.boolValue);
  if (!buf) { reject(@"bad_buffer", @"Unsupported PCM layout or empty data", nil); return; }

  // Hand over to DaVoiceTTS (it will resample/normalize and enqueue via AEC graph)
  [self.tts playBuffer:buf markAsLastUtterance:markLastN.boolValue];
  resolve(@"queued");
}

@end
