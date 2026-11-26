// Copied from react-native-davoice (TTSNPM ios/TTSRNBridge/DaVoiceTTSBridge.m); only the React imports changed (DVRNShim.h).
// DaVoiceTTSBridge.m
#import "DaVoiceTTSBridge.h"
#import "DVRNShim.h"
#import <AVFAudio/AVFAudio.h>

static const BOOL DTTSBridgeDebugLogsEnabled = NO;

static void DTTSBridgeDebugLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void DTTSBridgeDebugLog(NSString *format, ...)
{
  if (!DTTSBridgeDebugLogsEnabled) return;
  va_list args;
  va_start(args, format);
  NSLogv(format, args);
  va_end(args);
}

static NSData *DTTSBase64Decode(NSString *base64) {
  if (!base64 || (id)base64 == [NSNull null]) return nil;
  return [[NSData alloc] initWithBase64EncodedString:base64 options:0];
}

static AVAudioPCMBuffer *DTTSMakeMonoF32Buffer(NSData *raw,
                                               double sampleRate,
                                               NSString *format,
                                               NSInteger channels,
                                               BOOL interleaved)
{
  if (!raw || raw.length == 0 || sampleRate <= 0 || channels < 1) return nil;

  AVAudioFormat *outputFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate
                                                                               channels:1];
  NSString *normalizedFormat = format.lowercaseString;
  NSUInteger bytesPerSample = [normalizedFormat isEqualToString:@"i16"] ? 2 :
                              ([normalizedFormat isEqualToString:@"f32"] ? 4 : 0);
  if (bytesPerSample == 0 || raw.length % (bytesPerSample * channels) != 0) return nil;

  NSUInteger frameCount = raw.length / (bytesPerSample * channels);
  AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat
                                                           frameCapacity:(AVAudioFrameCount)frameCount];
  buffer.frameLength = (AVAudioFrameCount)frameCount;
  float *output = buffer.floatChannelData[0];

  if ([normalizedFormat isEqualToString:@"i16"]) {
    const int16_t *input = (const int16_t *)raw.bytes;
    for (NSUInteger frame = 0; frame < frameCount; ++frame) {
      int64_t sum = 0;
      for (NSInteger channel = 0; channel < channels; ++channel) {
        NSUInteger index = interleaved || channels == 1
          ? frame * channels + channel
          : channel * frameCount + frame;
        sum += input[index];
      }
      output[frame] = (float)(sum / (double)channels) / 32768.0f;
    }
  } else {
    const float *input = (const float *)raw.bytes;
    for (NSUInteger frame = 0; frame < frameCount; ++frame) {
      double sum = 0;
      for (NSInteger channel = 0; channel < channels; ++channel) {
        NSUInteger index = interleaved || channels == 1
          ? frame * channels + channel
          : channel * frameCount + frame;
        sum += input[index];
      }
      output[frame] = (float)(sum / channels);
    }
  }

  return buffer;
}

@interface DaVoiceTTSBridge()
@property (nonatomic, strong, nullable) DaVoiceTTS *ttsInstance;
@property (nonatomic, assign) BOOL hasListeners;
@end

@implementation DaVoiceTTSBridge

RCT_EXPORT_MODULE();

+ (BOOL)requiresMainQueueSetup {
  DTTSBridgeDebugLog(@"[DaVoiceTTSBridge] requiresMainQueueSetup called (module loaded).");

  return YES;
}

#pragma mark - RCTEventEmitter

- (NSArray<NSString *> *)supportedEvents
{
  // Single event exposed to JS.
  return @[@"onFinishedSpeaking"];
}

- (void)startObserving
{
  self.hasListeners = YES;
}

- (void)stopObserving
{
  self.hasListeners = NO;
}

- (void)dealloc
{
  if (_ttsInstance) {
    [_ttsInstance destroy];
    _ttsInstance = nil;
  }
}

#pragma mark - API

- (instancetype)init {
  self = [super init];
  if (self) {
    DTTSBridgeDebugLog(@"[DaVoiceTTSBridge] init called.");
  }
  return self;
}

- (NSURL *)resolveLocalURLFromPathOrURL:(NSString *)pathOrURL
{
  if (!pathOrURL || (id)pathOrURL == [NSNull null] || pathOrURL.length == 0) return nil;

  if ([pathOrURL hasPrefix:@"http://"] || [pathOrURL hasPrefix:@"https://"]) {
    NSURL *remoteURL = [NSURL URLWithString:pathOrURL];
    NSData *data = remoteURL ? [NSData dataWithContentsOfURL:remoteURL] : nil;
    if (!data) return nil;
    NSString *extension = remoteURL.pathExtension.length ? remoteURL.pathExtension : @"bin";
    NSString *name = [NSString stringWithFormat:@"rn_asset_%f.%@",
                      [[NSDate date] timeIntervalSince1970], extension];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    return [data writeToFile:path atomically:YES] ? [NSURL fileURLWithPath:path] : nil;
  }

  if ([pathOrURL hasPrefix:@"file://"]) return [NSURL URLWithString:pathOrURL];

  if ([pathOrURL hasPrefix:@"asset:/"]) {
    NSString *assetName = [pathOrURL substringFromIndex:@"asset:/".length];
    NSString *bundlePath = [[NSBundle mainBundle] pathForResource:assetName.stringByDeletingPathExtension
                                                           ofType:assetName.pathExtension];
    return bundlePath ? [NSURL fileURLWithPath:bundlePath] : nil;
  }

  return [NSURL fileURLWithPath:pathOrURL];
}

// Model initialization must not perform remote I/O on the React Native bridge
// queue. Local paths are resolved asynchronously as well, so initTTS has one
// consistent completion path and never blocks the bridge while resolving a model.
- (void)resolveModelURLFromPathOrURL:(NSString *)pathOrURL
                          completion:(void (^)(NSURL * _Nullable modelURL))completion
{
  if (!pathOrURL || (id)pathOrURL == [NSNull null] || pathOrURL.length == 0) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
    return;
  }

  NSURL *candidate = [NSURL URLWithString:pathOrURL];
  BOOL isRemote = [pathOrURL hasPrefix:@"http://"] || [pathOrURL hasPrefix:@"https://"];
  if (!isRemote) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      NSURL *url = [self resolveLocalURLFromPathOrURL:pathOrURL];
      dispatch_async(dispatch_get_main_queue(), ^{ completion(url); });
    });
    return;
  }

  if (!candidate) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
    return;
  }

  NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
  configuration.timeoutIntervalForRequest = 8.0;
  configuration.timeoutIntervalForResource = 15.0;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
  NSURLSessionDataTask *task = [session dataTaskWithURL:candidate
                                      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]]
      ? ((NSHTTPURLResponse *)response).statusCode : 200;
    NSURL *result = nil;
    if (!error && data.length > 0 && status < 400) {
      NSString *extension = candidate.pathExtension.length ? candidate.pathExtension : @"bin";
      NSString *name = [NSString stringWithFormat:@"rn_model_%f.%@",
                        [[NSDate date] timeIntervalSince1970], extension];
      NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
      if ([data writeToFile:path atomically:YES]) result = [NSURL fileURLWithPath:path];
    }
    [session finishTasksAndInvalidate];
    dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
  }];
  [task resume];
}

RCT_EXPORT_METHOD(setLicense:(NSString *)licenseKey
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (licenseKey == nil || (id)licenseKey == [NSNull null] || licenseKey.length == 0) {
    reject(@"invalid_args", @"Missing licenseKey", nil);
    return;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    BOOL ok = [DaVoiceTTS activateLicenseWithLicenseKey:licenseKey];
    resolve(@(ok));
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

RCT_EXPORT_METHOD(initTTS:(NSDictionary *)configDict
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  DTTSBridgeDebugLog(@"[DaVoiceTTSBridge] initTTS called with configDict: %@", configDict);
  NSString *modelPath = configDict[@"model"];

  if (!modelPath) {
    reject(@"invalid_config", @"Missing required 'model' key", nil);
    return;
  }

  [self resolveModelURLFromPathOrURL:modelPath completion:^(NSURL *modelURL) {
    if (!modelURL) {
      reject(@"bad_model", [NSString stringWithFormat:@"Could not resolve model path: %@", modelPath], nil);
      return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSError *error = nil;
      DaVoiceTTS *tts = [[DaVoiceTTS alloc] initWithModel:modelURL error:&error];
      if (error || !tts) {
        dispatch_async(dispatch_get_main_queue(), ^{
          reject(@"init_failed", error.localizedDescription ?: @"Failed to initialize", error);
        });
        return;
      }

      dispatch_async(dispatch_get_main_queue(), ^{
        if (self.ttsInstance) {
          @try { [self.ttsInstance stopSpeaking]; [self.ttsInstance destroy]; } @catch (__unused id e) {}
        }
        self.ttsInstance = tts;

        __weak typeof(self) weakSelf = self;
        self.ttsInstance.onLastUtteranceFinished = ^{
          __strong typeof(weakSelf) strongSelf = weakSelf;
          if (!strongSelf || !strongSelf.hasListeners) return;
          dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf sendEventWithName:@"onFinishedSpeaking" body:@{}];
          });
        };

        resolve(@"TTS initialized");
      });
    });
  }];
}

RCT_EXPORT_METHOD(getAllVoices:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  resolve(self.ttsInstance ? ([self.ttsInstance getAllVoices] ?: @[]) : @[]);
}

RCT_EXPORT_METHOD(getVoiceAbilities:(NSString *)name
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  resolve(self.ttsInstance && name ? ([self.ttsInstance getVoiceAbilities:name] ?: @[]) : @[]);
}

RCT_EXPORT_METHOD(setExternalVoicesPath:(NSString *)path
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  DaVoiceTTS *tts = self.ttsInstance;
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
  if (!self.ttsInstance || !name) { resolve(@(-1)); return; }
  [self.ttsInstance changeVoice:name completion:^(NSInteger result) { resolve(@(result)); }];
}

RCT_EXPORT_METHOD(speak:(NSString *)text
                    speakerId:(nonnull NSNumber *)speakerId
                    resolver:(RCTPromiseResolveBlock)resolve
                    rejecter:(RCTPromiseRejectBlock)reject)
  {
    if (!self.ttsInstance) {
      reject(@"no_instance", @"TTS not initialized", nil);
      return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      [self.ttsInstance speak:text sid:speakerId.intValue];
      resolve(@"Speaking");
    });
  }

  RCT_EXPORT_METHOD(speakWithSpeed:(NSString *)text
                    speakerId:(nonnull NSNumber *)speakerId
                    speed:(nonnull NSNumber *)speed
                    resolver:(RCTPromiseResolveBlock)resolve
                    rejecter:(RCTPromiseRejectBlock)reject)
  {
    if (!self.ttsInstance) {
      reject(@"no_instance", @"TTS not initialized", nil);
      return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      float s = speed ? speed.floatValue : 1.0f;
      [self.ttsInstance speak:text sid:speakerId.intValue speed:s];
      resolve(@"Speaking");
    });
  }

  RCT_EXPORT_METHOD(stopSpeaking:(RCTPromiseResolveBlock)resolve
                    rejecter:(RCTPromiseRejectBlock)reject)
  {
    if (!self.ttsInstance) {
      reject(@"no_instance", @"TTS not initialized", nil);
      return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      [self.ttsInstance stopSpeaking];
      resolve(@"Stopped");
    });
  }

  RCT_EXPORT_METHOD(playWav:(NSString *)pathOrURL
                    markAsLast:(nonnull NSNumber *)markAsLast
                    resolver:(RCTPromiseResolveBlock)resolve
                    rejecter:(RCTPromiseRejectBlock)reject)
  {
    if (!self.ttsInstance) {
      reject(@"no_instance", @"TTS not initialized", nil);
      return;
    }

    NSURL *fileURL = [self resolveLocalURLFromPathOrURL:pathOrURL];
    if (!fileURL || ![[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]) {
      reject(@"file_missing", [NSString stringWithFormat:@"File missing: %@", fileURL.path ?: pathOrURL], nil);
      return;
    }

    [self.ttsInstance playWav:fileURL markAsLastUtterance:markAsLast.boolValue];
    resolve(@"queued");
  }

  RCT_EXPORT_METHOD(playBuffer:(NSDictionary *)description
                    resolver:(RCTPromiseResolveBlock)resolve
                    rejecter:(RCTPromiseRejectBlock)reject)
  {
    if (!self.ttsInstance) {
      reject(@"no_instance", @"TTS not initialized", nil);
      return;
    }

    NSString *base64 = [RCTConvert NSString:description[@"base64"]];
    NSNumber *sampleRate = [RCTConvert NSNumber:description[@"sampleRate"]];
    NSString *format = [RCTConvert NSString:description[@"format"]];
    NSNumber *channels = description[@"channels"] ? [RCTConvert NSNumber:description[@"channels"]] : @(1);
    NSNumber *interleaved = description[@"interleaved"] ? [RCTConvert NSNumber:description[@"interleaved"]] : @(YES);
    NSNumber *markAsLast = description[@"markAsLast"] ? [RCTConvert NSNumber:description[@"markAsLast"]] : @(YES);

    if (!base64 || !sampleRate || !format) {
      reject(@"invalid_args", @"Missing one of base64/sampleRate/format", nil);
      return;
    }

    NSData *raw = DTTSBase64Decode(base64);
    AVAudioPCMBuffer *buffer = DTTSMakeMonoF32Buffer(raw,
                                                     sampleRate.doubleValue,
                                                     format,
                                                     channels.integerValue,
                                                     interleaved.boolValue);
    if (!buffer) {
      reject(@"bad_buffer", @"Unsupported PCM layout, invalid base64, or empty data", nil);
      return;
    }

    [self.ttsInstance playBuffer:buffer markAsLastUtterance:markAsLast.boolValue];
    resolve(@"queued");
  }

  RCT_EXPORT_METHOD(destroy:(RCTPromiseResolveBlock)resolve
                    rejecter:(RCTPromiseRejectBlock)reject)
  {
    if (!self.ttsInstance) {
      // Idempotent: resolve anyway.
      resolve(@"Already destroyed");
      return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      [self.ttsInstance destroy];
      self.ttsInstance = nil;
      resolve(@"Destroyed");
    });
  }

@end
