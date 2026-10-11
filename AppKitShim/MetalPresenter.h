// MetalPresenter.h - Offscreen graphics capture pipeline, CAMetalLayer integration,
// and touch/pointer-to-NSEvent translation.

#ifndef METALPRESENTER_H
#define METALPRESENTER_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>

#include <TargetConditionals.h>
#if TARGET_OS_IPHONE || TARGET_OS_IOS
#import <UIKit/UIKit.h>
#define MP_VIEW_BASE UIView
#else
@interface MP_VIEW_BASE : NSObject
@property (nonatomic) CGRect frame;
@property (nonatomic) CGRect bounds;
@property (nonatomic, strong) CALayer *layer;
@end
#endif

@class NSEvent;

@interface MetalPresenter : MP_VIEW_BASE

@property (nonatomic, readonly) CAMetalLayer *metalLayer;
@property (nonatomic, readonly) id<MTLDevice> device;
@property (nonatomic, readonly) id<MTLCommandQueue> commandQueue;
@property (nonatomic, assign) BOOL enablesOffscreenCapture;
@property (nonatomic, readonly) NSUInteger currentFPS;

// Direct layer integration
- (void)attachGuestLayer:(CALayer *)guestLayer;
- (void)detachGuestLayer:(CALayer *)guestLayer;

// Offscreen graphics capture pipeline
- (void)presentGuestTexture:(id<MTLTexture>)texture;

// Coordinate and event translation
- (CGPoint)translatePointToAppKit:(CGPoint)uiKitPoint;
- (void)dispatchMouseEvent:(NSUInteger)eventType atPoint:(CGPoint)uiKitPoint clickCount:(NSInteger)clicks pressure:(float)pressure;
- (void)dispatchScrollEventAtPoint:(CGPoint)uiKitPoint deltaX:(CGFloat)dx deltaY:(CGFloat)dy;
- (void)dispatchKeyEvent:(BOOL)isKeyDown characters:(NSString *)chars unmodChars:(NSString *)unmod keyCode:(unsigned short)code modifiers:(NSUInteger)flags;

// Presentation loop lifecycle
- (void)startPresentationLoop;
- (void)stopPresentationLoop;

@end

#endif // METALPRESENTER_H
