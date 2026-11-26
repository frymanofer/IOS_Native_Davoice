#import "DVSpeakerVerificationCore.h"
#import <KeyWordDetection/KeyWordDetection-Swift.h>

static NSString * const DVSVErrorDomain = @"io.davoice.cordova.wakeword.sv";

/** Forwards the microphone controller's callbacks as plugin events. */
@interface DVSVDelegateProxy : NSObject <SpeakerVerificationNativeDelegate>
@property (nonatomic, copy) NSString *controllerId;
@property (nonatomic, weak) DVSpeakerVerificationCore *core;
@end

@interface DVSpeakerVerificationCore ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, id> *engines;
@property (nonatomic, strong) NSMutableDictionary<NSString *, SpeakerVerificationMicController *> *controllers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, DVSVDelegateProxy *> *proxies;
@property (nonatomic, strong) dispatch_queue_t micQueue;  // controller calls run one at a time
- (void)emit:(NSString *)eventName controllerId:(NSString *)controllerId info:(NSDictionary *)info;
@end

@implementation DVSVDelegateProxy
- (void)svOnboardingProgress:(NSDictionary<NSString *,id> *)info { [self.core emit:@"speakerVerificationOnboardingProgress" controllerId:self.controllerId info:info]; }
- (void)svOnboardingDone:(NSDictionary<NSString *,id> *)info { [self.core emit:@"speakerVerificationOnboardingDone" controllerId:self.controllerId info:info]; }
- (void)svVerifyResult:(NSDictionary<NSString *,id> *)info { [self.core emit:@"speakerVerificationVerifyResult" controllerId:self.controllerId info:info]; }
- (void)svError:(NSDictionary<NSString *,id> *)info { [self.core emit:@"speakerVerificationError" controllerId:self.controllerId info:info]; }
@end

@implementation DVSpeakerVerificationCore

- (instancetype)init
{
    if ((self = [super init])) {
        _engines = [NSMutableDictionary dictionary];
        _controllers = [NSMutableDictionary dictionary];
        _proxies = [NSMutableDictionary dictionary];
        _micQueue = dispatch_queue_create("io.davoice.cordova.sv.mic", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

+ (NSString *)resolvePath:(NSString *)input
{
    if (![input isKindOfClass:NSString.class] || input.length == 0) return nil;
    NSString *s = [input hasPrefix:@"file://"] ? [NSURL URLWithString:input].path : input;
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([s hasPrefix:@"/"] && [fm fileExistsAtPath:s]) return s;
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    NSString *name = [s hasPrefix:@"/"] ? [s substringFromIndex:1] : s;
    for (NSString *candidate in @[name, [@"www" stringByAppendingPathComponent:name], [@"public" stringByAppendingPathComponent:name],
                                  name.lastPathComponent, [@"www" stringByAppendingPathComponent:name.lastPathComponent],
                                  [@"public" stringByAppendingPathComponent:name.lastPathComponent]]) {
        NSString *path = [bundle stringByAppendingPathComponent:candidate];
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

- (id)executeAction:(NSString *)action options:(NSDictionary *)options error:(NSError **)error
{
    if ([action isEqualToString:@"createSpeakerVerifier"]) return [self createVerifier:options error:error];
    if ([action isEqualToString:@"verifySpeakerWav"]) return [self verifyWav:options error:error];
    if ([action isEqualToString:@"destroySpeakerVerifier"]) {
        NSString *engineId = [self required:@"engineId" options:options error:error]; if (!engineId) return nil;
        @synchronized (self) {
            if (!self.engines[engineId]) return [self fail:@"VERIFIER_NOT_FOUND" message:[NSString stringWithFormat:@"No speaker verifier: %@", engineId] error:error];
            [self.engines removeObjectForKey:engineId];
        }
        return @{ @"success": @YES, @"engineId": engineId, @"destroyed": @YES };
    }
    if ([action isEqualToString:@"createSpeakerVerificationMicController"]) return [self createController:options error:error];
    if ([action hasPrefix:@"sv"] || [action isEqualToString:@"destroySpeakerVerificationMicController"]) return [self controllerAction:action options:options error:error];
    return NSNull.null;
}

- (NSDictionary *)createVerifier:(NSDictionary *)options error:(NSError **)error
{
    NSString *engineId = [self required:@"engineId" options:options error:error]; if (!engineId) return nil;
    @synchronized (self) {
        if (self.engines[engineId]) return [self fail:@"VERIFIER_EXISTS" message:[NSString stringWithFormat:@"Speaker verifier already exists: %@", engineId] error:error];
    }
    NSString *modelIn = [self required:@"modelPath" options:options error:error]; if (!modelIn) return nil;
    NSString *modelPath = [DVSpeakerVerificationCore resolvePath:modelIn];
    if (!modelPath) return [self fail:@"FILE_NOT_FOUND" message:[NSString stringWithFormat:@"Model not found: %@", modelIn] error:error];
    NSString *jsonPath = nil;
    if ([options[@"enrollmentJson"] isKindOfClass:NSString.class] && [options[@"enrollmentJson"] length]) {
        jsonPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"dv_sv_%@.json", NSUUID.UUID.UUIDString]];
        if (![options[@"enrollmentJson"] writeToFile:jsonPath atomically:YES encoding:NSUTF8StringEncoding error:error]) return nil;
    } else {
        NSString *jsonIn = [self required:@"enrollmentJsonPath" options:options error:error]; if (!jsonIn) return nil;
        jsonPath = [DVSpeakerVerificationCore resolvePath:jsonIn];
        if (!jsonPath) return [self fail:@"FILE_NOT_FOUND" message:[NSString stringWithFormat:@"Enrollment not found: %@", jsonIn] error:error];
    }
    NSDictionary *engineOptions = [options[@"options"] isKindOfClass:NSDictionary.class] ? options[@"options"] : @{};
    NSError *nativeError = nil;
    id engine = [SpeakerVerificationRNFacade createEngineWithModelPath:modelPath enrollmentJsonPath:jsonPath options:engineOptions error:&nativeError];
    if (!engine) return [self fail:@"VERIFIER_CREATE_FAILED" message:nativeError.localizedDescription ?: @"Could not create the speaker verifier." error:error];
    @synchronized (self) { self.engines[engineId] = engine; }
    return @{ @"success": @YES, @"engineId": engineId, @"modelPath": modelPath };
}

- (NSDictionary *)verifyWav:(NSDictionary *)options error:(NSError **)error
{
    NSString *engineId = [self required:@"engineId" options:options error:error]; if (!engineId) return nil;
    id engine; @synchronized (self) { engine = self.engines[engineId]; }
    if (!engine) return [self fail:@"VERIFIER_NOT_FOUND" message:[NSString stringWithFormat:@"No speaker verifier: %@", engineId] error:error];
    NSString *wavIn = [self required:@"wavPath" options:options error:error]; if (!wavIn) return nil;
    NSString *wavPath = [DVSpeakerVerificationCore resolvePath:wavIn];
    if (!wavPath) return [self fail:@"FILE_NOT_FOUND" message:[NSString stringWithFormat:@"WAV not found: %@", wavIn] error:error];
    BOOL reset = options[@"resetState"] ? [options[@"resetState"] boolValue] : YES;
    NSError *nativeError = nil; NSDictionary *out;
    @synchronized (engine) { out = [SpeakerVerificationRNFacade verifyWavWithEngine:engine wavPath:wavPath reset:reset error:&nativeError]; }
    if (!out) return [self fail:@"VERIFY_FAILED" message:nativeError.localizedDescription ?: @"Verification failed." error:error];
    NSMutableDictionary *result = [out mutableCopy];
    result[@"success"] = @YES; result[@"engineId"] = engineId;
    return result;
}

- (NSDictionary *)createController:(NSDictionary *)options error:(NSError **)error
{
    NSString *controllerId = [self required:@"controllerId" options:options error:error]; if (!controllerId) return nil;
    @synchronized (self) {
        if (self.controllers[controllerId]) return [self fail:@"CONTROLLER_EXISTS" message:[NSString stringWithFormat:@"Speaker verification controller already exists: %@", controllerId] error:error];
    }
    id raw = options[@"config"];
    NSMutableDictionary *config;
    if ([raw isKindOfClass:NSDictionary.class]) config = [raw mutableCopy];
    else if ([raw isKindOfClass:NSString.class]) {
        id parsed = [NSJSONSerialization JSONObjectWithData:[raw dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        config = [parsed isKindOfClass:NSDictionary.class] ? [parsed mutableCopy] : nil;
    }
    if (![config[@"modelPath"] isKindOfClass:NSString.class]) return [self fail:@"INVALID_ARGUMENTS" message:@"config.modelPath is required." error:error];
    NSString *modelPath = [DVSpeakerVerificationCore resolvePath:config[@"modelPath"]];
    if (!modelPath) return [self fail:@"FILE_NOT_FOUND" message:[NSString stringWithFormat:@"Model not found: %@", config[@"modelPath"]] error:error];
    config[@"modelPath"] = modelPath;
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:config options:0 error:nil] encoding:NSUTF8StringEncoding];
    __block id controller = nil; __block NSError *nativeError = nil;
    dispatch_sync(self.micQueue, ^{ controller = [SpeakerVerificationRNFacade createMicControllerWithConfigJson:json error:&nativeError]; });
    if (![controller isKindOfClass:SpeakerVerificationMicController.class])
        return [self fail:@"CONTROLLER_CREATE_FAILED" message:nativeError.localizedDescription ?: @"Could not create the controller." error:error];
    DVSVDelegateProxy *proxy = [DVSVDelegateProxy new]; proxy.controllerId = controllerId; proxy.core = self;
    ((SpeakerVerificationMicController *)controller).delegate = proxy;
    @synchronized (self) { self.controllers[controllerId] = controller; self.proxies[controllerId] = proxy; }
    return @{ @"success": @YES, @"controllerId": controllerId, @"modelPath": modelPath };
}

- (NSDictionary *)controllerAction:(NSString *)action options:(NSDictionary *)options error:(NSError **)error
{
    NSString *controllerId = [self required:@"controllerId" options:options error:error]; if (!controllerId) return nil;
    SpeakerVerificationMicController *c; @synchronized (self) { c = self.controllers[controllerId]; }
    if (!c) return [self fail:@"CONTROLLER_NOT_FOUND" message:[NSString stringWithFormat:@"No speaker verification controller: %@", controllerId] error:error];
    NSMutableDictionary *result = [@{ @"success": @YES, @"controllerId": controllerId } mutableCopy];
    __block BOOL ok = YES; __block NSError *nativeError = nil;
    if ([action isEqualToString:@"svBeginOnboarding"]) {
        NSString *enrollmentId = [options[@"enrollmentId"] isKindOfClass:NSString.class] ? options[@"enrollmentId"] : @"default";
        NSInteger target = options[@"targetEmbeddingCount"] ? [options[@"targetEmbeddingCount"] integerValue] : 5;
        BOOL reset = options[@"reset"] ? [options[@"reset"] boolValue] : YES;
        dispatch_sync(self.micQueue, ^{ ok = [c beginOnboardingWithEnrollmentId:enrollmentId targetEmbeddingCount:target reset:reset error:&nativeError]; });
        result[@"enrollmentId"] = enrollmentId; result[@"target"] = @(target);
    } else if ([action isEqualToString:@"svGetNextEmbeddingFromMic"]) {
        dispatch_sync(self.micQueue, ^{ ok = [c getNextEmbeddingFromMicAndReturnError:&nativeError]; });
    } else if ([action isEqualToString:@"svFinalizeOnboardingNow"]) {
        dispatch_sync(self.micQueue, ^{ ok = [c finalizeOnboardingNowAndReturnError:&nativeError]; });
    } else if ([action isEqualToString:@"svSetEnrollmentJson"]) {
        NSString *json = [self required:@"enrollmentJson" options:options error:error]; if (!json) return nil;
        dispatch_sync(self.micQueue, ^{ ok = [c setEnrollmentJson:json error:&nativeError]; });
    } else if ([action isEqualToString:@"svStartVerifyFromMic"]) {
        BOOL reset = options[@"resetState"] ? [options[@"resetState"] boolValue] : YES;
        dispatch_sync(self.micQueue, ^{ ok = [c startVerifyFromMicWithResetState:reset error:&nativeError]; });
    } else if ([action isEqualToString:@"svStartEndlessVerifyFromMic"]) {
        float hop = options[@"hopSeconds"] ? [options[@"hopSeconds"] floatValue] : 2.0f;
        BOOL stopOnMatch = [options[@"stopOnMatch"] boolValue];
        BOOL reset = options[@"resetState"] ? [options[@"resetState"] boolValue] : YES;
        dispatch_sync(self.micQueue, ^{ ok = [c startEndlessVerifyFromMicWithHopSeconds:hop stopOnMatch:stopOnMatch resetState:reset error:&nativeError]; });
    } else if ([action isEqualToString:@"svStop"]) {
        dispatch_sync(self.micQueue, ^{ [c stop]; });
    } else if ([action isEqualToString:@"destroySpeakerVerificationMicController"]) {
        dispatch_sync(self.micQueue, ^{ [c stop]; });
        @synchronized (self) { [self.controllers removeObjectForKey:controllerId]; [self.proxies removeObjectForKey:controllerId]; }
        result[@"destroyed"] = @YES;
    } else {
        return [self fail:@"UNSUPPORTED_ACTION" message:[NSString stringWithFormat:@"Unsupported action: %@", action] error:error];
    }
    if (!ok) return [self fail:@"SPEAKER_VERIFICATION_FAILED" message:nativeError.localizedDescription ?: [NSString stringWithFormat:@"%@ failed.", action] error:error];
    return result;
}

- (NSUInteger)destroyAll
{
    NSArray *controllers;
    NSUInteger count;
    @synchronized (self) {
        controllers = self.controllers.allValues;
        count = self.engines.count + controllers.count;
        [self.engines removeAllObjects]; [self.controllers removeAllObjects]; [self.proxies removeAllObjects];
    }
    for (SpeakerVerificationMicController *c in controllers) dispatch_sync(self.micQueue, ^{ [c stop]; });
    return count;
}

- (void)emit:(NSString *)eventName controllerId:(NSString *)controllerId info:(NSDictionary *)info
{
    NSMutableDictionary *event = info ? [info mutableCopy] : [NSMutableDictionary dictionary];
    event[@"eventName"] = eventName; event[@"controllerId"] = controllerId ?: @"";
    void (^sink)(NSDictionary *) = self.eventSink;
    if (sink) sink(event);
}

- (NSString *)required:(NSString *)key options:(NSDictionary *)options error:(NSError **)error
{
    id value = options[key];
    if (![value isKindOfClass:NSString.class] || [(NSString *)value length] == 0) {
        [self fail:@"INVALID_ARGUMENTS" message:[NSString stringWithFormat:@"%@ is required.", key] error:error]; return nil;
    }
    return value;
}

- (id)fail:(NSString *)code message:(NSString *)message error:(NSError **)error
{
    if (error) *error = [NSError errorWithDomain:DVSVErrorDomain code:1 userInfo:@{ NSLocalizedDescriptionKey: message, @"code": code }];
    return nil;
}
@end
