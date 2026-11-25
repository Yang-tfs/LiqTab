//
//  LTNativeGlassEnabler.m
//  LiqTab — force Douyin's own built-in "liquid glass" implementation.
//
//  Two complementary paths:
//   1. ABTest flag injection (setAbTestData: swizzle + immediate read-modify-write).
//   2. Direct-call fallback: swizzle the tab-bar view lifecycle and call
//      enableFakeLiquidGlass / enableLiquidGlass / layoutLiquidGlass, then
//      verify the V_enable* ivars actually flipped. Nothing is written by hand
//      into those ivars — doing so would bypass Douyin's own config setup.
//
//  Everything is runtime-only (NSClassFromString / NSSelectorFromString),
//  so the dylib has no hard link to any private Douyin symbol.
//

#import "LiqTabInternal.h"
#import <objc/runtime.h>
#import <objc/message.h>

static BOOL sInjecting = NO;
static BOOL sABTestHooksInstalled = NO;
static BOOL sDirectHooksInstalled = NO;
static BOOL sNativeGlassActive = NO;
static BOOL sInNativeCall = NO;

BOOL LTNativeGlassActive(void) { return sNativeGlassActive; }

static void LTInjectFlagsIntoDictionary(NSMutableDictionary *d) {
    if (!d) return;
    d[@"aiDouyinEnableLiquidGlass"] = @YES;
    d[@"aiDouyinEnableFakeLiquidGlass"] = @YES;
    d[@"aiDouyinEnableLiquidGlassHighDynamic"] = @YES;
    d[@"aiDouyinEnableHighDynamicAnimationOnLiquidGlass"] = @YES;
}

#pragma mark - Path 1: ABTest injection

static IMP sOriginalSetABTestData = NULL;

static void LTSetABTestDataHook(id self, SEL _cmd, NSDictionary *data) {
    if (!sOriginalSetABTestData) return;
    if (sInjecting) {
        ((void (*)(id, SEL, id))sOriginalSetABTestData)(self, _cmd, data);
        return;
    }
    NSMutableDictionary *patched = [data isKindOfClass:[NSDictionary class]]
        ? [data mutableCopy] : [NSMutableDictionary dictionary];
    LTInjectFlagsIntoDictionary(patched);
    sInjecting = YES;
    ((void (*)(id, SEL, id))sOriginalSetABTestData)(self, _cmd, [patched copy]);
    sInjecting = NO;
}

void LTInstallNativeGlassHooks(void) {
    if (sABTestHooksInstalled) return;
    Class cls = NSClassFromString(@"AWEABTestManager");
    if (!cls) { LTLog(@"AWEABTestManager 不存在，跳过 ABTest 注入"); return; }
    SEL sel = NSSelectorFromString(@"setAbTestData:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { LTLog(@"-[AWEABTestManager setAbTestData:] 不存在"); return; }
    sOriginalSetABTestData = method_getImplementation(m);
    IMP old = class_replaceMethod(cls, sel, (IMP)LTSetABTestDataHook, method_getTypeEncoding(m));
    if (!old) class_addMethod(cls, sel, (IMP)LTSetABTestDataHook, method_getTypeEncoding(m));
    sABTestHooksInstalled = YES;
    LTLog(@"已安装 ABTest 液态玻璃开关注入");
}

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
    LTLog(@"已立即写入 4 个液态玻璃 ABTest 开关");
}

#pragma mark - Path 2: direct-call + ivar verification

static BOOL LTIvarIsYES(id obj, NSString *name) {
    if (!obj) return NO;
    Class c = object_getClass(obj);
    while (c) {
        Ivar iv = class_getInstanceVariable(c, name.UTF8String);
        if (iv) {
            // BOOL ('B'/'c') 是标量，不能用 object_getIvar（它会当对象指针读）。
            const char *type = ivar_getTypeEncoding(iv);
            ptrdiff_t off = ivar_getOffset(iv);
            if (!type || off < 0) return NO;
            unsigned char *addr = (unsigned char *)(__bridge void *)obj + off;
            if (type[0] == 'B' || type[0] == 'c') return *addr != 0;
            // 万一它是 NSNumber 对象 ivar
            id value = object_getIvar(obj, iv);
            return [value isKindOfClass:[NSNumber class]] && [value boolValue];
        }
        c = class_getSuperclass(c);
    }
    return NO;
}

static void LTSend(id obj, NSString *selName) {
    SEL s = NSSelectorFromString(selName);
    if (![obj respondsToSelector:s]) return;
    @try {
        ((void (*)(id, SEL))objc_msgSend)(obj, s);
        LTLog(@"已调用 %@ -> %@", NSStringFromClass([obj class]), selName);
    } @catch (NSException *e) {
        LTLog(@"调用 %@ 异常: %@", selName, e.reason);
    }
}

static BOOL LTTryForceOnView(id view) {
    if (!view || sInNativeCall) return NO;
    sInNativeCall = YES;
    BOOL didSomething = NO;

    // Prefer the fake (low-version) implementation; only fall back to the
    // real one if the fake selector is unavailable on this build.
    BOOL hasFake = [view respondsToSelector:NSSelectorFromString(@"enableFakeLiquidGlass")];
    if (hasFake) {
        LTSend(view, @"enableFakeLiquidGlass");
        didSomething = YES;
    } else {
        LTSend(view, @"enableLiquidGlass");
        didSomething = YES;
    }
    LTSend(view, @"layoutLiquidGlass");
    LTSend(view, @"layoutLiquidUI");

    BOOL fakeOn = LTIvarIsYES(view, @"_enableFakeLiquidGlass") ||
                  LTIvarIsYES(view, @"V_enableFakeLiquidGlass") ||
                  LTIvarIsYES(view, @"enableFakeLiquidGlass");
    BOOL realOn = LTIvarIsYES(view, @"_enableLiquidGlass") ||
                  LTIvarIsYES(view, @"V_enableLiquidGlass") ||
                  LTIvarIsYES(view, @"enableLiquidGlass");
    if (fakeOn || realOn) {
        sNativeGlassActive = YES;
        LTLog(@"抖音原生液态玻璃已生效: fake=%@ real=%@", fakeOn ? @"YES" : @"NO", realOn ? @"YES" : @"NO");
    }
    sInNativeCall = NO;
    return didSomething;
}

static void LTProbeSubviewsRecursively(UIView *v, NSArray<NSString *> *classNames, int depth) {
    if (!v || depth > 6) return;
    NSString *cn = NSStringFromClass([v class]);
    for (NSString *wanted in classNames) {
        if ([cn containsString:wanted]) { LTTryForceOnView(v); break; }
    }
    for (UIView *sub in v.subviews) LTProbeSubviewsRecursively(sub, classNames, depth + 1);
}

// C IMPs used as method replacements. They call the captured original first.
static IMP sOriginalFullAbilityLayout = NULL;
static IMP sOriginalTabBarDidMoveToWindow = NULL;

static void LTFullAbilityLayoutHook(id self, SEL _cmd) {
    if (sOriginalFullAbilityLayout) ((void (*)(id, SEL))sOriginalFullAbilityLayout)(self, _cmd);
    if (!sNativeGlassActive) LTTryForceOnView(self);
}

static void LTTabBarDidMoveToWindowHook(id self, SEL _cmd) {
    if (sOriginalTabBarDidMoveToWindow) ((void (*)(id, SEL))sOriginalTabBarDidMoveToWindow)(self, _cmd);
    if (sNativeGlassActive || sInNativeCall) return;
    NSArray *names = @[@"AWELGNormalModeTabBarFullAbilityView",
                       @"AWENormalModeTabBarBlurView",
                       @"AWELGNormalModeTabBarGradientView"];
    LTProbeSubviewsRecursively((UIView *)self, names, 0);
}

void LTInstallNativeDirectCallHooks(void) {
    if (sDirectHooksInstalled) return;
    sDirectHooksInstalled = YES;

    Class full = NSClassFromString(@"AWELGNormalModeTabBarFullAbilityView");
    if (full) {
        SEL sel = NSSelectorFromString(@"layoutSubviews");
        Method m = class_getInstanceMethod(full, sel);
        if (m) {
            sOriginalFullAbilityLayout = method_getImplementation(m);
            class_replaceMethod(full, sel, (IMP)LTFullAbilityLayoutHook, method_getTypeEncoding(m));
            LTLog(@"已 hook AWELGNormalModeTabBarFullAbilityView layoutSubviews");
        }
    }

    Class tabBar = NSClassFromString(@"AWENormalModeTabBar");
    if (tabBar) {
        SEL sel = NSSelectorFromString(@"didMoveToWindow");
        Method m = class_getInstanceMethod(tabBar, sel);
        if (m) {
            sOriginalTabBarDidMoveToWindow = method_getImplementation(m);
            class_replaceMethod(tabBar, sel, (IMP)LTTabBarDidMoveToWindowHook, method_getTypeEncoding(m));
            LTLog(@"已 hook AWENormalModeTabBar didMoveToWindow");
        }
    }
}

void LTForceNativeGlassSweep(void) {
    if (sNativeGlassActive || sInNativeCall) return;
    Class barClass = NSClassFromString(@"AWENormalModeTabBar");
    if (!barClass) return;
    NSArray *windows;
    if (@available(iOS 13.0, *)) windows = [UIApplication sharedApplication].windows;
    else { id kw = [[UIApplication sharedApplication] keyWindow]; windows = kw ? @[kw] : @[]; }
    NSArray *names = @[@"AWELGNormalModeTabBarFullAbilityView",
                       @"AWENormalModeTabBarBlurView",
                       @"AWELGNormalModeTabBarGradientView"];
    for (UIWindow *w in windows) {
        if (w.hidden || w.alpha < 0.01) continue;
        LTProbeSubviewsRecursively(w, names, 0);
        if (sNativeGlassActive) break;
    }
}

void LTProbeNativeGlassViews(void) {
    NSArray *names = @[@"AWELGNormalModeTabBarFullAbilityView",
                       @"AWENormalModeTabBarBlurView",
                       @"AWELGNormalModeTabBarGradientView",
                       @"HomepageLiquidGlass",
                       @"AWEAdLiquidGlassNavibar"];
    for (NSString *name in names) {
        Class c = NSClassFromString(name);
        if (!c) continue;
        LTLog(@"发现抖音原生玻璃类: %@", name);
        for (NSString *sn in @[@"enableLiquidGlass", @"enableFakeLiquidGlass", @"layoutLiquidGlass", @"layoutLiquidUI"]) {
            if (class_getInstanceMethod(c, NSSelectorFromString(sn))) {
                LTLog(@"  %@ 实现 %@", name, sn);
            }
        }
    }
}
