#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, or nil. Swift cannot catch NSException; an exception
/// that unwinds through Swift frames ends the process. For calls into frameworks that report misuse by raising.
NSException * _Nullable FSCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
