// Copied from react-native-davoice (TTSNPM ios/STTRNBridge/STTBridge.h); only the React imports changed (DVRNShim.h).
#import "DVRNShim.h"

@class STT;  // from Swift

@interface STTBridge : RCTEventEmitter <RCTBridgeModule>
@end
