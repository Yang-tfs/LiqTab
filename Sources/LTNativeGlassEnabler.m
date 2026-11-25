//
//  LTNativeGlassEnabler.m
//  LiqTab — force Douyin's own built-in "fake liquid glass" flags.
//
//  Douyin 41.2.0 ships (but does not enable by default on iOS 16) ABTest keys:
//      aiDouyinEnableLiquidGlass
//      aiDouyinEnableFakeLiquidGlass
//  alongside classes AWELGNormalModeTabBarFullAbilityView /
//  AWENormalModeTabBarBlurView and selectors enableLiquidGlass /
//  enableFakeLiquidGlass / layoutLiquidGlass.
//
//  Rather than using Logos, we swizzle AWEABTestManager's setAbTestData: with
//  plain Objective-C runtime APIs so this dylib works with ANY injection
//  method (TrollFools, azule, Sideloadly tweak injection, etc.).
//

#import "LiqTabInternal.h"
#import <objc/runtime.h>
#import <objc/message.h>

static BOOL sInjecting = NO;
static BOOL sInstalled = NO;

static void LTInjectFlagsIntoDictionary(NSMutableDictionary *d) {
    if (!d) return;
    d[@"aiDouyinEnableLiquidGlass"] = @YES;
    d[@"aiDouyinEnableFakeLiquidGlass"] = @YES;
    d[@"aiDouyinEnableLiquidGlassHighDynamic"] = @YES;
    d[@"aiDouyinEnableHighDynamicAnimationOnLiquidGlass"] = @YES;
}

// Replacement for -[AWEABTestManager setAbTestData:].
// The original IMP is passed in via a global because C functions used as IMPs
// cannot capture state.
static IMP sOriginalSetABTestData = NULL;

static void LTSetABTestDataHook(id self, SEL _cmd, NSDictionary *data) {
    if (!sOriginalSetABTestData) {
        // Should not happen, but be safe.
        return;
    }
    if (sInjecting) {
        ((void (*)(id, SEL, id))sOriginalSetABTestData)(self, _cmd, data);
        return;
    }
    NSMutableDictionary *patched = nil;
    if ([data isKindOfClass:[NSDictionary class]]) {
        patched = [data mutableCopy];
        LTInjectFlagsIntoDictionary(patched);
    } else {
        patched = [NSMutableDictionary dictionary];
        LTInjectFlagsIntoDictionary(patched);
    }
    sInjecting = YES;
    ((void (*)(id, SEL, id))sOriginalSetABTestData)(self, _cmd, [patched copy]);
    sInjecting = NO;
}

void LTInstallNativeGlassHooks(void) {
    if (sInstalled) return;
    Class cls = NSClassFromString(@"AWEABTestManager");
    if (!cls) {
        LTLog(@"AWEABTestManager not found — skipping native flag injection");
        return;
    }
    SEL sel = NSSelectorFromString(@"setAbTestData:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        LTLog(@"-[AWEABTestManager setAbTestData:] not found — skipping");
        return;
    }
    sOriginalSetABTestData = method_getImplementation(m);
    IMP replacement = (IMP)LTSetABTestDataHook;
    IMP old = class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(m));
    if (!old) {
        class_addMethod(cls, sel, replacement, method_getTypeEncoding(m));
    }
    sInstalled = YES;
    LTLog(@"Installed ABTest flag injection hook");
}

// Push the flags at runtime even if the ABTest manager was already populated
// before our dylib loaded (e.g. injected very late).
void LTForceNativeFlagsNow(void) {
    Class cls = NSClassFromString(@"AWEABTestManager");
    if (!cls) return;
    id manager = nil;
    SEL shared = NSSelectorFromString(@"sharedManager");
    if ([cls respondsToSelector:shared]) {
        manager = ((id (*)(id, SEL))objc_msgSend)(cls, shared);
    }
    if (!manager) return;
    SEL getter = NSSelectorFromString(@"abTestData");
    NSDictionary *data = nil;
    if ([manager respondsToSelector:getter]) {
        data = ((id (*)(id, SEL))objc_msgSend)(manager, getter);
    }
    NSMutableDictionary *patched = [data isKindOfClass:[NSDictionary class]]
        ? [data mutableCopy] : [NSMutableDictionary dictionary];
    LTInjectFlagsIntoDictionary(patched);

    sInjecting = YES;
    SEL setter = NSSelectorFromString(@"setAbTestData:");
    if ([manager respondsToSelector:setter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(manager, setter, [patched copy]);
    }
    sInjecting = NO;
}

// Optionally call Douyin's own liquid-glass methods on the full-ability view.
// Guarded with respondsToSelector: so it is a no-op if Douyin changes.
void LTProbeNativeGlassViews(void) {
    NSArray *names = @[
        @"AWELGNormalModeTabBarFullAbilityView",
        @"AWENormalModeTabBarBlurView",
        @"AWELGNormalModeTabBarGradientView"
    ];
    for (NSString *name in names) {
        Class c = NSClassFromString(name);
        if (!c) continue;
        LTLog(@"Found native glass class: %@", name);
        NSArray *sels = @[@"enableLiquidGlass", @"enableFakeLiquidGlass", @"layoutLiquidGlass"];
        for (NSString *sn in sels) {
            SEL s = NSSelectorFromString(sn);
            if (class_getInstanceMethod(c, s)) {
                LTLog(@"  class %@ responds to %@", name, sn);
            }
        }
    }
}
