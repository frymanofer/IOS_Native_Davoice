// Copied from react-native-davoice (TTSNPM ios/STTRNBridge/STTBridge.m); only the React imports changed (DVRNShim.h).
// STTBridge.m
#import "STTBridge.h"
#import "DVRNShim.h"
#import <DaVoiceTTS/DaVoiceTTS-Swift.h>  // correct for your single-module setup

@interface STTBridge () <STTDelegate>
@property (nonatomic, strong, nullable) STT *stt;
@property (nonatomic, assign) BOOL hasListeners;
@end

@implementation STTBridge

RCT_EXPORT_MODULE(STT)

+ (BOOL)requiresMainQueueSetup { return YES; }

- (NSArray<NSString *> *)supportedEvents {
  return @[
    @"onSpeechResults",
    @"onSpeechStart",
    @"onSpeechPartialResults",
    @"onSpeechError",
    @"onSpeechEnd",
    @"onSpeechRecognized",
    @"onSpeechVolumeChanged"
  ];
}

- (void)startObserving   { self.hasListeners = YES; }
- (void)stopObserving    { self.hasListeners = NO;  }
- (dispatch_queue_t)methodQueue { return dispatch_get_main_queue(); }

- (void)dealloc {
  if (_stt) {
    [_stt destroySpeech:nil]; // or ^(BOOL ok){}
    _stt = nil;
  }
}

#pragma mark - STTDelegate
- (void)stt:(STT *)stt didEmitEvent:(NSString *)name body:(NSDictionary *)body {
  if (!self.hasListeners) return;
  [self sendEventWithName:name body:body ?: @{}];
}

#pragma mark - Helpers
- (void)ensureSTT {
  if (!self.stt) {
    self.stt = [STT new];
    self.stt.delegate = self;
  }
}

#pragma mark - API
RCT_EXPORT_METHOD(setLicense:(NSString *)licenseKey
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (licenseKey == nil || (id)licenseKey == [NSNull null] || licenseKey.length == 0) {
    reject(@"invalid_args", @"Missing licenseKey", nil);
    return;
  }

  [self ensureSTT];
  BOOL ok = [self.stt setLicenseWithLicenseKey:licenseKey];
  resolve(@(ok));
}

RCT_EXPORT_METHOD(isLicenseValid:(NSString *)licenseKey
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  if (licenseKey == nil || (id)licenseKey == [NSNull null] || licenseKey.length == 0) {
    reject(@"invalid_args", @"Missing licenseKey", nil);
    return;
  }

  BOOL ok = [LicenseManager isLicenseValidWithLicenseKey:licenseKey];
  resolve(@(ok));
}

RCT_EXPORT_METHOD(startSpeech:(NSString *)locale
                  callback:(RCTResponseSenderBlock)callback)
{
  [self ensureSTT];
  [self.stt startSpeechWithLocaleStr:locale];
  if (callback) callback(@[@(NO)]);
}

RCT_EXPORT_METHOD(stopSpeech:(RCTResponseSenderBlock)callback)
{
  if (!self.stt) { if (callback) callback(@[@(NO)]); return; }
  [self.stt stopSpeech:^(BOOL ok) {
    if (callback) callback(@[@(NO)]);
  }];
}

RCT_EXPORT_METHOD(cancelSpeech:(RCTResponseSenderBlock)callback)
{
  if (!self.stt) { if (callback) callback(@[@(NO)]); return; }
  [self.stt cancelSpeech:^(BOOL ok) {
    if (callback) callback(@[@(NO)]);
  }];
}

RCT_EXPORT_METHOD(destroySpeech:(RCTResponseSenderBlock)callback)
{
  if (self.stt) {
    [self.stt destroySpeech:^(BOOL ok) {}];
    self.stt = nil;
  }
  if (callback) callback(@[@(NO)]);
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

@end
