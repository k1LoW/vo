#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain of the `NSError` a caught `NSException` is converted into.
extern NSErrorDomain const VoNSExceptionErrorDomain;

/// `userInfo` key carrying the raised exception's `name`.
extern NSString *const VoNSExceptionNameKey;

/// Runs `block`, converting a raised `NSException` into an `NSError`.
///
/// Swift has no way to catch an `NSException`, so a Cocoa API that raises one instead of
/// returning an error takes the whole process down however the Swift caller is written.
/// Only an Objective-C `@try` can intercept it.
///
/// Returns `YES` when `block` ran to completion, `NO` when it raised.
BOOL VoRunCatchingNSException(void (NS_NOESCAPE ^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
