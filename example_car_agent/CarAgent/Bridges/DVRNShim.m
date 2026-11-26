#import "DVRNShim.h"

@implementation RCTEventEmitter
- (NSArray<NSString *> *)supportedEvents { return @[]; }
- (void)sendEventWithName:(NSString *)name body:(id)body
{
    void (^sink)(NSString *, id) = self.dvEventSink;
    if (sink) sink(name, body);
}
- (void)startObserving { }
- (void)stopObserving { }
- (void)addListener:(NSString *)eventName { }
- (void)removeListeners:(double)count { }
@end

@implementation RCTConvert
+ (NSNumber *)NSNumber:(id)json
{
    if ([json isKindOfClass:NSNumber.class]) return json;
    if ([json isKindOfClass:NSString.class]) {
        NSNumberFormatter *f = [NSNumberFormatter new];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        return [f numberFromString:json];
    }
    return nil;
}
+ (NSString *)NSString:(id)json
{
    if ([json isKindOfClass:NSString.class]) return json;
    if ([json isKindOfClass:NSNumber.class]) return [json stringValue];
    return nil;
}
+ (NSDictionary *)NSDictionary:(id)json { return [json isKindOfClass:NSDictionary.class] ? json : nil; }
+ (NSArray *)NSArray:(id)json { return [json isKindOfClass:NSArray.class] ? json : nil; }
+ (BOOL)BOOL:(id)json { return [json respondsToSelector:@selector(boolValue)] ? [json boolValue] : NO; }
+ (double)double:(id)json { return [json respondsToSelector:@selector(doubleValue)] ? [json doubleValue] : 0; }
@end
