//
//  Tweak.m
//  LiqTab — constructor entry point.
//
//  纯 Objective-C Runtime，无 Substrate / Logos 依赖。
//
//  与 DYYY 共存策略：
//   • 检测到 DYYY 时，完全不 hook AWENormalModeTabBar（DYYY 用 Logos hook 了
//     同一个 layoutSubviews，双方都改视图会造成布局死循环）。改用 CADisplayLink
//     低频轮询，只把玻璃视图叠加到 window 上，绝不改原生底栏。
//   • 检测到 DYYY 时也不 hook AWEABTestManager（DYYY 的「禁止下发配置」模式
//     会直接 return 截断调用链）。
//

#import "LiqTabInternal.h"
#import <objc/runtime.h>
#import <objc/message.h>

// DYYY 检测（在 LTTabBarMirror.m 中实现）
BOOL LTDYYYDetected(void);

// 内部 C 函数
void LTInstallNativeGlassHooks(void);
void LTForceNativeFlagsNow(void);
void LTProbeNativeGlassViews(void);

// 前向声明
static UIView *LTFindTabBarView(void);
static UIView *LTFindViewRecursively(UIView *v, Class cls, int depth);

#pragma mark - 轮询模式（DYYY 共存）

static CADisplayLink *sPollLink = nil;
static LTTabBarMirror *sOverlayMirror = nil;
static NSInteger sPollTick = 0;

@interface LTPollDriver : NSObject
- (void)tick:(CADisplayLink *)link;
@end

@implementation LTPollDriver
- (void)tick:(CADisplayLink *)link {
    if (![LTPrefs enabled]) return;
    if ([LTPrefs mode] == LTOperatingModeNative) return;
    // 每 6 帧检查一次（约 10Hz），避免频繁遍历视图树。
    if (++sPollTick % 6 != 0) return;

    UIView *bar = LTFindTabBarView();
    if (!bar) {
        if (sOverlayMirror) { [sOverlayMirror detach]; sOverlayMirror = nil; }
        return;
    }
    if (!sOverlayMirror) {
        sOverlayMirror = [[LTTabBarMirror alloc] initWithTabBar:bar];
        LTLog(@"DYYY 共存模式：已创建叠加玻璃视图");
    }
    [sOverlayMirror synchronize];
}
@end

static UIView *LTFindTabBarView(void) {
    static Class barClass = Nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ barClass = NSClassFromString(@"AWENormalModeTabBar"); });
    if (!barClass) return nil;

    NSArray *windows;
    if (@available(iOS 13.0, *)) {
        windows = [UIApplication sharedApplication].windows;
    } else {
        id kw = [[UIApplication sharedApplication] keyWindow];
        windows = kw ? @[kw] : @[];
    }
    for (UIWindow *w in windows) {
        UIView *found = LTFindViewRecursively(w, barClass, 0);
        if (found && !CGRectIsEmpty(found.bounds)) return found;
    }
    return nil;
}

static UIView *LTFindViewRecursively(UIView *v, Class cls, int depth) {
    if (!v || !cls || depth > 12) return nil;
    if ([v isKindOfClass:cls]) return v;
    for (UIView *s in v.subviews) {
        UIView *f = LTFindViewRecursively(s, cls, depth + 1);
        if (f) return f;
    }
    return nil;
}

static LTPollDriver *sPollDriver = nil;

static void LTStartPolling(void) {
    if (sPollLink) return;
    sPollDriver = [[LTPollDriver alloc] init];
    sPollLink = [CADisplayLink displayLinkWithTarget:sPollDriver selector:@selector(tick:)];
    sPollLink.preferredFramesPerSecond = 60;
    [sPollLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    LTLog(@"DYYY 共存模式：启动轮询");
}

#pragma mark - Swizzling 模式（无 DYYY）

static IMP sOriginalTabBarLayout = NULL;

static void LTTabBarLayoutHook(id self, SEL _cmd) {
    if (sOriginalTabBarLayout) ((void (*)(id, SEL))sOriginalTabBarLayout)(self, _cmd);

    UIView *bar = (UIView *)self;
    LTTabBarMirror *mirror = objc_getAssociatedObject(bar, &kLTMirrorKey);
    if (!mirror) {
        if (![LTPrefs enabled]) return;
        if ([LTPrefs mode] == LTOperatingModeNative) return;
        id buttons = nil;
        @try { buttons = [bar valueForKey:@"tabBarButtons"]; }
        @catch (NSException *e) { return; }
        if (![buttons isKindOfClass:[NSArray class]] || [(NSArray *)buttons count] == 0) return;
        mirror = [[LTTabBarMirror alloc] initWithTabBar:bar];
    }
    // synchronize 内部有 applying 防重入，避免布局抖动。
    [mirror synchronize];
}

static void LTInstallSwizzleHooks(void) {
    Class barClass = NSClassFromString(@"AWENormalModeTabBar");
    if (!barClass) {
        LTLog(@"AWENormalModeTabBar 类未找到，tweak 未激活");
        return;
    }
    SEL layout = @selector(layoutSubviews);
    Method m = class_getInstanceMethod(barClass, layout);
    if (!m) return;
    sOriginalTabBarLayout = method_getImplementation(m);
    IMP replacement = (IMP)LTTabBarLayoutHook;
    if (!class_replaceMethod(barClass, layout, replacement, method_getTypeEncoding(m))) {
        class_addMethod(barClass, layout, replacement, method_getTypeEncoding(m));
    }
    LTLog(@"已 hook AWENormalModeTabBar -layoutSubviews（独立模式）");
}

#pragma mark - 入口

__attribute__((constructor)) static void LTInitialize(void) {
    @autoreleasepool {
        BOOL dyyy = LTDYYYDetected();
        LTLog(@"加载完成（DYYY %@）", dyyy ? @"已检测到，进入共存模式" : @"未检测到，独立模式");

        if (dyyy) {
            // 共存模式：不 hook 任何抖音类，不碰 ABTest，纯叠加视图。
            LTStartPolling();
        } else {
            // 独立模式：安装 hook + 强制原生液态玻璃开关。
            if ([LTPrefs forceNativeFlags]) {
                LTInstallNativeGlassHooks();
                LTForceNativeFlagsNow();
            }
            LTProbeNativeGlassViews();
            if ([LTPrefs mode] != LTOperatingModeNative) {
                LTInstallSwizzleHooks();
            }
        }
    }
}
