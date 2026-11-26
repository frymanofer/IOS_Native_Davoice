// Copied from react-native-davoice (TTSNPM ios/TTSRNBridge/DaVoiceTTSBridge.h); only the React imports changed (DVRNShim.h).
#import "DVRNShim.h"

#import <DaVoiceTTS/DaVoiceTTS-Swift.h>

@interface DaVoiceTTSBridge : RCTEventEmitter <RCTBridgeModule>
@end
