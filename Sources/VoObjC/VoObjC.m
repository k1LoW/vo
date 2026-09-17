#import "VoObjC.h"

NSErrorDomain const VoNSExceptionErrorDomain = @"io.github.k1low.vo.NSException";
NSString *const VoNSExceptionNameKey = @"VoNSExceptionName";

BOOL VoRunCatchingNSException(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        // Resuming after a caught NSException is only sound because the raise happens
        // inside the callee's own Objective-C frames, so no Swift frame is unwound and
        // nothing of ours is left half-built. Callers must still discard the object they
        // were setting up rather than reuse it.
        if (error != NULL) {
            *error = [NSError errorWithDomain:VoNSExceptionErrorDomain
                                         code:0
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: exception.reason ?: exception.name,
                                         VoNSExceptionNameKey: exception.name,
                                     }];
        }
        return NO;
    }
}
