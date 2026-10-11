// AppDelegate.h - Host Application App Delegate.

#ifndef APPDELEGATE_H
#define APPDELEGATE_H

#include <TargetConditionals.h>
#if TARGET_OS_IPHONE || TARGET_OS_IOS
#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

#else
#import <Foundation/Foundation.h>

@interface AppDelegate : NSObject
@end

#endif

#endif // APPDELEGATE_H
