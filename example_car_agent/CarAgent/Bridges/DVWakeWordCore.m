#import "DVWakeWordCore.h"
#import "DVSpeakerVerificationCore.h"

static NSString * const DVWakeWordErrorDomain = @"io.davoice.cordova.wakeword";

@class DVWakeWordCore;
@interface DVWakeWordDetector : NSObject <KeywordDetectionRNDelegate>
@property (nonatomic, strong) KeyWordsDetection *detector;
@property (nonatomic, copy) NSString *instanceId;
@property (nonatomic, weak) DVWakeWordCore *core;
@property (nonatomic, copy, nullable) NSString *lastSpeakerId;
@property (nonatomic) float vadThreshold;
@property (nonatomic) NSInteger vadWindow;
@end

@interface DVWakeWordCore ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, DVWakeWordDetector *> *instances;
@end

@implementation DVWakeWordDetector
- (void)KeywordDetectionDidDetectEvent:(NSDictionary<NSString *,id> *)eventInfo
{
    NSMutableDictionary *event = eventInfo ? [eventInfo mutableCopy] : [NSMutableDictionary dictionary];
    event[@"eventName"] = @"keywordDetected";
    event[@"instanceId"] = self.instanceId;
    if (!event[@"modelName"] && event[@"phrase"]) event[@"modelName"] = event[@"phrase"];
    if (!event[@"phrase"] && event[@"modelName"]) event[@"phrase"] = event[@"modelName"];
    // The speaker that opened the speaker-verification gate (only when speakers are enrolled).
    if ([event[@"speakerId"] isKindOfClass:NSString.class]) self.lastSpeakerId = event[@"speakerId"];
    if (self.core.eventSink) self.core.eventSink(event);
}
@end

@implementation DVWakeWordCore

- (instancetype)init
{
    self = [super init];
    if (self) _instances = [NSMutableDictionary dictionary];
    return self;
}

- (NSDictionary *)executeAction:(NSString *)action options:(NSDictionary *)options error:(NSError **)error
{
    if ([action isEqualToString:@"ping"]) return @{ @"success": @YES, @"status": @"ok", @"platform": @"ios" };
    if ([action isEqualToString:@"create"]) return [self create:options multi:NO error:error];
    if ([action isEqualToString:@"createMulti"]) return [self create:options multi:YES error:error];
    if ([action isEqualToString:@"setAudioRoutingConfig"]) return [self setAudioRoutingConfig:options error:error];
    if ([action isEqualToString:@"destroyAll"]) return [self destroyAll];
    // App-wide audio session helpers (same as the React Native package).
    AudioSessionAndDuckingManager *audio = AudioSessionAndDuckingManager.shared;
    if ([action isEqualToString:@"enableDucking"] || [action isEqualToString:@"enableAggressiveDucking"]) { [audio enableAggressiveDucking]; return @{ @"success": @YES }; }
    if ([action isEqualToString:@"disableDucking"]) { [audio disableDucking]; return @{ @"success": @YES }; }
    if ([action isEqualToString:@"initAudioSessionAndDuckManager"]) { [audio initAudioSessAndDuckManage]; return @{ @"success": @YES }; }
    if ([action isEqualToString:@"restartListeningAfterDucking"]) { [audio restartListeningAfterDucking]; return @{ @"success": @YES }; }
    if ([action isEqualToString:@"disableDuckingAndCleanup"]) { [audio disableDuckingAndCleanup]; return @{ @"success": @YES }; }

    NSString *instanceId = [self requiredString:@"instanceId" options:options error:error];
    if (!instanceId) return nil;
    DVWakeWordDetector *wrapper = self.instances[instanceId];
    if (!wrapper) return [self fail:@"INSTANCE_NOT_FOUND" message:[NSString stringWithFormat:@"No instance found: %@", instanceId] error:error];
    KeyWordsDetection *detector = wrapper.detector;
    NSMutableDictionary *result = [@{ @"success": @YES, @"instanceId": instanceId } mutableCopy];

    if ([action isEqualToString:@"setLicense"]) {
        NSString *license = [self requiredString:@"license" options:options error:error];
        if (!license) return nil;
        result[@"licensed"] = @([detector setLicenseWithLicenseKey:license]);
    } else if ([action isEqualToString:@"start"]) {
        NSString *enrollment = [options[@"speakerVerificationEnrollmentJsonOrPath"] isKindOfClass:NSString.class]
                ? [DVWakeWordCore portableEnrollment:options[@"speakerVerificationEnrollmentJsonOrPath"]] : nil;
        BOOL noExternalActivation = options[@"noExternalActivation"] ? [options[@"noExternalActivation"] boolValue] : YES;
        BOOL duckOthers = options[@"duckOthers"] ? [options[@"duckOthers"] boolValue] : NO;
        BOOL mixWithOthers = options[@"mixWithOthers"] ? [options[@"mixWithOthers"] boolValue] : YES;
        BOOL defaultToSpeaker = options[@"defaultToSpeaker"] ? [options[@"defaultToSpeaker"] boolValue] : YES;
        BOOL started = enrollment.length > 0
            ? [detector startListeningWithSpeakerVerificationEnrollmentJsonOrPath:enrollment
                    noExternalActivation:noExternalActivation duckOthers:duckOthers
                    mixWithOthers:mixWithOthers defaultToSpeaker:defaultToSpeaker]
            : [detector startListeningWithNoExternalActivation:noExternalActivation duckOthers:duckOthers
                    mixWithOthers:mixWithOthers defaultToSpeaker:defaultToSpeaker];
        if (!started) return [self fail:@"START_FAILED" message:@"Native wake-word listening did not start." error:error];
        result[@"listening"] = @YES;
    } else if ([action isEqualToString:@"startWithSpeakerId"] || [action isEqualToString:@"startWithSpeakers"]) {
        BOOL noExternalActivation = options[@"noExternalActivation"] ? [options[@"noExternalActivation"] boolValue] : YES;
        BOOL duckOthers = options[@"duckOthers"] ? [options[@"duckOthers"] boolValue] : NO;
        BOOL mixWithOthers = options[@"mixWithOthers"] ? [options[@"mixWithOthers"] boolValue] : YES;
        BOOL defaultToSpeaker = options[@"defaultToSpeaker"] ? [options[@"defaultToSpeaker"] boolValue] : YES;
        BOOL started;
        if ([action isEqualToString:@"startWithSpeakers"]) {
            started = [detector startListeningWithSpeakers:[self speakerItems:options[@"speakers"]]
                    noExternalActivation:noExternalActivation duckOthers:duckOthers
                    mixWithOthers:mixWithOthers defaultToSpeaker:defaultToSpeaker];
        } else {
            NSString *enrollment = [self requiredString:@"speakerVerificationEnrollmentJsonOrPath" options:options error:error];
            if (!enrollment) return nil;
            enrollment = [DVWakeWordCore portableEnrollment:enrollment];
            NSString *speakerId = [options[@"speakerId"] isKindOfClass:NSString.class] && [options[@"speakerId"] length] ? options[@"speakerId"] : @"default";
            started = [detector startListeningWithSpeakerVerificationEnrollmentJsonOrPath:enrollment speakerId:speakerId
                    noExternalActivation:noExternalActivation duckOthers:duckOthers
                    mixWithOthers:mixWithOthers defaultToSpeaker:defaultToSpeaker];
        }
        if (!started) return [self fail:@"START_FAILED" message:@"Native wake-word listening did not start." error:error];
        result[@"listening"] = @YES;
    } else if ([action isEqualToString:@"addSpeaker"]) {
        NSString *json = [self requiredString:@"jsonOrPath" options:options error:error]; if (!json) return nil;
        NSString *speakerId = [options[@"speakerId"] isKindOfClass:NSString.class] && [options[@"speakerId"] length] ? options[@"speakerId"] : @"default";
        NSError *nativeError = nil;
        if (![detector addSpeakerWithId:speakerId jsonOrPath:[DVWakeWordCore portableEnrollment:json] error:&nativeError])
            return [self nativeFailure:@"SPEAKER_ERROR" nativeError:nativeError error:error];
        result[@"speakerIds"] = [detector getSpeakerIds];
    } else if ([action isEqualToString:@"setSpeakers"]) {
        NSError *nativeError = nil;
        if (![detector setSpeakers:[self speakerItems:options[@"speakers"]] error:&nativeError])
            return [self nativeFailure:@"SPEAKER_ERROR" nativeError:nativeError error:error];
        result[@"speakerIds"] = [detector getSpeakerIds];
    } else if ([action isEqualToString:@"removeSpeaker"]) {
        NSString *speakerId = [self requiredString:@"speakerId" options:options error:error]; if (!speakerId) return nil;
        result[@"removed"] = @([detector removeSpeakerWithId:speakerId]);
        result[@"speakerIds"] = [detector getSpeakerIds];
    } else if ([action isEqualToString:@"getSpeakerIds"]) {
        result[@"speakerIds"] = [detector getSpeakerIds];
    } else if ([action isEqualToString:@"getLastDetectedSpeakerId"]) {
        result[@"speakerId"] = wrapper.lastSpeakerId ?: NSNull.null;
    } else if ([action isEqualToString:@"setDetectionAudioRecording"]) {
        BOOL enabled = options[@"enabled"] ? [options[@"enabled"] boolValue] : YES;
        [detector setDetectionAudioRecording:enabled]; result[@"enabled"] = @(enabled);
    } else if ([action isEqualToString:@"isDetectionAudioRecordingEnabled"]) {
        result[@"enabled"] = @([detector isDetectionAudioRecordingEnabled]);
    } else if ([action isEqualToString:@"getVadParameters"]) {
        result[@"threshold"] = @(wrapper.vadThreshold); result[@"millisecondsWindow"] = @(wrapper.vadWindow);
    } else if ([action isEqualToString:@"startSilentVad"]) {
        result[@"listening"] = @([detector startSilentListening]);
    } else if ([action isEqualToString:@"stopSilentVad"]) {
        [detector stopSilentListening]; result[@"listening"] = @NO;
    } else if ([action isEqualToString:@"stop"]) {
        [detector stopListening]; result[@"listening"] = @NO;
    } else if ([action isEqualToString:@"pause"]) {
        BOOL stopMic = [options[@"stopMicrophone"] boolValue];
        [detector pauseDetectionWithStopMic:stopMic]; result[@"paused"] = @YES; result[@"microphoneStopped"] = @(stopMic);
    } else if ([action isEqualToString:@"resume"]) {
        [detector unPauseDetection]; result[@"paused"] = @NO;
    } else if ([action isEqualToString:@"replaceModel"]) {
        NSString *model = [self requiredString:@"modelName" options:options error:error]; if (!model) return nil;
        NSError *nativeError = nil;
        BOOL replaced = [detector replaceKeywordDetectionModelWithModelPath:model
            threshold:[options[@"threshold"] floatValue] ?: 0.99f
            bufferCnt:options[@"bufferCount"] ? [options[@"bufferCount"] integerValue] : 2 error:&nativeError];
        if (!replaced || nativeError) return [self nativeFailure:@"REPLACE_FAILED" nativeError:nativeError error:error];
        result[@"modelName"] = model;
    } else if ([action isEqualToString:@"getVoiceProps"]) {
        [result addEntriesFromDictionary:[detector getVoiceProps] ?: @{}];
    } else if ([action isEqualToString:@"getRecordingWav"]) {
        result[@"path"] = [detector getRecordingWav] ?: NSNull.null;
    } else if ([action isEqualToString:@"getRecordingWavArray"]) {
        NSString *path = [detector getRecordingWav]; result[@"paths"] = path ? @[path] : @[];
    } else if ([action isEqualToString:@"setVadParameters"]) {
        NSError *nativeError = nil; float threshold = options[@"threshold"] ? [options[@"threshold"] floatValue] : 0.45f;
        NSInteger window = options[@"millisecondsWindow"] ? [options[@"millisecondsWindow"] integerValue] : 1000;
        if (![detector setVADParamsWithThreshold:threshold msWindow:window error:&nativeError] || nativeError)
            return [self nativeFailure:@"VAD_PARAMETERS_FAILED" nativeError:nativeError error:error];
        wrapper.vadThreshold = threshold; wrapper.vadWindow = window;
        result[@"threshold"] = @(threshold); result[@"millisecondsWindow"] = @(window);
    } else if ([action isEqualToString:@"startVad"]) {
        BOOL started = [detector startVADListening];
        if (!started) return [self fail:@"VAD_START_FAILED" message:@"Native VAD listening did not start." error:error];
        result[@"listening"] = @YES;
    } else if ([action isEqualToString:@"stopVad"]) {
        [detector stopVADListening]; result[@"listening"] = @NO;
    } else if ([action isEqualToString:@"setTtsActive"]) {
        BOOL active = [options[@"active"] boolValue];
        if (active) [AudioSessionAndDuckingManager.shared beginWakeWordDuringTTS];
        else [AudioSessionAndDuckingManager.shared endWakeWordDuringTTS];
        result[@"active"] = @(active);
    } else if ([action isEqualToString:@"destroy"]) {
        [detector stopListening]; detector.delegate = nil; [self.instances removeObjectForKey:instanceId]; result[@"destroyed"] = @YES;
    } else if ([action isEqualToString:@"startForegroundService"] || [action isEqualToString:@"stopForegroundService"]) {
        return [self fail:@"UNAVAILABLE_ON_IOS" message:@"Foreground services are Android-only." error:error];
    } else {
        return [self fail:@"UNSUPPORTED_ACTION" message:[NSString stringWithFormat:@"Unsupported action: %@", action] error:error];
    }
    return result;
}

- (NSDictionary *)create:(NSDictionary *)options multi:(BOOL)multi error:(NSError **)error
{
    NSString *instanceId = [self requiredString:@"instanceId" options:options error:error]; if (!instanceId) return nil;
    if (self.instances[instanceId]) return [self fail:@"INSTANCE_EXISTS" message:[NSString stringWithFormat:@"Instance already exists: %@", instanceId] error:error];
    NSError *nativeError = nil; KeyWordsDetection *detector = nil;
    if (multi) {
        NSArray *models = options[@"modelNames"], *thresholds = options[@"thresholds"], *buffers = options[@"bufferCounts"], *cooldowns = options[@"millisecondsBetweenCallbacks"];
        if (![models isKindOfClass:NSArray.class] || models.count == 0 || thresholds.count != models.count || buffers.count != models.count || cooldowns.count != models.count)
            return [self fail:@"INVALID_ARGUMENTS" message:@"All multi-model arrays must have the same non-zero length." error:error];
        detector = [[KeyWordsDetection alloc] initWithModelPaths:models thresholds:thresholds bufferCnts:buffers msBetweenCallback:cooldowns error:&nativeError];
    } else {
        NSString *model = [self requiredString:@"modelName" options:options error:error]; if (!model) return nil;
        float threshold = options[@"threshold"] ? [options[@"threshold"] floatValue] : 0.99f;
        NSInteger buffer = options[@"bufferCount"] ? [options[@"bufferCount"] integerValue] : 2;
        detector = [[KeyWordsDetection alloc] initWithModelPath:model threshold:threshold bufferCnt:buffer error:&nativeError];
    }
    if (!detector || nativeError) return [self nativeFailure:@"CREATE_FAILED" nativeError:nativeError error:error];
    DVWakeWordDetector *wrapper = [DVWakeWordDetector new]; wrapper.instanceId = instanceId; wrapper.detector = detector; wrapper.core = self;
    wrapper.vadThreshold = 0.45f; wrapper.vadWindow = 1000;
    detector.delegate = wrapper; self.instances[instanceId] = wrapper;
    return @{ @"success": @YES, @"instanceId": instanceId };
}

- (NSDictionary *)setAudioRoutingConfig:(NSDictionary *)options error:(NSError **)error
{
    id config = options[@"config"];
    if (!config) return [self fail:@"INVALID_ARGUMENTS" message:@"config is required." error:error];
    NSString *json = [config isKindOfClass:NSString.class] ? config : nil;
    if (!json) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:config options:0 error:error];
        if (!data) return nil; json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    [AudioSessionAndDuckingManager.shared setWakewordAudioRoutingConfigFromJSONString:json];
    return @{ @"success": @YES };
}

- (NSDictionary *)destroyAll
{
    NSUInteger count = self.instances.count;
    for (DVWakeWordDetector *wrapper in self.instances.allValues) { [wrapper.detector stopListening]; wrapper.detector.delegate = nil; }
    [self.instances removeAllObjects];
    return @{ @"success": @YES, @"destroyedCount": @(count) };
}

/** [{id, json}] -> the native speaker items (string values only). */
- (NSArray<NSDictionary<NSString *, NSString *> *> *)speakerItems:(id)raw
{
    NSMutableArray *out = [NSMutableArray array];
    if (![raw isKindOfClass:NSArray.class]) return out;
    for (id item in (NSArray *)raw) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary<NSString *, NSString *> *entry = [NSMutableDictionary dictionary];
        if ([item[@"id"] isKindOfClass:NSString.class]) entry[@"id"] = item[@"id"];
        if ([item[@"json"] isKindOfClass:NSString.class]) entry[@"json"] = [DVWakeWordCore portableEnrollment:item[@"json"]];
        [out addObject:entry];
    }
    return out;
}

/**
 * An enrollment records the speaker model it was made with (configSnapshot.modelPath, an absolute
 * path). That path is gone when the enrollment comes from another device or platform, or after the
 * app container moved, and the native fallback only looks in the bundle root, while Cordova and
 * Capacitor apps keep models in www/ or public/. If the recorded file is missing, point it at the
 * app's speaker model (same file name, else sv.dm) found by the plugin's resolver.
 * Accepts the JSON text or a path to it; returns JSON text (or the input unchanged).
 */
+ (NSString *)portableEnrollment:(NSString *)jsonOrPath
{
    if (![jsonOrPath isKindOfClass:NSString.class] || jsonOrPath.length == 0) return jsonOrPath;
    NSString *text = jsonOrPath;
    NSString *trimmed = [jsonOrPath stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![trimmed hasPrefix:@"{"]) {
        NSString *path = [DVSpeakerVerificationCore resolvePath:trimmed];
        NSString *fileText = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
        if (!fileText) return jsonOrPath;
        text = fileText;
    }
    NSMutableDictionary *root = [[NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
                                                                 options:NSJSONReadingMutableContainers error:nil] mutableCopy];
    NSMutableDictionary *snapshot = [root[@"configSnapshot"] isKindOfClass:NSDictionary.class] ? [root[@"configSnapshot"] mutableCopy] : nil;
    NSString *modelPath = [snapshot[@"modelPath"] isKindOfClass:NSString.class] ? snapshot[@"modelPath"] : nil;
    if (!snapshot || modelPath.length == 0 || [NSFileManager.defaultManager fileExistsAtPath:modelPath]) return text;
    NSString *replacement = [DVSpeakerVerificationCore resolvePath:modelPath.lastPathComponent] ?: [DVSpeakerVerificationCore resolvePath:@"sv.dm"];
    if (!replacement) return text;
    snapshot[@"modelPath"] = replacement;
    root[@"configSnapshot"] = snapshot;
    NSData *data = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : text;
}

- (NSString *)requiredString:(NSString *)key options:(NSDictionary *)options error:(NSError **)error
{
    id value = options[key];
    if (![value isKindOfClass:NSString.class] || [(NSString *)value length] == 0) {
        [self fail:@"INVALID_ARGUMENTS" message:[NSString stringWithFormat:@"%@ is required.", key] error:error]; return nil;
    }
    return value;
}
- (NSDictionary *)nativeFailure:(NSString *)code nativeError:(NSError *)nativeError error:(NSError **)error
{ return [self fail:code message:nativeError.localizedDescription ?: @"Native operation failed." error:error]; }
- (NSDictionary *)fail:(NSString *)code message:(NSString *)message error:(NSError **)error
{
    if (error) *error = [NSError errorWithDomain:DVWakeWordErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message, @"code": code}];
    return nil;
}
@end
