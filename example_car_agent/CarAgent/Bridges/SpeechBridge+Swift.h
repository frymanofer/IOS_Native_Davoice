// The methods of SpeechBridge (copied unchanged from react-native-davoice) that the Swift app calls. SpeechBridge defines them with
// RCT_EXPORT_METHOD in SpeechBridge.m only; this category declares them so Swift can call them directly. Same names and arguments as
// the React Native `Speech` object's native module (react-native-davoice/speech), so the Swift SpeechController mirrors its JS layer.
#import "SpeechBridge.h"

NS_ASSUME_NONNULL_BEGIN

@interface SpeechBridge (DVSwift)
- (void)setLicense:(NSString *)licenseKey resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)setAudioRoutingConfig:(NSString *)jsonConfig resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)initAll:(NSDictionary *)opts resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)destroyAll:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)pauseSpeechRecognitionLiteAsync:(NSNumber *)timeoutMs resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)unPauseSpeechRecognitionLiteAsync:(NSNumber *)times preFetchMs:(NSNumber *)preFetch timeoutMs:(NSNumber *)timeoutMs
                                 resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)startSpeechAsync:(NSString *)locale timeoutMs:(NSNumber *)timeoutMs resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)startSpeechWithSVSpeakers:(NSString *)locale speakers:(NSArray *)speakers timeoutMs:(NSNumber *)timeoutMs
                         resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)addSpeaker:(NSString *)speakerId jsonOrPath:(NSString *)jsonOrPath resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)setSpeakers:(NSArray *)speakers resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)removeSpeaker:(NSString *)speakerId resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getSpeakerIds:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)setAECEnabled:(BOOL)enabled resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getAllVoices:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)getVoiceAbilities:(NSString *)name resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)changeVoice:(NSString *)name resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)speak:(NSString *)text speakerId:(NSNumber *)speakerId speed:(NSNumber *)speed
     resolver:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)stopSpeaking:(RCTPromiseResolveBlock)resolve rejecter:(RCTPromiseRejectBlock)reject;
- (void)isRecognizing:(RCTResponseSenderBlock)callback;
@end

NS_ASSUME_NONNULL_END
