// ContainerViewController.h - Main execution harness hosting guest macOS binaries on iPadOS.

#ifndef CONTAINERVIEWCONTROLLER_H
#define CONTAINERVIEWCONTROLLER_H

#include <TargetConditionals.h>
#if TARGET_OS_IPHONE || TARGET_OS_IOS
#import <UIKit/UIKit.h>
#define CVC_BASE_CLASS UIViewController
#else
#import <Foundation/Foundation.h>
#define CVC_BASE_CLASS NSObject
#endif

@class MetalPresenter;

@interface ContainerViewController : CVC_BASE_CLASS

@property (nonatomic, strong, readonly) MetalPresenter *presenter;
@property (nonatomic, copy) NSString *currentBinaryPath;
@property (nonatomic, readonly) BOOL isGuestRunning;

// Execution control
- (BOOL)loadAndExecuteGuestBinaryAtPath:(NSString *)path;
- (void)terminateGuestBinary;

// UI controls
- (void)toggleHUD;
- (void)presentDocumentPicker;

@end

#endif // CONTAINERVIEWCONTROLLER_H
