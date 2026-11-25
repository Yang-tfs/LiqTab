//
//  Tweak.m
//  LiqTab — constructor entry point.
//
//  No Logos / Substrate dependency: all hooks are installed with the Objective-C
//  runtime. Works when injected as a dylib into the decrypted Douyin app.
//

#import "LiqTabInternal.h"
#import <objc/runtime.h>
#import <dlfcn.h>

// Forward declarations of our internal C functions.
void LTInstallNativeGlassHooks(void);
void LTForceNativeFlagsNow(void);
void LTProbeNativeGlassViews(void);

#pragma mark - Swizzled IMPs

// Our replacement for -[AWENormalModeTabBar layoutSubviews].
// The original IMP is stored per-class because different Douyin versions may
// subclass AWENormalModeTabBar.
static IMP sOriginalTabBarLayout = NULL;
static Class sTabBarClass = Nil;

static void LTTabBarLayoutHook(id self, SEL _cmd) {
    if (sOriginalTabBarLayout) ((void (*)(id, SEL))sOriginalTabBarLayout)(self, _cmd);

    UIView *bar = (UIView *)self;
    LTTabBarMirror *mirror = objc_getAssociatedObject(bar, &kLTMirrorKey);
    if (!mirror) {
        // Only create the mirror when the tweak is enabled and the bar appears
        // to be the main bottom bar (has tabBarButtons).
        if (![LTPrefs enabled]) return;
        if ([LTPrefs mode] == LTOperatingModeNative) return;
        id buttons = nil;
        @try { buttons = [bar valueForKey:@"tabBarButtons"]; }
        @catch (NSException *e) { return; }
        if (![buttons isKindOfClass:[NSArray class]] || [(NSArray *)buttons count] == 0) return;
        mirror = [[LTTabBarMirror alloc] initWithTabBar:bar];
    }
    [mirror synchronize];
}

// Replacement for -[UIViewController viewDidLayoutSubviews] on Douyin's root
// tab bar controller. We only re-sync our existing mirror; we never create one
// here. This keeps the hook surface small.
static IMP sOriginalControllerLayout = NULL;
static Class sControllerClass = Nil;

static void LTControllerLayoutHook(id self, SEL _cmd) {
    if (sOriginalControllerLayout) ((void (*)(id, SEL))sOriginalControllerLayout)(self, _cmd);
    UIView *bar = ((UIViewController *)self).viewIfLoaded;
    if (!bar) return;
    // Find any mirror attached to a descendant tab bar.
    LTTabBarMirror *mirror = objc_getAssociatedObject(bar, &kLTMirrorKey);
    if (mirror) { [mirror synchronize]; return; }
    for (UIView *v in bar.subviews) {
        mirror = objc_getAssociatedObject(v, &kLTMirrorKey);
        if (mirror) { [mirror synchronize]; return; }
    }
}

#pragma mark - Hook installation

static void LTInstallHooks(void) {
    // Hook AWENormalModeTabBar (the class DYKiller hooks; verified present in
    // Douyin 41.2.0's AwemeCore binary).
    sTabBarClass = NSClassFromString(@"AWENormalModeTabBar");
    if (!sTabBarClass) {
        LTLog(@"AWENormalModeTabBar class not found — tweak inactive");
        return;
    }
    SEL layout = @selector(layoutSubviews);
    Method m = class_getInstanceMethod(sTabBarClass, layout);
    if (m) {
        sOriginalTabBarLayout = method_getImplementation(m);
        IMP replacement = (IMP)LTTabBarLayoutHook;
        if (!class_replaceMethod(sTabBarClass, layout, replacement, method_getTypeEncoding(m))) {
            class_addMethod(sTabBarClass, layout, replacement, method_getTypeEncoding(m));
        }
        LTLog(@"Hooked AWENormalModeTabBar -layoutSubviews");
    }

    // Force Douyin's own fake-liquid-glass ABTest flags (safe, key-scoped).
    if ([LTPrefs forceNativeFlags]) {
        LTInstallNativeGlassHooks();
        LTForceNativeFlagsNow();
    }
    LTProbeNativeGlassViews();

    // When our mode is Native-only, we are done: no custom rendering.
    if ([LTPrefs mode] == LTOperatingModeNative) return;

    // Optional: hook the root tab bar controller to keep the mirror synced.
    // We try the known Douyin controller class name, then fall back to
    // UITabBarController. Hooking UITabBarController globally is harmless
    // because we only re-sync an already-installed mirror.
    sControllerClass = NSClassFromString(@"DUXTabBarContainerController");
    if (!sControllerClass) sControllerClass = [UITabBarController class];
    SEL vdl = @selector(viewDidLayoutSubviews);
    Method cm = class_getInstanceMethod(sControllerClass, vdl);
    if (cm) {
        sOriginalControllerLayout = method_getImplementation(cm);
        IMP replacement = (IMP)LTControllerLayoutHook;
        if (!class_replaceMethod(sControllerClass, vdl, replacement, method_getTypeEncoding(cm))) {
            class_addMethod(sControllerClass, vdl, replacement, method_getTypeEncoding(cm));
        }
        LTLog(@"Hooked %@ -viewDidLayoutSubviews", NSStringFromClass(sControllerClass));
    }
}

#pragma mark - Constructor

__attribute__((constructor)) static void LTInitialize(void) {
    @autoreleasepool {
        LTLog(@"Loaded (Douyin 41.2.0 / iOS 16.3.1 target)");
        LTInstallHooks();
    }
}
