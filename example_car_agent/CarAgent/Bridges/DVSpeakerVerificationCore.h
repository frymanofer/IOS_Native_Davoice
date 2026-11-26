#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** Speaker verification (WAV verifier + microphone onboarding/verification), framework-neutral. */
@interface DVSpeakerVerificationCore : NSObject
@property (nonatomic, copy, nullable) void (^eventSink)(NSDictionary *event);
/** Handles the speaker-verification actions; returns nil + error on failure, or NSNull.null for "not mine". */
- (id _Nullable)executeAction:(NSString *)action options:(NSDictionary *)options error:(NSError **)error;
- (NSUInteger)destroyAll;
/** Absolute path, file:// URL, or a file name in the app bundle (root, www/ or public/). nil if not found. */
+ (NSString * _Nullable)resolvePath:(NSString *)input;
@end

NS_ASSUME_NONNULL_END
