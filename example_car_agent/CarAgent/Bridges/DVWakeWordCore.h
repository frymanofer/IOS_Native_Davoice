#import <Foundation/Foundation.h>
#import <KeyWordDetection/KeyWordDetection-Swift.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DVWakeWordEventSink)(NSDictionary *event);

/** Framework-neutral owner of iOS wake-word detector instances. */
@interface DVWakeWordCore : NSObject
@property (nonatomic, copy, nullable) DVWakeWordEventSink eventSink;
- (NSDictionary * _Nullable)executeAction:(NSString *)action
                                  options:(NSDictionary *)options
                                    error:(NSError **)error;
- (NSDictionary *)destroyAll;
@end

NS_ASSUME_NONNULL_END
