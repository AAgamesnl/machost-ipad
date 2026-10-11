// AppDelegate.m - Host Application App Delegate.

#import "AppDelegate.h"
#import "ContainerViewController.h"

@implementation AppDelegate

#if TARGET_OS_IPHONE || TARGET_OS_IOS
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application; (void)launchOptions;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    ContainerViewController *rootVC = [[ContainerViewController alloc] init];
    self.window.rootViewController = rootVC;
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    (void)application;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    (void)application;
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    (void)application;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    (void)application;
}

- (void)applicationWillTerminate:(UIApplication *)application {
    (void)application;
}
#endif

@end
