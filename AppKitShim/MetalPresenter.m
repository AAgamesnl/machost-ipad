// MetalPresenter.m - Offscreen graphics capture pipeline, CAMetalLayer integration,
// and touch/pointer-to-NSEvent translation.

#import "MetalPresenter.h"
#import "AppKitShim.h"

#if TARGET_OS_IPHONE || TARGET_OS_IOS

static NSString *const kBlitShaderSource = @""
"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct VertexOut {\n"
"    float4 position [[position]];\n"
"    float2 uv;\n"
"};\n"
"vertex VertexOut quadVertex(uint vid [[vertex_id]]) {\n"
"    VertexOut out;\n"
"    float2 pos[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };\n"
"    float2 uv[4]  = { float2(0.0, 1.0),   float2(1.0, 1.0),   float2(0.0, 0.0),   float2(1.0, 0.0) };\n"
"    out.position = float4(pos[vid], 0.0, 1.0);\n"
"    out.uv = uv[vid];\n"
"    return out;\n"
"}\n"
"fragment float4 quadFragment(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {\n"
"    constexpr sampler s(address::clamp_to_edge, filter::linear);\n"
"    return tex.sample(s, in.uv);\n"
"}\n";

@interface MetalPresenter () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) id<MTLRenderPipelineState> blitPipelineState;
@property (nonatomic, strong) id<MTLTexture> pendingGuestTexture;
@end

@implementation MetalPresenter {
    NSUInteger _frameCount;
    NSTimeInterval _lastFPSUpdateTime;
    NSUInteger _currentFPS;
}

@synthesize currentFPS = _currentFPS;

+ (Class)layerClass {
    return [CAMetalLayer class];
}

- (CAMetalLayer *)metalLayer {
    return (CAMetalLayer *)self.layer;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupMetal];
        [self setupGestures];
        _enablesOffscreenCapture = YES;
        self.multipleTouchEnabled = YES;
        self.userInteractionEnabled = YES;
    }
    return self;
}

- (void)setupMetal {
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) return;

    CAMetalLayer *layer = self.metalLayer;
    layer.device = _device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.contentsScale = [UIScreen mainScreen].nativeScale;

    _commandQueue = [_device newCommandQueue];

    // Build pipeline for blitting offscreen guest textures
    NSError *error = nil;
    id<MTLLibrary> library = [_device newLibraryWithSource:kBlitShaderSource options:nil error:&error];
    if (library) {
        id<MTLFunction> vertFunc = [library newFunctionWithName:@"quadVertex"];
        id<MTLFunction> fragFunc = [library newFunctionWithName:@"quadFragment"];

        MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = vertFunc;
        desc.fragmentFunction = fragFunc;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

        _blitPipelineState = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
    }
}

- (void)setupGestures {
    // Hover gesture for iPad trackpad and Apple Pencil / mouse pointer
    if (@available(iOS 13.4, *)) {
        UIHoverGestureRecognizer *hover = [[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(handleHover:)];
        hover.delegate = self;
        [self addGestureRecognizer:hover];
    }

    // Two-finger pan gesture for scroll wheel emulation
    UIPanGestureRecognizer *twoFingerPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleTwoFingerPan:)];
    twoFingerPan.minimumNumberOfTouches = 2;
    twoFingerPan.maximumNumberOfTouches = 2;
    twoFingerPan.delegate = self;
    [self addGestureRecognizer:twoFingerPan];
}

// =============================================================================
// Guest Layer Integration
// =============================================================================
- (void)attachGuestLayer:(CALayer *)guestLayer {
    if (!guestLayer) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        guestLayer.frame = self.bounds;
        [self.layer addSublayer:guestLayer];
    });
}

- (void)detachGuestLayer:(CALayer *)guestLayer {
    if (!guestLayer) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [guestLayer removeFromSuperlayer];
    });
}

// =============================================================================
// Offscreen Texture Presentation
// =============================================================================
- (void)presentGuestTexture:(id<MTLTexture>)texture {
    if (!texture || !_blitPipelineState || !_commandQueue) return;
    _pendingGuestTexture = texture;
}

- (void)renderPendingTexture {
    id<MTLTexture> tex = _pendingGuestTexture;
    if (!tex) return;

    id<CAMetalDrawable> drawable = [self.metalLayer nextDrawable];
    if (!drawable) return;

    MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
    passDesc.colorAttachments[0].texture = drawable.texture;
    passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
    passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLCommandBuffer> cmdBuf = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cmdBuf renderCommandEncoderWithDescriptor:passDesc];
    [enc setRenderPipelineState:_blitPipelineState];
    [enc setFragmentTexture:tex atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [enc endEncoding];

    [cmdBuf presentDrawable:drawable];
    [cmdBuf commit];
    _pendingGuestTexture = nil;
}

// =============================================================================
// Presentation Loop & CADisplayLink
// =============================================================================
- (void)startPresentationLoop {
    if (_displayLink) return;
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onDisplayTick:)];
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    _lastFPSUpdateTime = CACurrentMediaTime();
    _frameCount = 0;
}

- (void)stopPresentationLoop {
    if (_displayLink) {
        [_displayLink invalidate];
        _displayLink = nil;
    }
}

- (void)onDisplayTick:(CADisplayLink *)link {
    (void)link;
    _frameCount++;
    NSTimeInterval now = CACurrentMediaTime();
    if (now - _lastFPSUpdateTime >= 1.0) {
        _currentFPS = _frameCount;
        _frameCount = 0;
        _lastFPSUpdateTime = now;
    }

    if (_enablesOffscreenCapture && _pendingGuestTexture) {
        [self renderPendingTexture];
    }
}

// =============================================================================
// Coordinate & Event Translation
// =============================================================================
- (CGPoint)translatePointToAppKit:(CGPoint)uiKitPoint {
    // iPadOS UIKit Y=0 is at top; macOS AppKit Y=0 is at bottom
    return CGPointMake(uiKitPoint.x, self.bounds.size.height - uiKitPoint.y);
}

- (void)dispatchMouseEvent:(NSUInteger)eventType atPoint:(CGPoint)uiKitPoint clickCount:(NSInteger)clicks pressure:(float)pressure {
    CGPoint appKitPoint = [self translatePointToAppKit:uiKitPoint];
    NSEvent *ev = [NSEvent mouseEventWithType:(NSEventType)eventType
                                     location:appKitPoint
                                modifierFlags:0
                                    timestamp:[[NSDate date] timeIntervalSinceReferenceDate]
                                 windowNumber:1
                                      context:nil
                                  eventNumber:1
                                   clickCount:clicks
                                     pressure:pressure];
    [[NSApplication sharedApplication] sendEvent:ev];
}

- (void)dispatchScrollEventAtPoint:(CGPoint)uiKitPoint deltaX:(CGFloat)dx deltaY:(CGFloat)dy {
    CGPoint appKitPoint = [self translatePointToAppKit:uiKitPoint];
    NSEvent *ev = [NSEvent scrollWheelEventWithLocation:appKitPoint
                                          modifierFlags:0
                                              timestamp:[[NSDate date] timeIntervalSinceReferenceDate]
                                                 deltaX:dx
                                                 deltaY:dy];
    [[NSApplication sharedApplication] sendEvent:ev];
}

- (void)dispatchKeyEvent:(BOOL)isKeyDown characters:(NSString *)chars unmodChars:(NSString *)unmod keyCode:(unsigned short)code modifiers:(NSUInteger)flags {
    NSEventType type = isKeyDown ? NSEventTypeKeyDown : NSEventTypeKeyUp;
    NSEvent *ev = [NSEvent keyEventWithType:type
                                   location:CGPointZero
                              modifierFlags:(NSEventModifierFlags)flags
                                  timestamp:[[NSDate date] timeIntervalSinceReferenceDate]
                               windowNumber:1
                                    context:nil
                                 characters:chars
                charactersIgnoringModifiers:unmod
                                  isARepeat:NO
                                    keyCode:code];
    [[NSApplication sharedApplication] sendEvent:ev];
}

// =============================================================================
// UIKit Touch & Gesture Handling
// =============================================================================
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    UITouch *t = [touches anyObject];
    if (t) {
        CGPoint p = [t locationInView:self];
        float pressure = (t.maximumPossibleForce > 0) ? (t.force / t.maximumPossibleForce) : 1.0f;
        [self dispatchMouseEvent:NSEventTypeLeftMouseDown atPoint:p clickCount:t.tapCount pressure:pressure];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    UITouch *t = [touches anyObject];
    if (t) {
        CGPoint p = [t locationInView:self];
        float pressure = (t.maximumPossibleForce > 0) ? (t.force / t.maximumPossibleForce) : 1.0f;
        [self dispatchMouseEvent:NSEventTypeLeftMouseDragged atPoint:p clickCount:1 pressure:pressure];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    UITouch *t = [touches anyObject];
    if (t) {
        CGPoint p = [t locationInView:self];
        [self dispatchMouseEvent:NSEventTypeLeftMouseUp atPoint:p clickCount:1 pressure:0.0f];
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    UITouch *t = [touches anyObject];
    if (t) {
        CGPoint p = [t locationInView:self];
        [self dispatchMouseEvent:NSEventTypeLeftMouseUp atPoint:p clickCount:1 pressure:0.0f];
    }
}

- (void)handleHover:(UIHoverGestureRecognizer *)recognizer API_AVAILABLE(ios(13.4)) {
    CGPoint p = [recognizer locationInView:self];
    if (recognizer.state == UIGestureRecognizerStateChanged || recognizer.state == UIGestureRecognizerStateBegan) {
        [self dispatchMouseEvent:NSEventTypeMouseMoved atPoint:p clickCount:0 pressure:0.0f];
    }
}

- (void)handleTwoFingerPan:(UIPanGestureRecognizer *)recognizer {
    CGPoint translation = [recognizer translationInView:self];
    CGPoint loc = [recognizer locationInView:self];
    // Invert Y delta to match macOS scroll orientation
    [self dispatchScrollEventAtPoint:loc deltaX:translation.x deltaY:-translation.y];
    [recognizer setTranslation:CGPointZero inView:self];
}

// Hardware Keyboard Support
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *p in presses) {
        if (@available(iOS 13.4, *)) {
            UIKey *k = p.key;
            if (k) {
                [self dispatchKeyEvent:YES
                             characters:k.characters
                             unmodChars:k.charactersIgnoringModifiers
                                keyCode:(unsigned short)k.keyCode
                              modifiers:k.modifierFlags];
                continue;
            }
        }
    }
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *p in presses) {
        if (@available(iOS 13.4, *)) {
            UIKey *k = p.key;
            if (k) {
                [self dispatchKeyEvent:NO
                             characters:k.characters
                             unmodChars:k.charactersIgnoringModifiers
                                keyCode:(unsigned short)k.keyCode
                              modifiers:k.modifierFlags];
                continue;
            }
        }
    }
    [super pressesEnded:presses withEvent:event];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

@end

#else

// Mock implementation for non-iOS host build verification
@implementation MetalPresenter
- (void)attachGuestLayer:(CALayer *)guestLayer { (void)guestLayer; }
- (void)detachGuestLayer:(CALayer *)guestLayer { (void)guestLayer; }
- (void)presentGuestTexture:(id<MTLTexture>)texture { (void)texture; }
- (CGPoint)translatePointToAppKit:(CGPoint)uiKitPoint { return uiKitPoint; }
- (void)dispatchMouseEvent:(NSUInteger)type atPoint:(CGPoint)p clickCount:(NSInteger)c pressure:(float)pr {
    (void)type; (void)p; (void)c; (void)pr;
}
- (void)dispatchScrollEventAtPoint:(CGPoint)p deltaX:(CGFloat)dx deltaY:(CGFloat)dy {
    (void)p; (void)dx; (void)dy;
}
- (void)dispatchKeyEvent:(BOOL)isDown characters:(NSString *)c unmodChars:(NSString *)u keyCode:(unsigned short)k modifiers:(NSUInteger)m {
    (void)isDown; (void)c; (void)u; (void)k; (void)m;
}
- (void)startPresentationLoop {}
- (void)stopPresentationLoop {}
@end

#endif
