//
//  LTTabBarMirror.m
//  LiqTab — 把抖音底栏镜像/包裹成悬浮玻璃胶囊。
//
//  两种模式：
//   1. 独立模式（未检测到 DYYY）：自建胶囊 + 镜像按钮 + 隐藏原生底栏，和 DYKiller 一致。
//   2. DYYY 共存模式：把玻璃作为原生底栏的「背景层」插入（index 0），
//      原生按钮浮在玻璃之上 —— 只换底，不动按钮，避免和 DYYY 抢控制权。
//

#import "LiqTabInternal.h"
#import <objc/runtime.h>
#import <objc/message.h>

char kLTMirrorKey;
static char kLTBarPreparedKey;
static char kLTGlassKey;

#pragma mark - 反射小工具

static id LTGet(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (NSException *e) { return nil; }
}

static BOOL LTHas(id obj, SEL sel) { return obj && [obj respondsToSelector:sel]; }

static NSString *LTTitleOfButton(id button) {
    NSString *s = LTGet(LTGet(LTGet(button, @"innerView"), @"label"), @"text");
    if (![s isKindOfClass:[NSString class]] || s.length == 0) s = LTGet(button, @"currentTitleText");
    if (![s isKindOfClass:[NSString class]] || s.length == 0) s = [button accessibilityLabel];
    return [s isKindOfClass:[NSString class]] ? s : nil;
}

static NSInteger LTTypeOfButton(id button) {
    id v = LTGet(button, @"type");
    return [v isKindOfClass:[NSNumber class]] ? [v integerValue] : -1;
}

static NSInteger LTIndexForButton(id button) {
    id v = LTGet(button, @"validIndex");
    return [v isKindOfClass:[NSNumber class]] ? [v integerValue] : -1;
}

static UIImage *LTFindImage(UIView *v, int depth) {
    if (!v || depth > 6) return nil;
    if ([v isKindOfClass:[UIImageView class]]) {
        UIImage *img = ((UIImageView *)v).image;
        if (img) return img;
    }
    for (UIView *s in v.subviews) {
        UIImage *img = LTFindImage(s, depth + 1);
        if (img) return img;
    }
    return nil;
}

static UIImage *LTImageForButton(id button) {
    UIImage *img = LTGet(LTGet(button, @"imageView"), @"image");
    if (![img isKindOfClass:[UIImage class]]) img = LTGet(LTGet(LTGet(button, @"innerView"), @"imageView"), @"image");
    if (![img isKindOfClass:[UIImage class]]) img = LTGet(button, @"currentImage");
    if (![img isKindOfClass:[UIImage class]]) {
        UIView *root = [button isKindOfClass:[UIView class]] ? (UIView *)button : nil;
        img = LTFindImage(root, 0);
    }
    return [img isKindOfClass:[UIImage class]] ? img : nil;
}

static id LTFindBadge(UIView *v, int depth) {
    if (!v || depth > 6) return nil;
    NSString *cn = NSStringFromClass([v class]);
    if ([cn containsString:@"Badge"] && LTGet(v, @"badgeText")) return v;
    for (UIView *s in v.subviews) {
        id b = LTFindBadge(s, depth + 1);
        if (b) return b;
    }
    return nil;
}

static NSString *LTBadgeForButton(id button) {
    id badge = LTGet(button, @"badge");
    if (!badge) {
        UIView *root = [button isKindOfClass:[UIView class]] ? (UIView *)button : nil;
        badge = LTFindBadge(root, 0);
    }
    NSString *txt = LTGet(badge, @"badgeText");
    if (![txt isKindOfClass:[NSString class]] || txt.length == 0) {
        id num = LTGet(badge, @"badgeNumber");
        if ([num isKindOfClass:[NSNumber class]] && [num integerValue] > 0) {
            return [num integerValue] > 99 ? @"99+" : [num stringValue];
        }
        return nil;
    }
    return txt;
}

static UIViewController *LTControllerForView(UIView *v) {
    UIResponder *r = v.nextResponder;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) return (UIViewController *)r;
        r = r.nextResponder;
    }
    return nil;
}

// 判断原生底栏的图标/文字是深色还是浅色（决定玻璃用 dark 还是 light 材质）。
static BOOL LTBarUsesLightInk(UIView *bar, NSArray *buttons) {
    for (id b in buttons) {
        UIColor *c = LTGet(LTGet(LTGet(b, @"innerView"), @"label"), @"textColor");
        if (![c isKindOfClass:[UIColor class]]) continue;
        UIColor *resolved = c;
        if (@available(iOS 13.0, *)) {
            UITraitCollection *tc = bar.window.windowScene.traitCollection;
            if (tc) resolved = [c resolvedColorWithTraitCollection:tc];
        }
        CGFloat r = 0, g = 0, bl = 0, a = 0;
        if ([resolved getRed:&r green:&g blue:&bl alpha:&a]) {
            CGFloat brightness = 0.299 * r + 0.587 * g + 0.114 * bl;
            if (brightness > 0.6) return YES;
            if (brightness < 0.4) return NO;
        }
    }
    // 兜底：抖音主界面（视频流）为深色底、白色图标。
    return YES;
}

BOOL LTDYYYDetected(void) {
    // 不做 dispatch_once 缓存：constructor 阶段 DYYY 可能还没注册，需支持延迟检测。
    return (NSClassFromString(@"DYYYManager") != nil) ||
           (NSClassFromString(@"DYYYABTestHook") != nil) ||
           (NSClassFromString(@"DYYYFullscreenCoordinator") != nil);
}

#pragma mark - Mirror

@interface LTTabBarMirror ()
@property (nonatomic, weak) UIView *hostBar;
@property (nonatomic, strong) UIView *container;
@property (nonatomic, strong) LTCustomGlassView *glass;
@property (nonatomic, strong) UIView *capsule;
@property (nonatomic, strong) UIView *cameraKey;
@property (nonatomic, strong) UIImageView *cameraIcon;
@property (nonatomic, strong) UIButton *cameraHit;
@property (nonatomic, strong) NSMutableArray<LTTabItemView *> *items;
@property (nonatomic, strong) NSArray *lastButtons;
@property (nonatomic, strong) NSString *lastSignature;
@property (nonatomic, assign) BOOL applying;
@property (nonatomic, assign) BOOL invalidated;
@property (nonatomic, assign) BOOL overlayMode;
@end

@implementation LTTabBarMirror

- (BOOL)applied { return _container != nil && _container.superview != nil; }
- (BOOL)attached { return self.hostBar != nil && !self.invalidated; }
- (BOOL)isAttachedToBar:(UIView *)bar { return bar != nil && self.hostBar == bar && !self.invalidated; }

- (instancetype)initWithTabBar:(UIView *)tabBar {
    if (self = [super init]) {
        _hostBar = tabBar;
        _items = [NSMutableArray array];
        // 始终叠加模式：原生图标/文字/点击一个都不动，玻璃只垫在底栏背景。
        // 独立自建胶囊会重画图标和文字，观感差且容易错位——彻底弃用。
        _overlayMode = YES;
        // 必须先设置关联对象，否则 addSubview 触发的 layout 会重复创建。
        objc_setAssociatedObject(tabBar, &kLTMirrorKey, self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self build];
    }
    return self;
}

- (void)build {
    UIView *bar = self.hostBar;
    if (!bar) return;

    _container = [[UIView alloc] initWithFrame:CGRectZero];
    _container.backgroundColor = [UIColor clearColor];
    _container.userInteractionEnabled = NO;   // 玻璃不能挡点击
    _container.autoresizingMask = UIViewAutoresizingNone;

    _glass = [[LTCustomGlassView alloc] initWithFrame:CGRectZero];
    _glass.glassRadius = [LTPrefs barHeight] / 2.0;
    _glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_container addSubview:_glass];

    if (self.overlayMode) {
        // ── 兜底叠加模式：拿不到按钮数组时，玻璃作为原生底栏的背景层 ──
        [self prepareNativeBar:bar];
        [bar insertSubview:_container atIndex:0];
        // 防止被 DYYY / UIKit 的子视图插入挤到上面去，记录并保持最底层。
        objc_setAssociatedObject(bar, &kLTGlassKey, _container, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self apply];
        return;
    }

    // ── 独立模式：自建胶囊 + 镜像按钮 + 独立圆键 ──
    _container.userInteractionEnabled = YES;
    bar.clipsToBounds = NO;   // 允许胶囊超出底栏上沿，形成悬浮感
    _capsule = [[UIView alloc] initWithFrame:CGRectZero];
    _capsule.backgroundColor = [UIColor clearColor];
    [_container addSubview:_capsule];

    CGFloat keySize = [LTPrefs barHeight];
    _cameraKey = [[UIView alloc] initWithFrame:CGRectMake(0, 0, keySize, keySize)];
    _cameraKey.backgroundColor = [UIColor clearColor];
    _cameraKey.layer.cornerRadius = keySize / 2.0;
    if (@available(iOS 13.0, *)) _cameraKey.layer.cornerCurve = kCACornerCurveContinuous;
    _cameraKey.hidden = YES;

    UIVisualEffectView *bev = [[UIVisualEffectView alloc] initWithEffect:
        [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    bev.frame = _cameraKey.bounds;
    bev.layer.cornerRadius = keySize / 2.0;
    bev.layer.masksToBounds = YES;
    bev.userInteractionEnabled = NO;
    [_cameraKey insertSubview:bev atIndex:0];

    _cameraIcon = [[UIImageView alloc] initWithFrame:CGRectInset(_cameraKey.bounds, 14, 14)];
    _cameraIcon.contentMode = UIViewContentModeScaleAspectFit;
    _cameraIcon.userInteractionEnabled = NO;
    [_cameraKey addSubview:_cameraIcon];

    _cameraHit = [UIButton buttonWithType:UIButtonTypeCustom];
    _cameraHit.frame = _cameraKey.bounds;
    [_cameraKey addSubview:_cameraHit];
    [_cameraHit addTarget:self action:@selector(cameraTapped) forControlEvents:UIControlEventTouchUpInside];
    [_container addSubview:_cameraKey];

    [bar addSubview:_container];
    [self apply];
}

// 清除原生底栏背景（只做一次；之后每次 apply 再兜底隐藏背景子视图）。
- (void)prepareNativeBar:(UIView *)bar {
    if (objc_getAssociatedObject(bar, &kLTBarPreparedKey)) return;
    objc_setAssociatedObject(bar, &kLTBarPreparedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    bar.clipsToBounds = NO;
    bar.backgroundColor = [UIColor clearColor];
    bar.opaque = NO;
    if ([bar isKindOfClass:[UITabBar class]]) {
        UITabBar *tb = (UITabBar *)bar;
        if (@available(iOS 13.0, *)) {
            UITabBarAppearance *app = [[UITabBarAppearance alloc] init];
            app.backgroundEffect = nil;
            app.backgroundColor = [UIColor clearColor];
            app.shadowColor = [UIColor clearColor];
            tb.standardAppearance = app;
            if (@available(iOS 15.0, *)) tb.scrollEdgeAppearance = app;
        }
        tb.backgroundImage = [UIImage new];
        tb.shadowImage = [UIImage new];
        tb.translucent = YES;
    }
    LTLog(@"DYYY 共存：已清空原生底栏背景，玻璃将作为按钮背景");
}

// 把底栏自带的背景子视图压成透明（只隐藏明确的背景类，绝不碰按钮）。
- (void)hideBarBackgroundSubviews:(UIView *)bar buttons:(NSArray *)buttons {
    for (UIView *v in bar.subviews) {
        if (v == _container) continue;
        NSString *cn = NSStringFromClass([v class]);
        if ([cn containsString:@"BarBackground"] ||
            [cn containsString:@"EffectBackground"] ||
            [cn containsString:@"BlurView"] ||
            [cn containsString:@"GradientView"] ||
            [cn containsString:@"BackgroundView"] ||
            [cn containsString:@"SkinContainer"]) {
            if (v.alpha != 0.0) v.alpha = 0.0;
        }
    }
    bar.backgroundColor = [UIColor clearColor];
    bar.opaque = NO;
    // 保证玻璃始终在最底层（按钮之后插入的新视图不能盖住它）。
    if (_container.superview == bar && bar.subviews.firstObject != _container && !_container.hidden) {
        [bar sendSubviewToBack:_container];
    }
}

- (void)synchronize {
    if (self.applying || self.invalidated) return;
    [self apply];
}

- (void)apply {
    UIView *bar = self.hostBar;
    if (!bar || self.invalidated) return;
    if (CGRectIsEmpty(bar.bounds)) return;
    self.applying = YES;

    NSArray *buttons = LTGet(bar, @"tabBarButtons");
    if (![buttons isKindOfClass:[NSArray class]]) buttons = @[];
    self.lastButtons = buttons;

    if (self.overlayMode) {
        [self layoutOverlayGlass:bar buttons:buttons];
        self.applying = NO;
        return;
    }

    [self hideOriginalContent:bar];
    [self layoutCapsule:bar buttons:buttons];
    self.applying = NO;
}

#pragma mark - DYYY 共存：玻璃垫在原生按钮下面

- (void)layoutOverlayGlass:(UIView *)bar buttons:(NSArray *)buttons {
    [self hideBarBackgroundSubviews:bar buttons:buttons];

    CGRect b = bar.bounds;
    CGFloat safeBottom = bar.safeAreaInsets.bottom;
    CGFloat rowH = MAX(CGRectGetHeight(b) - safeBottom, 44.0);   // 按钮所在高度（通常 49）
    CGFloat side = [LTPrefs sideInset];

    // 关键修复：原来把胶囊上移 (rowH-h)/2 导致玻璃和原生按钮错位、露出白边。
    // 现在玻璃严格贴合原生按钮行（同 y、同高），只在左右按 sideInset 内缩。
    CGFloat y = 0;
    CGFloat fH = rowH;
    CGRect f = CGRectMake(side, y, MAX(CGRectGetWidth(b) - side * 2.0, 1.0), fH);

    if (!CGRectEqualToRect(_container.frame, f)) _container.frame = f;

    _glass.glassRadius = fH / 2.0;
    [_glass applyStyleForUserInterfaceStyle:
        LTBarUsesLightInk(bar, buttons) ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight];
    _glass.hidden = NO;

    // 选中胶囊：直接读原生按钮的 frame，套在玻璃里，跟随抖音/DYYY 的布局。
    if ([LTPrefs showSelectionPill]) {
        UIView *selected = nil;
        NSInteger selIdx = -1;
        for (NSInteger i = 0; i < (NSInteger)buttons.count; i++) {
            id b = buttons[i];
            id sv = LTGet(b, @"selected");
            if (sv && [sv respondsToSelector:@selector(boolValue)] && [sv boolValue]) {
                selected = [b isKindOfClass:[UIView class]] ? (UIView *)b : nil;
                selIdx = i;
                break;
            }
        }
        if (!selected) {
            id vc = LTControllerForView(bar);
            if (LTHas(vc, NSSelectorFromString(@"selectedIndex"))) {
                id raw = LTGet(vc, @"selectedIndex");
                NSInteger idx = [raw isKindOfClass:[NSNumber class]] ? [raw integerValue] : -1;
                if (idx >= 0 && idx < (NSInteger)buttons.count) {
                    id b = buttons[idx];
                    selected = [b isKindOfClass:[UIView class]] ? (UIView *)b : nil;
                }
            }
        }
        if (selected && selected.superview) {
            CGRect bf = [selected.superview convertRect:selected.frame toView:bar];
            CGRect inGlass = CGRectOffset(bf, -CGRectGetMinX(_container.frame), -CGRectGetMinY(_container.frame));
            inGlass = CGRectInset(inGlass, 6, 5);
            [_glass setSelectionFrame:inGlass animated:NO];
        } else {
            [_glass setSelectionFrame:CGRectZero animated:NO];
        }
    } else {
        [_glass setSelectionFrame:CGRectZero animated:NO];
    }
}

#pragma mark - 独立模式：自建胶囊

- (void)layoutCapsule:(UIView *)bar buttons:(NSArray *)buttons {
    CGRect b = bar.bounds;
    CGFloat safeBottom = bar.safeAreaInsets.bottom;
    CGFloat h = [LTPrefs barHeight];
    CGFloat side = [LTPrefs sideInset];
    CGFloat bottom = [LTPrefs bottomInset];
    CGFloat y = CGRectGetHeight(b) - safeBottom - bottom - h;
    // 不再 clamp 到 0：bar.clipsToBounds = NO，允许胶囊略微浮在底栏上沿之上。

    _container.frame = CGRectMake(0, y, CGRectGetWidth(b), h);
    _container.userInteractionEnabled = YES;
    _capsule.frame = _container.bounds;
    _glass.frame = _container.bounds;
    _glass.glassRadius = ([LTPrefs cornerRadius] > 0) ? [LTPrefs cornerRadius] : h / 2.0;

    CGFloat plusSize = h;
    BOOL hasPlus = NO;
    for (id bt in buttons) { if (LTTypeOfButton(bt) == 2) { hasPlus = YES; break; } }

    CGFloat capsuleW = CGRectGetWidth(_container.bounds) - side * 2.0
                        - (hasPlus ? plusSize + 8.0 : 0.0);
    CGRect capsuleFrame = CGRectMake(side, 0, MAX(capsuleW, 1.0), h);
    _capsule.frame = capsuleFrame;

    LTCustomGlassView *capsuleGlass = _glass;
    capsuleGlass.frame = capsuleFrame;
    capsuleGlass.glassRadius = h / 2.0;

    if (hasPlus) {
        CGFloat keySize = plusSize;
        _cameraKey.hidden = NO;
        _cameraKey.frame = CGRectMake(CGRectGetWidth(_container.bounds) - side - keySize,
                                      (h - keySize) / 2.0, keySize, keySize);
    } else {
        _cameraKey.hidden = YES;
    }

    [self syncItems:buttons];
    _container.userInteractionEnabled = YES;
    _capsule.userInteractionEnabled = YES;
}

- (void)syncItems:(NSArray *)buttons {
    NSMutableString *sig = [NSMutableString string];
    NSMutableArray *visible = [NSMutableArray array];
    id cameraButton = nil;
    for (id b in buttons) {
        NSInteger type = LTTypeOfButton(b);
        NSString *title = LTTitleOfButton(b) ?: @"";
        NSString *badge = LTBadgeForButton(b) ?: @"";
        id sv = LTGet(b, @"selected");
        BOOL selected = sv && [sv respondsToSelector:@selector(boolValue)] && [sv boolValue];
        [sig appendFormat:@"%@|%@|%@|%d;", @(type), title, badge, selected];
        if (type == 2) cameraButton = b;
        else [visible addObject:b];
    }
    if ([self.lastSignature isEqualToString:sig] && self.items.count == visible.count) {
        for (LTTabItemView *item in self.items) {
            id sv = LTGet(item.originalButton, @"selected");
            item.itemSelected = sv && [sv respondsToSelector:@selector(boolValue)] && [sv boolValue];
        }
        return;
    }
    self.lastSignature = sig;

    for (LTTabItemView *v in self.items) [v removeFromSuperview];
    [self.items removeAllObjects];

    UIColor *ink = LTBarUsesLightInk(self.hostBar, buttons) ? [UIColor whiteColor] : [UIColor blackColor];
    [LTTabItemView setInkColor:ink];

    CGFloat count = MAX(visible.count, 1);
    CGFloat w = CGRectGetWidth(self.capsule.bounds);
    CGFloat itemW = w / count;
    for (NSInteger i = 0; i < (NSInteger)visible.count; i++) {
        id b = visible[i];
        LTTabItemView *item = [[LTTabItemView alloc] initWithFrame:
            CGRectMake(i * itemW, 0, itemW, CGRectGetHeight(self.capsule.bounds))];
        item.originalButton = b;
        item.titleLabel.text = LTTitleOfButton(b);
        UIImage *img = LTImageForButton(b);
        if (img) item.imageView.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        NSString *badge = LTBadgeForButton(b);
        item.badgeLabel.text = badge;
        item.badgeLabel.hidden = (badge.length == 0);
        NSInteger vi = LTIndexForButton(b);
        item.index = (vi >= 0) ? vi : i;
        __weak LTTabBarMirror *weakSelf = self;
        item.tapBlock = ^(LTTabItemView *tapped) { [weakSelf forwardTapForItem:tapped]; };
        [self.capsule addSubview:item];
        [self.items addObject:item];
    }

    if (cameraButton) {
        UIImage *img = LTImageForButton(cameraButton);
        if (img) self.cameraIcon.image = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        self.cameraIcon.tintColor = ink;
        self.cameraKey.hidden = NO;
    } else {
        self.cameraKey.hidden = YES;
    }
}

- (void)hideOriginalContent:(UIView *)bar {
    for (UIView *v in bar.subviews) {
        if (v == self.container) continue;
        v.hidden = YES;
        v.userInteractionEnabled = NO;
    }
}

- (void)forwardTapForItem:(LTTabItemView *)item {
    id button = item.originalButton;
    if (!button) return;
    UIViewController *vc = LTControllerForView(self.hostBar);
    SEL sel = NSSelectorFromString(@"tabBarButtonDidTouchUpInside:gestureRecognizer:");
    if (LTHas(vc, sel)) {
        id gesture = LTGet(button, @"singleTapGes");
        ((void (*)(id, SEL, id, id))objc_msgSend)(vc, sel, button, gesture);
        return;
    }
    id delegate = LTGet(self.hostBar, @"delegate");
    sel = NSSelectorFromString(@"tabBar:didSelectItem:");
    if (LTHas(delegate, sel)) {
        id tabItem = LTGet(button, @"item");
        if (tabItem) ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, self.hostBar, tabItem);
    }
}

- (void)cameraTapped {
    UIViewController *vc = LTControllerForView(self.hostBar);
    SEL sel = NSSelectorFromString(@"plusTabBarButtonDidClick:");
    for (id b in self.lastButtons) {
        if (LTTypeOfButton(b) == 2) {
            if (LTHas(vc, sel)) ((void (*)(id, SEL, id))objc_msgSend)(vc, sel, b);
            return;
        }
    }
}

- (void)detach {
    self.invalidated = YES;
    [_container removeFromSuperview];
    [LTTabItemView setInkColor:nil];
}

@end
