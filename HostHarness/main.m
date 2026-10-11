// main.m - Host Application entry point.

#import "AppDelegate.h"

#include <TargetConditionals.h>
#if TARGET_OS_IPHONE || TARGET_OS_IOS
#import <UIKit/UIKit.h>

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
#else
#import <Foundation/Foundation.h>

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSLog(@"MacHost execution harness built for non-iOS host.");
    }
    return 0;
}
#endif
