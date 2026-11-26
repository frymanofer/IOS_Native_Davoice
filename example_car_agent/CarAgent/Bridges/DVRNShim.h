// The parts of React Native's iOS headers that the DaVoice speech bridges (SpeechBridge,
// DaVoiceTTSBridge, STTBridge, copied from react-native-davoice) use, implemented for Cordova.
// RCT_EXPORT_METHOD declares a plain Objective-C method; DaVoiceSpeech finds it at runtime by name.
#import <Foundation/Foundation.h>

// Each DaVoice plugin compiles its own copy of these classes; the macros give them unique names so the
// speech and LLM plugins can be in one app.
#define RCTEventEmitter DVSpeechRCTEventEmitter
#define RCTConvert DVSpeechRCTConvert
#define RCTBridgeModule DVSpeechRCTBridgeModule

NS_ASSUME_NONNULL_BEGIN

typedef void (^RCTPromiseResolveBlock)(id _Nullable result);
typedef void (^RCTPromiseRejectBlock)(NSString * _Nullable code, NSString * _Nullable message, NSError * _Nullable error);
typedef void (^RCTResponseSenderBlock)(NSArray * _Nullable response);

#define RCT_EXPORT_MODULE(js_name) \
    + (NSString *)moduleName { NSString *n = @"" #js_name; return n.length ? n : NSStringFromClass(self); }
#define RCT_EXPORT_METHOD(method) - (void)method
#define RCT_REMAP_METHOD(js_name, method) - (void)method

#ifndef RCT_DEBUG
#define RCT_DEBUG 0
#endif
#define RCTLog(...) NSLog(__VA_ARGS__)
#define RCTLogInfo(...) NSLog(__VA_ARGS__)
#define RCTLogWarn(...) NSLog(__VA_ARGS__)
#define RCTLogError(...) NSLog(__VA_ARGS__)

@protocol RCTBridgeModule <NSObject>
@optional
+ (NSString *)moduleName;
+ (BOOL)requiresMainQueueSetup;
- (dispatch_queue_t)methodQueue;
@end

/** React Native's RCTEventEmitter: sendEventWithName:body: reaches JavaScript through DaVoiceSpeech. */
@interface RCTEventEmitter : NSObject <RCTBridgeModule>
@property (nonatomic, copy, nullable) void (^dvEventSink)(NSString *name, id _Nullable body);
- (NSArray<NSString *> *)supportedEvents;
- (void)sendEventWithName:(NSString *)name body:(id _Nullable)body;
- (void)startObserving;
- (void)stopObserving;
- (void)addListener:(NSString *)eventName;
- (void)removeListeners:(double)count;
@end

@interface RCTConvert : NSObject
+ (nullable NSNumber *)NSNumber:(nullable id)json;
+ (nullable NSString *)NSString:(nullable id)json;
+ (nullable NSDictionary *)NSDictionary:(nullable id)json;
+ (nullable NSArray *)NSArray:(nullable id)json;
+ (BOOL)BOOL:(nullable id)json;
+ (double)double:(nullable id)json;
@end

NS_ASSUME_NONNULL_END
