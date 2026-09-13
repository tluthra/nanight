#import "NanightAudioSafety.h"

NSString *NanightStartAudioNode(AVAudioPlayerNode *node) {
    @try {
        [node play];
        return nil;
    } @catch (NSException *exception) {
        return exception.reason ?: exception.name;
    }
}
