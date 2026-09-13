#import <AVFoundation/AVFoundation.h>

// AVAudioPlayerNode raises Objective-C exceptions, which Swift do/catch cannot catch.
FOUNDATION_EXPORT NSString * _Nullable NanightStartAudioNode(AVAudioPlayerNode * _Nonnull node);
