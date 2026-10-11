// ContainerViewController.m - Main execution harness hosting guest macOS binaries on iPadOS.

#import "ContainerViewController.h"
#import "../AppKitShim/MetalPresenter.h"
#import "../AppKitShim/AppKitShim.h"
#import "../DyldInterpose/DyldInterpose.h"
#import "../MachOPatcher/MachOPatcher.h"
#import "JITHelper.h"

#include <pthread.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

#if TARGET_OS_IPHONE || TARGET_OS_IOS
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

@interface ContainerViewController () <UIDocumentPickerDelegate>
@property (nonatomic, strong) MetalPresenter *presenter;
@property (nonatomic, strong) UIView *hudView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *fpsLabel;
@property (nonatomic, strong) NSTimer *hudTimer;
@end

typedef struct {
    char binaryPath[1024];
    char patchedPath[1024];
    uint64_t entryoff;
    __unsafe_unretained ContainerViewController *controller;
} GuestLaunchContext;

static pthread_t s_guestThread = NULL;
static volatile BOOL s_guestRunning = NO;
static volatile int s_lastGuestExitCode = 0;

static void guest_exit_interception_handler(int status) {
    NSLog(@"[HostHarness] Guest binary intercepted exit(%d). Stopping guest execution thread safely.", status);
    s_lastGuestExitCode = status;
    s_guestRunning = NO;
}

static void *guest_thread_entry(void *arg) {
    GuestLaunchContext *ctx = (GuestLaunchContext *)arg;
    @autoreleasepool {
        // 1. Initialize JIT runtime
        int jitReady = jit_init_environment();
        NSLog(@"[HostHarness] JIT initialization status: %d", jitReady);

        // 2. Interpose Dyld executable path and exit() so guest operates seamlessly
        di_set_guest_executable_path(ctx->binaryPath);
        di_enable_exit_interposing(guest_exit_interception_handler);
        NSLog(@"[HostHarness] Configured guest executable path: %s", ctx->binaryPath);

        // 3. Set container sandbox environment variables
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = [paths firstObject];
        NSString *tmpDir = NSTemporaryDirectory();
        setenv("HOME", [docDir UTF8String], 1);
        setenv("TMPDIR", [tmpDir UTF8String], 1);
        setenv("LC_CONTAINER_DIR", [docDir UTF8String], 1);

        // 4. Load the patched guest image via dlopen
        void *handle = dlopen(ctx->patchedPath, RTLD_NOW | RTLD_GLOBAL);
        if (!handle) {
            NSLog(@"[HostHarness] Failed to dlopen guest binary: %s", dlerror());
            s_guestRunning = NO;
            free(ctx);
            return NULL;
        }

        // 5. Resolve entry point
        typedef int (*GuestMainFunc)(int argc, char **argv, char **envp, char **apple);
        GuestMainFunc entryFunc = NULL;

        if (ctx->entryoff > 0) {
            // Find base address of loaded guest image
            uint32_t count = _dyld_image_count();
            for (uint32_t i = 0; i < count; i++) {
                const char *imgName = _dyld_get_image_name(i);
                if (imgName && strstr(imgName, ctx->patchedPath)) {
                    const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
                    entryFunc = (GuestMainFunc)((uintptr_t)hdr + ctx->entryoff);
                    break;
                }
            }
        }

        if (!entryFunc) {
            entryFunc = (GuestMainFunc)dlsym(handle, "main");
        }

        if (!entryFunc) {
            NSLog(@"[HostHarness] Could not resolve guest entry point.");
            s_guestRunning = NO;
            free(ctx);
            return NULL;
        }

        NSLog(@"[HostHarness] Dispatching guest main entry point at %p", entryFunc);

        char *argv[] = { ctx->binaryPath, NULL };
        char *envp[] = { "USER=mobile", "SHELL=/bin/sh", NULL };
        char *apple[] = { ctx->binaryPath, NULL };

        int exitCode = entryFunc(1, argv, envp, apple);
        NSLog(@"[HostHarness] Guest binary returned exit code: %d", exitCode);
        s_lastGuestExitCode = exitCode;

        s_guestRunning = NO;
        free(ctx);
    }
    return NULL;
}

@implementation ContainerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    // Initialize MetalPresenter canvas
    _presenter = [[MetalPresenter alloc] initWithFrame:self.view.bounds];
    _presenter.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_presenter];
    [_presenter startPresentationLoop];

    // Build translucent HUD overlay
    [self setupHUD];

    // Start status update timer
    _hudTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(updateHUDMetrics) userInfo:nil repeats:YES];

    // Check for auto-launch bundled binary
    NSString *bundledApp = [[NSBundle mainBundle] pathForResource:@"guest_sample" ofType:nil];
    if (bundledApp && [[NSFileManager defaultManager] fileExistsAtPath:bundledApp]) {
        [self loadAndExecuteGuestBinaryAtPath:bundledApp];
    }
}

- (void)setupHUD {
    CGFloat hudWidth = self.view.bounds.size.width - 40;
    _hudView = [[UIView alloc] initWithFrame:CGRectMake(20, 40, hudWidth, 60)];
    _hudView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.8];
    _hudView.layer.cornerRadius = 12;
    _hudView.layer.masksToBounds = YES;
    _hudView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 10, hudWidth - 260, 20)];
    _statusLabel.textColor = [UIColor whiteColor];
    _statusLabel.font = [UIFont boldSystemFontOfSize:14];
    _statusLabel.text = @"Container Ready";
    [_hudView addSubview:_statusLabel];

    _fpsLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 32, hudWidth - 260, 18)];
    _fpsLabel.textColor = [UIColor lightGrayColor];
    _fpsLabel.font = [UIFont systemFontOfSize:12];
    _fpsLabel.text = @"FPS: 0 | JIT: Checking...";
    [_hudView addSubview:_fpsLabel];

    // Button: Select Binary
    UIButton *selectBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    selectBtn.frame = CGRectMake(hudWidth - 240, 12, 110, 36);
    [selectBtn setTitle:@"Load Binary" forState:UIControlStateNormal];
    [selectBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    selectBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    selectBtn.layer.cornerRadius = 8;
    [selectBtn addTarget:self action:@selector(presentDocumentPicker) forControlEvents:UIControlEventTouchUpInside];
    [_hudView addSubview:selectBtn];

    // Button: Terminate / Restart
    UIButton *termBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    termBtn.frame = CGRectMake(hudWidth - 120, 12, 105, 36);
    [termBtn setTitle:@"Terminate" forState:UIControlStateNormal];
    [termBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    termBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    termBtn.layer.cornerRadius = 8;
    [termBtn addTarget:self action:@selector(terminateGuestBinary) forControlEvents:UIControlEventTouchUpInside];
    [_hudView addSubview:termBtn];

    [self.view addSubview:_hudView];

    // 3-finger tap gesture to toggle HUD
    UITapGestureRecognizer *tripleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleHUD)];
    tripleTap.numberOfTouchesRequired = 3;
    [self.view addGestureRecognizer:tripleTap];
}

- (void)updateHUDMetrics {
    NSUInteger fps = _presenter.currentFPS;
    BOOL jit = jit_is_available();
    _fpsLabel.text = [NSString stringWithFormat:@"FPS: %lu | JIT: %@", (unsigned long)fps, jit ? @"Active" : @"Inactive"];
}

- (void)toggleHUD {
    [UIView animateWithDuration:0.3 animations:^{
        self.hudView.alpha = (self.hudView.alpha > 0.1) ? 0.0 : 1.0;
    }];
}

- (void)presentDocumentPicker {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.item", @"public.data", @"public.executable"]
                       inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = [urls firstObject];
    if (!url) return;

    BOOL hasAccess = [url startAccessingSecurityScopedResource];
    NSString *fileName = [url lastPathComponent];
    NSString *destDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *destPath = [destDir stringByAppendingPathComponent:fileName];

    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:destPath]) {
        [fm removeItemAtPath:destPath error:nil];
    }
    NSError *copyError = nil;
    [fm copyItemAtPath:url.path toPath:destPath error:&copyError];

    if (hasAccess) {
        [url stopAccessingSecurityScopedResource];
    }

    NSString *binaryToExecute = destPath;
    if (copyError || ![fm fileExistsAtPath:destPath]) {
        binaryToExecute = url.path;
    }

    [self loadAndExecuteGuestBinaryAtPath:binaryToExecute];
}

- (BOOL)loadAndExecuteGuestBinaryAtPath:(NSString *)path {
    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSLog(@"[HostHarness] Specified binary does not exist: %@", path);
        return NO;
    }

    [self terminateGuestBinary];

    _currentBinaryPath = [path copy];
    _statusLabel.text = [NSString stringWithFormat:@"Running: %@", [path lastPathComponent]];

    // Create target patched dylib path in tmp
    NSString *patchedPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"patched_%@", [path lastPathComponent]]];

    // Prepare MachOPatcher options
    mp_dylib_remap remaps[] = {
        {"/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", "@rpath/AppKitShim.framework/AppKitShim"}
    };

    mp_options opts;
    mp_default_options(&opts);
    opts.remaps = remaps;
    opts.remap_count = 1;
    opts.install_name = [patchedPath UTF8String];
    opts.strip_code_signature = 1; // Mandatory: strip old macOS signature so modified binary is accepted by dyld

    mp_report report;
    memset(&report, 0, sizeof(report));

    NSLog(@"[HostHarness] Patching Mach-O binary: %@ -> %@", path, patchedPath);
    mp_status status = mp_patch_file([path UTF8String], [patchedPath UTF8String], &opts, &report);
    if (status != MP_OK) {
        NSLog(@"[HostHarness] MachOPatcher failed with code %d: %s", status, mp_strerror(status));
        // If already patched or failed, fallback to path
        patchedPath = path;
    }

    // Allocate thread launch context
    GuestLaunchContext *ctx = (GuestLaunchContext *)calloc(1, sizeof(GuestLaunchContext));
    strncpy(ctx->binaryPath, [path UTF8String], sizeof(ctx->binaryPath) - 1);
    strncpy(ctx->patchedPath, [patchedPath UTF8String], sizeof(ctx->patchedPath) - 1);
    ctx->entryoff = report.entryoff;
    ctx->controller = self;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 16 * 1024 * 1024); // 16 MB execution stack

    s_guestRunning = YES;
    int err = pthread_create(&s_guestThread, &attr, guest_thread_entry, ctx);
    pthread_attr_destroy(&attr);

    if (err != 0) {
        NSLog(@"[HostHarness] Failed to spawn guest thread: %d", err);
        s_guestRunning = NO;
        free(ctx);
        return NO;
    }

    return YES;
}

- (void)terminateGuestBinary {
    if (s_guestRunning) {
        NSLog(@"[HostHarness] Requesting guest shutdown...");
        s_guestRunning = NO;
        [NSApp stop:nil];
        [NSApp terminate:nil];
        s_guestThread = NULL;
        _statusLabel.text = @"Guest Terminated";
    }
}

- (BOOL)isGuestRunning {
    return s_guestRunning;
}

@end

#else

// Non-iOS host mock implementation
@implementation ContainerViewController
- (BOOL)loadAndExecuteGuestBinaryAtPath:(NSString *)path { (void)path; return YES; }
- (void)terminateGuestBinary {}
- (void)toggleHUD {}
- (void)presentDocumentPicker {}
- (BOOL)isGuestRunning { return NO; }
@end

#endif
