// AppKitShim.h - Minimal AppKit implementation for hosting macOS binaries on iPadOS.
#ifndef APPKITSHIM_H
#define APPKITSHIM_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>

#ifdef __cplusplus
extern "C" {
#endif

// =============================================================================
// AppKit Geometry Types & Helpers
// =============================================================================
typedef CGPoint NSPoint;
typedef NSPoint *NSPointPointer;
typedef NSPoint *NSPointArray;

typedef CGSize NSSize;
typedef NSSize *NSSizePointer;
typedef NSSize *NSSizeArray;

typedef CGRect NSRect;
typedef NSRect *NSRectPointer;
typedef NSRect *NSRectArray;

static inline NSPoint NSMakePoint(CGFloat x, CGFloat y) { return CGPointMake(x, y); }
static inline NSSize NSMakeSize(CGFloat w, CGFloat h) { return CGSizeMake(w, h); }
static inline NSRect NSMakeRect(CGFloat x, CGFloat y, CGFloat w, CGFloat h) { return CGRectMake(x, y, w, h); }

#define NSZeroPoint CGPointZero
#define NSZeroSize  CGSizeZero
#define NSZeroRect  CGRectZero

static inline BOOL NSEqualPoints(NSPoint a, NSPoint b) { return CGPointEqualToPoint(a, b); }
static inline BOOL NSEqualSizes(NSSize a, NSSize b)   { return CGSizeEqualToSize(a, b); }
static inline BOOL NSEqualRects(NSRect a, NSRect b)   { return CGRectEqualToRect(a, b); }

// Forward declarations
@class NSApplication;
@class NSWindow;
@class NSView;
@class NSEvent;
@class NSScreen;
@class NSColor;
@class NSFont;
@class NSMenu;
@class NSMenuItem;
@class NSGraphicsContext;

extern NSApplication *NSApp;

// NSEvent Types
typedef NS_ENUM(NSUInteger, NSEventType) {
    NSEventTypeLeftMouseDown      = 1,
    NSEventTypeLeftMouseUp        = 2,
    NSEventTypeRightMouseDown     = 3,
    NSEventTypeRightMouseUp       = 4,
    NSEventTypeMouseMoved         = 5,
    NSEventTypeLeftMouseDragged   = 6,
    NSEventTypeRightMouseDragged  = 7,
    NSEventTypeMouseEntered       = 8,
    NSEventTypeMouseExited        = 9,
    NSEventTypeKeyDown            = 10,
    NSEventTypeKeyUp              = 11,
    NSEventTypeFlagsChanged       = 12,
    NSEventTypeAppKitDefined      = 13,
    NSEventTypeSystemDefined      = 14,
    NSEventTypeApplicationDefined = 15,
    NSEventTypePeriodic           = 16,
    NSEventTypeCursorUpdate       = 17,
    NSEventTypeScrollWheel        = 22,
    NSEventTypeOtherMouseDown     = 25,
    NSEventTypeOtherMouseUp       = 26,
    NSEventTypeOtherMouseDragged  = 27
};

// NSEvent Modifier Flags
typedef NS_OPTIONS(NSUInteger, NSEventModifierFlags) {
    NSEventModifierFlagCapsLock = 1 << 16,
    NSEventModifierFlagShift    = 1 << 17,
    NSEventModifierFlagControl  = 1 << 18,
    NSEventModifierFlagOption   = 1 << 19,
    NSEventModifierFlagCommand  = 1 << 20,
    NSEventModifierFlagNumericPad = 1 << 21,
    NSEventModifierFlagHelp     = 1 << 22,
    NSEventModifierFlagFunction = 1 << 23,
    NSEventModifierFlagDeviceIndependentFlagsMask = 0xffff0000UL
};

// NSWindow Style Masks
typedef NS_OPTIONS(NSUInteger, NSWindowStyleMask) {
    NSWindowStyleMaskBorderless             = 0,
    NSWindowStyleMaskTitled                 = 1 << 0,
    NSWindowStyleMaskClosable               = 1 << 1,
    NSWindowStyleMaskMiniaturizable         = 1 << 2,
    NSWindowStyleMaskResizable              = 1 << 3,
    NSWindowStyleMaskFullSizeContentView    = 1 << 15
};

typedef NS_ENUM(NSUInteger, NSBackingStoreType) {
    NSBackingStoreRetained    = 0,
    NSBackingStoreNonretained = 1,
    NSBackingStoreBuffered    = 2
};

// -----------------------------------------------------------------------------
// NSEvent
// -----------------------------------------------------------------------------
@interface NSEvent : NSObject

@property (nonatomic, readonly) NSEventType type;
@property (nonatomic, readonly) CGPoint locationInWindow;
@property (nonatomic, readonly) NSEventModifierFlags modifierFlags;
@property (nonatomic, readonly) NSTimeInterval timestamp;
@property (nonatomic, readonly, weak) NSWindow *window;
@property (nonatomic, readonly, copy) NSString *characters;
@property (nonatomic, readonly, copy) NSString *charactersIgnoringModifiers;
@property (nonatomic, readonly) unsigned short keyCode;
@property (nonatomic, readonly) CGFloat deltaX;
@property (nonatomic, readonly) CGFloat deltaY;
@property (nonatomic, readonly) CGFloat deltaZ;
@property (nonatomic, readonly) NSInteger clickCount;
@property (nonatomic, readonly) float pressure;

+ (NSEvent *)mouseEventWithType:(NSEventType)type
                       location:(CGPoint)location
                  modifierFlags:(NSEventModifierFlags)flags
                      timestamp:(NSTimeInterval)time
                   windowNumber:(NSInteger)wNum
                        context:(id)context
                    eventNumber:(NSInteger)eNum
                     clickCount:(NSInteger)cCount
                       pressure:(float)pressure;

+ (NSEvent *)keyEventWithType:(NSEventType)type
                     location:(CGPoint)location
                modifierFlags:(NSEventModifierFlags)flags
                    timestamp:(NSTimeInterval)time
                 windowNumber:(NSInteger)wNum
                      context:(id)context
                   characters:(NSString *)characters
  charactersIgnoringModifiers:(NSString *)unmod
                    isARepeat:(BOOL)repeat
                      keyCode:(unsigned short)code;

+ (NSEvent *)scrollWheelEventWithLocation:(CGPoint)location
                            modifierFlags:(NSEventModifierFlags)flags
                                timestamp:(NSTimeInterval)time
                                   deltaX:(CGFloat)dx
                                   deltaY:(CGFloat)dy;

@end

// -----------------------------------------------------------------------------
// NSResponder
// -----------------------------------------------------------------------------
@interface NSResponder : NSObject

- (void)mouseDown:(NSEvent *)event;
- (void)mouseUp:(NSEvent *)event;
- (void)mouseMoved:(NSEvent *)event;
- (void)mouseDragged:(NSEvent *)event;
- (void)rightMouseDown:(NSEvent *)event;
- (void)rightMouseUp:(NSEvent *)event;
- (void)keyDown:(NSEvent *)event;
- (void)keyUp:(NSEvent *)event;
- (void)flagsChanged:(NSEvent *)event;
- (void)scrollWheel:(NSEvent *)event;
- (BOOL)acceptsFirstResponder;
- (BOOL)becomeFirstResponder;
- (BOOL)resignFirstResponder;

@end

// -----------------------------------------------------------------------------
// NSView
// -----------------------------------------------------------------------------
@interface NSView : NSResponder

@property (nonatomic) CGRect frame;
@property (nonatomic) CGRect bounds;
@property (nonatomic, weak) NSView *superview;
@property (nonatomic, readonly) NSArray<NSView *> *subviews;
@property (nonatomic, weak) NSWindow *window;
@property (nonatomic) BOOL wantsLayer;
@property (nonatomic, strong) CALayer *layer;

- (instancetype)initWithFrame:(CGRect)frame;
- (void)addSubview:(NSView *)view;
- (void)removeFromSuperview;
- (void)drawRect:(CGRect)dirtyRect;
- (void)setNeedsDisplay:(BOOL)flag;
- (void)setNeedsDisplayInRect:(CGRect)invalidRect;
- (CGPoint)convertPoint:(CGPoint)point fromView:(NSView *)view;
- (CGPoint)convertPoint:(CGPoint)point toView:(NSView *)view;
- (CGRect)convertRect:(CGRect)rect fromView:(NSView *)view;
- (CGRect)convertRect:(CGRect)rect toView:(NSView *)view;
- (NSView *)hitTest:(CGPoint)point;

@end

// -----------------------------------------------------------------------------
// NSWindow
// -----------------------------------------------------------------------------
@interface NSWindow : NSResponder

@property (nonatomic) CGRect frame;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) NSView *contentView;
@property (nonatomic, weak) id delegate;
@property (nonatomic, readonly) BOOL isKeyWindow;
@property (nonatomic, readonly) BOOL isVisible;
@property (nonatomic, weak) NSResponder *firstResponder;
@property (nonatomic) NSInteger level;

- (instancetype)initWithContentRect:(CGRect)contentRect
                          styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backing
                              defer:(BOOL)flag;

- (void)makeKeyAndOrderFront:(id)sender;
- (void)orderFront:(id)sender;
- (void)orderOut:(id)sender;
- (void)center;
- (void)close;
- (void)setFrame:(CGRect)frame display:(BOOL)display;
- (void)setContentSize:(CGSize)size;
- (CGRect)contentRectForFrameRect:(CGRect)frameRect;
- (CGRect)frameRectForContentRect:(CGRect)contentRect;
- (void)sendEvent:(NSEvent *)event;
- (BOOL)makeFirstResponder:(NSResponder *)responder;

@end

// -----------------------------------------------------------------------------
// NSApplication
// -----------------------------------------------------------------------------
@protocol NSApplicationDelegate <NSObject>
@optional
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender;
- (void)applicationWillTerminate:(NSNotification *)notification;
@end

@interface NSApplication : NSResponder

@property (nonatomic, weak) id<NSApplicationDelegate> delegate;
@property (nonatomic, readonly) NSArray<NSWindow *> *windows;
@property (nonatomic, readonly, weak) NSWindow *keyWindow;
@property (nonatomic, readonly, weak) NSWindow *mainWindow;
@property (nonatomic, getter=isRunning, readonly) BOOL running;
@property (nonatomic, strong) NSMenu *mainMenu;
@property (nonatomic, readonly) NSEvent *currentEvent;

+ (NSApplication *)sharedApplication;
- (void)run;
- (void)stop:(id)sender;
- (void)terminate:(id)sender;
- (void)sendEvent:(NSEvent *)event;
- (void)postEvent:(NSEvent *)event atStart:(BOOL)flag;
- (void)activateIgnoringOtherApps:(BOOL)flag;

@end

// -----------------------------------------------------------------------------
// NSScreen
// -----------------------------------------------------------------------------
@interface NSScreen : NSObject

@property (nonatomic, readonly) CGRect frame;
@property (nonatomic, readonly) CGRect visibleFrame;
@property (nonatomic, readonly) CGFloat backingScaleFactor;

+ (NSScreen *)mainScreen;
+ (NSArray<NSScreen *> *)screens;

@end

// -----------------------------------------------------------------------------
// NSColor & NSFont
// -----------------------------------------------------------------------------
@interface NSColor : NSObject

+ (NSColor *)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a;
+ (NSColor *)colorWithCalibratedRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a;
+ (NSColor *)colorWithDeviceRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a;
+ (NSColor *)colorWithWhite:(CGFloat)white alpha:(CGFloat)alpha;
+ (NSColor *)clearColor;
+ (NSColor *)blackColor;
+ (NSColor *)whiteColor;
+ (NSColor *)redColor;
+ (NSColor *)greenColor;
+ (NSColor *)blueColor;

- (CGColorRef)CGColor;

@end

@interface NSFont : NSObject

+ (NSFont *)systemFontOfSize:(CGFloat)fontSize;
+ (NSFont *)boldSystemFontOfSize:(CGFloat)fontSize;

@end

// -----------------------------------------------------------------------------
// NSGraphicsContext
// -----------------------------------------------------------------------------
@interface NSGraphicsContext : NSObject

+ (NSGraphicsContext *)currentContext;
+ (void)setCurrentContext:(NSGraphicsContext *)context;
+ (NSGraphicsContext *)graphicsContextWithCGContext:(CGContextRef)graphicsPort flipped:(BOOL)initialFlippedState;

- (CGContextRef)CGContext;
@property (nonatomic, readonly, getter=isFlipped) BOOL flipped;

@end

// -----------------------------------------------------------------------------
// NSMenu & NSMenuItem
// -----------------------------------------------------------------------------
@interface NSMenuItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic) SEL action;
@property (nonatomic, weak) id target;
@property (nonatomic, copy) NSString *keyEquivalent;
@property (nonatomic, strong) NSMenu *submenu;

- (instancetype)initWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)keyEq;
@end

@interface NSMenu : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, readonly) NSArray<NSMenuItem *> *itemArray;

- (instancetype)initWithTitle:(NSString *)title;
- (void)addItem:(NSMenuItem *)item;
- (NSMenuItem *)addItemWithTitle:(NSString *)title action:(SEL)action keyEquivalent:(NSString *)keyEq;
@end

// -----------------------------------------------------------------------------
// NSCursor & NSWorkspace
// -----------------------------------------------------------------------------
@interface NSCursor : NSObject
+ (NSCursor *)arrowCursor;
+ (NSCursor *)IBeamCursor;
+ (NSCursor *)pointingHandCursor;
- (void)set;
- (void)push;
- (void)pop;
@end

@interface NSWorkspace : NSObject
+ (NSWorkspace *)sharedWorkspace;
- (BOOL)openURL:(NSURL *)url;
@end

// Entry point helper
int NSApplicationMain(int argc, const char *argv[]);

#ifdef __cplusplus
}
#endif

#endif // APPKITSHIM_H
