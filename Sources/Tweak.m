//
//  Tweak.m
//  LiqTab — 入口。纯 Objective-C Runtime，无 Substrate / Logos 依赖。
//
//  设计（v2）：统一使用「轮询叠加」模式，不 hook 抖音任何方法。
//    • 不 hook AWENormalModeTabBar -layoutSubviews
//      → 不会和 DYYY 的 Logos hook 互相递归，也不会布局抖动死循环。
//    • 不隐藏、不重排原生按钮
//      → 原生图标/文字/角标全部保留，玻璃只做它们的背景层。
//    • 低频轮询（~10Hz）跟踪底栏位置，兼容 DYYY 修改底栏高度/隐藏等操作。
//
//  可选：未检测到 DYYY 时，仍可强制开启抖音自带的 fake liquid glass 开关
//  （默认关闭，避免和 DYYY 的 ABTest 管理冲突）。
//

#import "LiqTabInternal.h"
#import <objc/runtime.h>
#import <objc/message.h>

BOOL LTDYYYDetected(void);
void LTInstallNativeGlassHooks(void);
void LTForceNativeFlagsNow(void);
void LTProbeNativeGlassViews(void);
void LTInstallSettingsHooks(void);

static UIView *LTFindTabBarView(void);
static UIView *LTFindViewRecursively(UIView *v, Class cls, int depth);

#pragma mark - 轮询

static CADisplayLink *sPollLink = nil;
static LTTabBarMirror *sMirror = nil;
static NSInteger sTick = 0;
static BOOL sActivated = NO;

static UIView *LTFindViewRecursively(UIView *v, Class cls, int depth) {
    if (!v || !cls || depth > 12) return nil;
    if ([v isKindOfClass:cls]) return v;
    for (UIView *s in v.subviews) {
        UIView *f = LTFindViewRecursively(s, cls, depth + 1);
        if (f) return f;
    }
    return nil;
}

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
        if (w.hidden || w.alpha < 0.01) continue;
        UIView *found = LTFindViewRecursively(w, barClass, 0);
        if (found && !CGRectIsEmpty(found.bounds) && !found.hidden && found.alpha > 0.01) {
            return found;
        }
    }
    return nil;
}

@interface LTPollDriver : NSObject
- (void)tick:(CADisplayLink *)link;
@end

@implementation LTPollDriver
- (void)tick:(CADisplayLink *)link {
    if (![LTPrefs enabled]) {
        if (sMirror) { [sMirror detach]; sMirror = nil; }
        return;
    }
    if ([LTPrefs mode] == LTOperatingModeNative) return;
    if (++sTick % 6 != 0) return;   // ≈10Hz，避免频繁遍历视图树

    UIView *bar = LTFindTabBarView();

    // 底栏消失（全屏/隐藏）时把玻璃也收起来；底栏换了实例则重建。
    if (sMirror && ![sMirror isAttachedToBar:bar]) {
        [sMirror detach];
        sMirror = nil;
    }
    if (!bar) return;

    if (!sMirror) {
        sMirror = [[LTTabBarMirror alloc] initWithTabBar:bar];
        LTLog(@"已挂载玻璃背景到 %@", NSStringFromClass([bar class]));
    }
    [sMirror synchronize];
}
@end

static LTPollDriver *sPollDriver = nil;

static void LTStartPolling(void) {
    if (sPollLink) return;
    sPollDriver = [[LTPollDriver alloc] init];
    sPollLink = [CADisplayLink displayLinkWithTarget:sPollDriver selector:@selector(tick:)];
    sPollLink.preferredFramesPerSecond = 60;
    [sPollLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    LTLog(@"轮询已启动");
}

#pragma mark - 启动

static void LTActivate(void) {
    if (sActivated) return;
    sActivated = YES;

    BOOL dyyy = LTDYYYDetected();
    LTLog(@"激活：DYYY %@", dyyy ? @"已检测到" : @"未检测到");

    // 仅在明确没有 DYYY 时才考虑动 ABTest（有 DYYY 时它的拦截会破坏链路）。
    if (!dyyy && [LTPrefs forceNativeFlags] && [LTPrefs mode] == LTOperatingModeNative) {
        LTInstallNativeGlassHooks();
        LTForceNativeFlagsNow();
        LTProbeNativeGlassViews();
    }

    // 安装设置入口 hook（与 DYYY 共用 hook 点，但只改返回数组，不会递归）。
    LTInstallSettingsHooks();

    LTStartPolling();
}

__attribute__((constructor)) static void LTInitialize(void) {
    @autoreleasepool {
        LTLog(@"加载（等待 App 启动完成后激活）");
        // 延迟到 App 启动后：此时所有注入的 dylib（含 DYYY）都已注册类。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LTActivate();
        });
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *n) {
            LTActivate();
        }];
    }
}
