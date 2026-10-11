// AppKitShim.m - Minimal AppKit implementation for hosting macOS binaries on iPadOS.

#import "AppKitShim.h"

#include <TargetConditionals.h>
#if TARGET_OS_IPHONE || TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif

NSApplication *NSApp = nil;

// Forward private interface for NSApplication so NSWindow and helper functions can invoke it without compiler warnings
@interface NSApplication ()
- (void)addWindow:(NSWindow *)window;
- (void)removeWindow:(NSWindow *)window;
- (void)setKeyWindow:(NSWindow *)window;
- (void)setCurrentEvent:(NSEvent *)event;
@end

// =============================================================================
// NSEvent Implementation
// =============================================================================
@implementation NSEvent {
    NSEventType _type;
    CGPoint _locationInWindow;
    NSEventModifierFlags _modifierFlags;
    NSTimeInterval _timestamp;
    __weak NSWindow *_window;
    NSString *_characters;
    NSString *_charactersIgnoringModifiers;
    unsigned short _keyCode;
    CGFloat _deltaX;
    CGFloat _deltaY;
    CGFloat _deltaZ;
    NSInteger _clickCount;
    float _pressure;
}

@synthesize type = _type;
@synthesize locationInWindow = _locationInWindow;
@synthesize modifierFlags = _modifierFlags;
@synthesize timestamp = _timestamp;
@synthesize window = _window;
@synthesize characters = _characters;
@synthesize charactersIgnoringModifiers = _charactersIgnoringModifiers;
@synthesize keyCode = _keyCode;
@synthesize deltaX = _deltaX;
@synthesize deltaY = _deltaY;
@synthesize deltaZ = _deltaZ;
@synthesize clickCount = _clickCount;
@synthesize pressure = _pressure;

+ (NSEvent *)mouseEventWithType:(NSEventType)type
                       location:(CGPoint)location
                  modifierFlags:(NSEventModifierFlags)flags
                      timestamp:(NSTimeInterval)time
                   windowNumber:(NSInteger)wNum
                        context:(id)context
                    eventNumber:(NSInteger)eNum
                     clickCount:(NSInteger)cCount
                       pressure:(float)pressure {
    (void)wNum; (void)context; (void)eNum;
    NSEvent *ev = [[NSEvent alloc] init];
    ev->_type = type;
    ev->_locationInWindow = location;
    ev->_modifierFlags = flags;
    ev->_timestamp = (time > 0) ? time : [[NSDate date] timeIntervalSinceReferenceDate];
    ev->_clickCount = cCount > 0 ? cCount : 1;
    ev->_pressure = pressure;
    ev->_window = [NSApp keyWindow];
    return ev;
}

+ (NSEvent *)keyEventWithType:(NSEventType)type
                     location:(CGPoint)location
                modifierFlags:(NSEventModifierFlags)flags
                    timestamp:(NSTimeInterval)time
                 windowNumber:(NSInteger)wNum
                      context:(id)context
                   characters:(NSString *)characters
  charactersIgnoringModifiers:(NSString *)unmod
                    isARepeat:(BOOL)repeat
                      keyCode:(unsigned short)code {
    (void)wNum; (void)context; (void)repeat;
    NSEvent *ev = [[NSEvent alloc] init];
    ev->_type = type;
    ev->_locationInWindow = location;
    ev->_modifierFlags = flags;
    ev->_timestamp = (time > 0) ? time : [[NSDate date] timeIntervalSinceReferenceDate];
    ev->_characters = [characters copy];
    ev->_charactersIgnoringModifiers = [unmod copy];
    ev->_keyCode = code;
    ev->_window = [NSApp keyWindow];
    return ev;
}

+ (NSEvent *)scrollWheelEventWithLocation:(CGPoint)location
                            modifierFlags:(NSEventModifierFlags)flags
                                timestamp:(NSTimeInterval)time
                                   deltaX:(CGFloat)dx
                                   deltaY:(CGFloat)dy {
    NSEvent *ev = [[NSEvent alloc] init];
    ev->_type = NSEventTypeScrollWheel;
    ev->_locationInWindow = location;
    ev->_modifierFlags = flags;
    ev->_timestamp = (time > 0) ? time : [[NSDate date] timeIntervalSinceReferenceDate];
    ev->_deltaX = dx;
    ev->_deltaY = dy;
    ev->_window = [NSApp keyWindow];
    return ev;
}

@end

// =============================================================================
// NSResponder Implementation
// =============================================================================
@implementation NSResponder

- (void)mouseDown:(NSEvent *)event { (void)event; }
- (void)mouseUp:(NSEvent *)event { (void)event; }
- (void)mouseMoved:(NSEvent *)event { (void)event; }
- (void)mouseDragged:(NSEvent *)event { (void)event; }
- (void)rightMouseDown:(NSEvent *)event { (void)event; }
- (void)rightMouseUp:(NSEvent *)event { (void)event; }
- (void)keyDown:(NSEvent *)event { (void)event; }
- (void)keyUp:(NSEvent *)event { (void)event; }
- (void)flagsChanged:(NSEvent *)event { (void)event; }
- (void)scrollWheel:(NSEvent *)event { (void)event; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder { return YES; }
- (BOOL)resignFirstResponder { return YES; }

@end

// =============================================================================
// NSView Implementation
// =============================================================================
@implementation NSView {
    NSMutableArray<NSView *> *_subviews;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super init];
    if (self) {
        _frame = frame;
        _bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
        _subviews = [NSMutableArray array];
        _wantsLayer = NO;
        _layer = nil;
    }
    return self;
}

- (NSArray<NSView *> *)subviews {
    return [_subviews copy];
}

- (void)addSubview:(NSView *)view {
    if (!view || view == self) return;
    [view removeFromSuperview];
    [_subviews addObject:view];
    view.superview = self;
    view.window = self.window;
    if (self.layer && view.layer) {
        [self.layer addSublayer:view.layer];
    }
}

- (void)removeFromSuperview {
    if (_superview) {
        [_superview->_subviews removeObject:self];
        _superview = nil;
        _window = nil;
        if (_layer) {
            [_layer removeFromSuperlayer];
        }
    }
}

- (void)setWantsLayer:(BOOL)wants {
    _wantsLayer = wants;
    if (wants && !_layer) {
        _layer = [CALayer layer];
        _layer.frame = _frame;
    }
}

- (void)setLayer:(CALayer *)layer {
    _layer = layer;
    if (layer) {
        _wantsLayer = YES;
        layer.frame = _frame;
    }
}

- (void)setFrame:(CGRect)frame {
    _frame = frame;
    _bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
    if (_layer) {
        _layer.frame = frame;
    }
}

- (void)setBounds:(CGRect)bounds {
    _bounds = bounds;
    if (_layer) {
        _layer.bounds = bounds;
    }
}

- (void)drawRect:(CGRect)dirtyRect {
    (void)dirtyRect;
}

- (void)setNeedsDisplay:(BOOL)flag {
    (void)flag;
    if (_layer) {
        [_layer setNeedsDisplay];
    }
}

- (void)setNeedsDisplayInRect:(CGRect)invalidRect {
    (void)invalidRect;
    if (_layer) {
        [_layer setNeedsDisplay];
    }
}

- (CGPoint)convertPoint:(CGPoint)point fromView:(NSView *)view {
    if (!view) return point;
    CGPoint p = point;
    p.x += (view.frame.origin.x - self.frame.origin.x);
    p.y += (view.frame.origin.y - self.frame.origin.y);
    return p;
}

- (CGPoint)convertPoint:(CGPoint)point toView:(NSView *)view {
    if (!view) return point;
    CGPoint p = point;
    p.x += (self.frame.origin.x - view.frame.origin.x);
    p.y += (self.frame.origin.y - view.frame.origin.y);
    return p;
}

- (CGRect)convertRect:(CGRect)rect fromView:(NSView *)view {
    CGPoint origin = [self convertPoint:rect.origin fromView:view];
    return CGRectMake(origin.x, origin.y, rect.size.width, rect.size.height);
}

- (CGRect)convertRect:(CGRect)rect toView:(NSView *)view {
    CGPoint origin = [self convertPoint:rect.origin toView:view];
    return CGRectMake(origin.x, origin.y, rect.size.width, rect.size.height);
}

- (NSView *)hitTest:(CGPoint)point {
    if (!CGRectContainsPoint(self.bounds, point)) return nil;
    for (NSView *subview in [_subviews reverseObjectEnumerator]) {
        CGPoint subPoint = CGPointMake(point.x - subview.frame.origin.x,
                                       point.y - subview.frame.origin.y);
        NSView *hit = [subview hitTest:subPoint];
        if (hit) return hit;
    }
    return self;
}

@end

// =============================================================================
// NSWindow Implementation
// =============================================================================
@implementation NSWindow {
    NSMutableArray<NSView *> *_registeredViews;
    BOOL _isVisible;
    NSInteger _level;
}

@synthesize level = _level;

- (instancetype)initWithContentRect:(CGRect)contentRect
                          styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backing
                              defer:(BOOL)flag {
    (void)style; (void)backing; (void)flag;
    self = [super init];
    if (self) {
        _frame = contentRect;
        _title = @"macOS Application";
        _isVisible = NO;
        _level = 0;
        _registeredViews = [NSMutableArray array];
        self.contentView = [[NSView alloc] initWithFrame:contentRect];
        [[NSApplication sharedApplication] addWindow:self];
    }
    return self;
}

- (void)setContentView:(NSView *)contentView {
    if (_contentView) {
        _contentView.window = nil;
    }
    _contentView = contentView;
    if (_contentView) {
        _contentView.frame = CGRectMake(0, 0, _frame.size.width, _frame.size.height);
        _contentView.window = self;
        if (!_firstResponder) {
            _firstResponder = _contentView;
        }
    }
}

- (BOOL)isKeyWindow {
    return ([NSApp keyWindow] == self);
}

- (BOOL)isVisible {
    return _isVisible;
}

- (void)makeKeyAndOrderFront:(id)sender {
    (void)sender;
    _isVisible = YES;
    [[NSApplication sharedApplication] setKeyWindow:self];
}

- (void)orderFront:(id)sender {
    (void)sender;
    _isVisible = YES;
}

- (void)orderOut:(id)sender {
    (void)sender;
    _isVisible = NO;
}

- (void)center {
    NSScreen *screen = [NSScreen mainScreen];
    CGRect sFrame = screen.frame;
    _frame.origin.x = (sFrame.size.width - _frame.size.width) / 2.0;
    _frame.origin.y = (sFrame.size.height - _frame.size.height) / 2.0;
}

- (void)close {
    _isVisible = NO;
    [[NSApplication sharedApplication] removeWindow:self];
}

- (void)setFrame:(CGRect)frame display:(BOOL)display {
    (void)display;
    _frame = frame;
    if (_contentView) {
        _contentView.frame = CGRectMake(0, 0, frame.size.width, frame.size.height);
    }
}

- (void)setContentSize:(CGSize)size {
    _frame.size = size;
    if (_contentView) {
        _contentView.frame = CGRectMake(0, 0, size.width, size.height);
    }
}

- (CGRect)contentRectForFrameRect:(CGRect)frameRect {
    return frameRect;
}

- (CGRect)frameRectForContentRect:(CGRect)contentRect {
    return contentRect;
}

- (BOOL)makeFirstResponder:(NSResponder *)responder {
    if (_firstResponder == responder) return YES;
    if ([_firstResponder resignFirstResponder]) {
        if ([responder becomeFirstResponder]) {
            _firstResponder = responder;
            return YES;
        }
    }
    return NO;
}

- (void)sendEvent:(NSEvent *)event {
    if (!event) return;
    switch (event.type) {
        case NSEventTypeLeftMouseDown:
        case NSEventTypeLeftMouseUp:
        case NSEventTypeRightMouseDown:
        case NSEventTypeRightMouseUp:
        case NSEventTypeMouseMoved:
        case NSEventTypeLeftMouseDragged:
        case NSEventTypeRightMouseDragged: {
            CGPoint loc = event.locationInWindow;
            NSView *targetView = [_contentView hitTest:loc];
            if (!targetView) targetView = _contentView;
            if (event.type == NSEventTypeLeftMouseDown) [targetView mouseDown:event];
            else if (event.type == NSEventTypeLeftMouseUp) [targetView mouseUp:event];
            else if (event.type == NSEventTypeRightMouseDown) [targetView rightMouseDown:event];
            else if (event.type == NSEventTypeRightMouseUp) [targetView rightMouseUp:event];
            else if (event.type == NSEventTypeMouseMoved) [targetView mouseMoved:event];
            else if (event.type == NSEventTypeLeftMouseDragged) [targetView mouseDragged:event];
            break;
        }
        case NSEventTypeKeyDown:
            if (_firstResponder) [_firstResponder keyDown:event];
            else if (_contentView) [_contentView keyDown:event];
            break;
        case NSEventTypeKeyUp:
            if (_firstResponder) [_firstResponder keyUp:event];
            else if (_contentView) [_contentView keyUp:event];
            break;
        case NSEventTypeScrollWheel:
            if (_firstResponder) [_firstResponder scrollWheel:event];
            else if (_contentView) [_contentView scrollWheel:event];
            break;
        default:
            break;
    }
}

@end

// =============================================================================
// NSApplication Implementation
// =============================================================================
@implementation NSApplication {
    NSMutableArray<NSWindow *> *_windowList;
    __weak NSWindow *_keyWin;
    BOOL _isRunning;
    BOOL _shouldStop;
    NSEvent *_currentEvent;
}

@synthesize running = _isRunning;
@synthesize currentEvent = _currentEvent;

+ (NSApplication *)sharedApplication {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSApp = [[NSApplication alloc] init];
    });
    return NSApp;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _windowList = [NSMutableArray array];
        _isRunning = NO;
        _shouldStop = NO;
        _currentEvent = nil;
    }
    return self;
}

- (void)addWindow:(NSWindow *)window {
    if (window && ![_windowList containsObject:window]) {
        [_windowList addObject:window];
        if (!_keyWin) _keyWin = window;
    }
}

- (void)removeWindow:(NSWindow *)window {
    if (window) {
        [_windowList removeObject:window];
        if (_keyWin == window) {
            _keyWin = [_windowList firstObject];
        }
    }
}

- (void)setKeyWindow:(NSWindow *)window {
    _keyWin = window;
}

- (void)setCurrentEvent:(NSEvent *)event {
    _currentEvent = event;
}

- (NSArray<NSWindow *> *)windows {
    return [_windowList copy];
}

- (NSWindow *)keyWindow {
    return _keyWin ? _keyWin : [_windowList firstObject];
}

- (NSWindow *)mainWindow {
    return [self keyWindow];
}

- (void)run {
    _isRunning = YES;
    _shouldStop = NO;

    if ([_delegate respondsToSelector:@selector(applicationDidFinishLaunching:)]) {
        NSNotification *notif = [NSNotification notificationWithName:@"NSApplicationDidFinishLaunchingNotification" object:self];
        [_delegate applicationDidFinishLaunching:notif];
    }

    // Process run loop ticks while active
    NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
    while (_isRunning && !_shouldStop) {
        @autoreleasepool {
            [runLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.016]];
        }
    }
}

- (void)stop:(id)sender {
    (void)sender;
    _shouldStop = YES;
    _isRunning = NO;
}

- (void)terminate:(id)sender {
    (void)sender;
    [self stop:nil];
    if ([_delegate respondsToSelector:@selector(applicationWillTerminate:)]) {
        NSNotification *notif = [NSNotification notificationWithName:@"NSApplicationWillTerminateNotification" object:self];
        [_delegate applicationWillTerminate:notif];
    }
}

- (void)sendEvent:(NSEvent *)event {
    if (!event) return;
    _currentEvent = event;
    NSWindow *win = event.window ? event.window : self.keyWindow;
    [win sendEvent:event];
}

- (void)postEvent:(NSEvent *)event atStart:(BOOL)flag {
    (void)flag;
    [self sendEvent:event];
}

- (void)activateIgnoringOtherApps:(BOOL)flag {
    (void)flag;
}

@end

// =============================================================================
// NSScreen Implementation
// =============================================================================
@implementation NSScreen

+ (NSScreen *)mainScreen {
    static NSScreen *s_main = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_main = [[NSScreen alloc] init];
    });
    return s_main;
}

+ (NSArray<NSScreen *> *)screens {
    return @[[NSScreen mainScreen]];
}

- (CGRect)frame {
#if TARGET_OS_IPHONE || TARGET_OS_IOS
    return [UIScreen mainScreen].bounds;
#else
    return CGRectMake(0, 0, 1024, 768);
#endif
}

- (CGRect)visibleFrame {
    return [self frame];
}

- (CGFloat)backingScaleFactor {
#if TARGET_OS_IPHONE || TARGET_OS_IOS
    return [UIScreen mainScreen].scale;
#else
    return 2.0;
#endif
}

@end

// =============================================================================
// NSColor & NSFont Implementation
// =============================================================================
@implementation NSColor {
    CGFloat _r, _g, _b, _a;
    CGColorRef _cachedColor;
}

+ (NSColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    NSColor *c = [[NSColor alloc] init];
    c->_r = r; c->_g = g; c->_b = b; c->_a = a;
    return c;
}

+ (NSColor *)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    return [self colorWithRed:r green:g blue:b alpha:a];
}

+ (NSColor *)colorWithDeviceRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    return [self colorWithRed:r green:g blue:b alpha:a];
}

+ (NSColor *)colorWithWhite:(CGFloat)white alpha:(CGFloat)alpha {
    return [self colorWithRed:white green:white blue:white alpha:alpha];
}

+ (NSColor *)clearColor { return [self colorWithRed:0 green:0 blue:0 alpha:0]; }
+ (NSColor *)blackColor { return [self colorWithRed:0 green:0 blue:0 alpha:1]; }
+ (NSColor *)whiteColor { return [self colorWithRed:1 green:1 blue:1 alpha:1]; }
+ (NSColor *)redColor   { return [self colorWithRed:1 green:0 blue:0 alpha:1]; }
+ (NSColor *)greenColor { return [self colorWithRed:0 green:1 blue:0 alpha:1]; }
+ (NSColor *)blueColor  { return [self colorWithRed:0 green:0 blue:1 alpha:1]; }

- (CGColorRef)CGColor {
    if (!_cachedColor) {
        CGFloat comps[4] = {_r, _g, _b, _a};
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        _cachedColor = CGColorCreate(cs, comps);
        CGColorSpaceRelease(cs);
    }
    return _cachedColor;
}

- (void)dealloc {
    if (_cachedColor) {
        CGColorRelease(_cachedColor);
    }
}

@end

@implementation NSFont {
    CGFloat _pointSize;
    BOOL _isBold;
}

+ (NSFont *)systemFontOfSize:(CGFloat)fontSize {
    NSFont *f = [[NSFont alloc] init];
    f->_pointSize = fontSize;
    f->_isBold = NO;
    return f;
}

+ (NSFont *)boldSystemFontOfSize:(CGFloat)fontSize {
    NSFont *f = [[NSFont alloc] init];
    f->_pointSize = fontSize;
    f->_isBold = YES;
    return f;
}

@end

// =============================================================================
// NSGraphicsContext Implementation
// =============================================================================
@implementation NSGraphicsContext {
    CGContextRef _context;
    BOOL _flipped;
}

@synthesize flipped = _flipped;

static NSGraphicsContext *s_currentContext = nil;

+ (NSGraphicsContext *)currentContext {
    return s_currentContext;
}

+ (void)setCurrentContext:(NSGraphicsContext *)context {
    s_currentContext = context;
}

+ (NSGraphicsContext *)graphicsContextWithCGContext:(CGContextRef)graphicsPort flipped:(BOOL)initialFlippedState {
    NSGraphicsContext *ctx = [[NSGraphicsContext alloc] init];
    if (graphicsPort) {
        CGContextRetain(graphicsPort);
    }
    ctx->_context = graphicsPort;
    ctx->_flipped = initialFlippedState;
    return ctx;
}

- (CGContextRef)CGContext {
    return _context;
}

- (void)dealloc {
    if (_context) {
        CGContextRelease(_context);
    }
}

@end

// =============================================================================
// NSMenu & NSMenuItem Implementation
// =============================================================================
@implementation NSMenuItem
- (instancetype)initWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)keyEq {
    self = [super init];
    if (self) {
        _title = [title copy];
        _action = action;
        _keyEquivalent = [keyEq copy];
    }
    return self;
}
@end

@implementation NSMenu {
    NSMutableArray<NSMenuItem *> *_items;
}

- (instancetype)initWithTitle:(NSString *)title {
    self = [super init];
    if (self) {
        _title = [title copy];
        _items = [NSMutableArray array];
    }
    return self;
}

- (NSArray<NSMenuItem *> *)itemArray {
    return [_items copy];
}

- (void)addItem:(NSMenuItem *)item {
    if (item) [_items addObject:item];
}

- (NSMenuItem *)addItemWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)keyEq {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:keyEq];
    [self addItem:item];
    return item;
}

@end

// =============================================================================
// NSCursor & NSWorkspace Implementation
// =============================================================================
@implementation NSCursor
+ (NSCursor *)arrowCursor { return [[NSCursor alloc] init]; }
+ (NSCursor *)IBeamCursor { return [[NSCursor alloc] init]; }
+ (NSCursor *)pointingHandCursor { return [[NSCursor alloc] init]; }
- (void)set {}
- (void)push {}
- (void)pop {}
@end

@implementation NSWorkspace
+ (NSWorkspace *)sharedWorkspace {
    static NSWorkspace *ws = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ws = [[NSWorkspace alloc] init];
    });
    return ws;
}

- (BOOL)openURL:(NSURL *)url {
#if TARGET_OS_IPHONE || TARGET_OS_IOS
    return [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil], YES;
#else
    (void)url;
    return YES;
#endif
}
@end

int NSApplicationMain(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app run];
    }
    return 0;
}
