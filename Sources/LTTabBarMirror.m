//
//  LTTabBarMirror.m
//  LiqTab — mirrors Douyin's native tab bar into a floating glass capsule.
//
//  兼容 DYYY：检测到 DYYY 时进入「叠加模式」——不 hook / 不修改原生底栏，
//  只把自己的玻璃视图加到 UIWindow 上，按原生底栏的 frame 定位。
//

#import "LiqTabInternal.h"
#import <objc/runtime.h>
#import <objc/message.h>

char kLTMirrorKey;

#pragma mark - Small reflection helpers

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

// 检测到 DYYY 时返回 YES。
BOOL LTDYYYDetected(void) {
    static BOOL detected;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        detected = (NSClassFromString(@"DYYYManager") != nil) ||
                   (NSClassFromString(@"DYYYABTestHook") != nil) ||
                   (NSClassFromString(@"DYYYFullscreenCoordinator") != nil);
    });
    return detected;
}

// 在视图树里递归查找指定类（前向声明）。
static UIView *LTFindViewOfClass(UIView *v, Class cls, int depth);

// 在全屏幕层级里查找抖音的原生底栏（DYYY 共存模式下使用）。
static UIView *LTFindNativeTabBar(void) {
    NSArray *windows;
    if (@available(iOS 13.0, *)) {
        windows = [UIApplication sharedApplication].windows;
    } else {
        windows = @[[UIApplication sharedApplication].keyWindow];
    }
    Class tabBarClass = NSClassFromString(@"AWENormalModeTabBar");
    for (UIWindow *w in windows) {
        UIView *found = LTFindViewOfClass(w, tabBarClass, 0);
        if (found) return found;
    }
    return nil;
}

static UIView *LTFindViewOfClass(UIView *v, Class cls, int depth) {
    if (!v || depth > 12 || !cls) return nil;
    if ([v isKindOfClass:cls]) return v;
    for (UIView *s in v.subviews) {
        UIView *f = LTFindViewOfClass(s, cls, depth + 1);
        if (f) return f;
    }
    return nil;
}

#pragma mark - Mirror

@interface LTTabBarMirror ()
@property (nonatomic, weak) UIView *hostBar;
@property (nonatomic, strong) UIView *container;     // full-width transparent wrapper
@property (nonatomic, strong) LTCustomGlassView *glass;
@property (nonatomic, strong) UIView *capsule;      // holds tab items
@property (nonatomic, strong) UIView *cameraKey;    // round separate key
@property (nonatomic, strong) UIImageView *cameraIcon;
@property (nonatomic, strong) UIButton *cameraHit;
@property (nonatomic, strong) NSMutableArray<LTTabItemView *> *items;
@property (nonatomic, strong) NSArray *lastButtons;
@property (nonatomic, strong) NSString *lastSignature;
@property (nonatomic, assign) BOOL applying;
@property (nonatomic, assign) BOOL invalidated;
@property (nonatomic, assign) BOOL overlayMode;     // DYYY 共存：只叠加视图，不改原生底栏
@end

@implementation LTTabBarMirror

- (instancetype)initWithTabBar:(UIView *)tabBar {
    if (self = [super init]) {
        _hostBar = tabBar;
        _items = [NSMutableArray array];
        _overlayMode = LTDYYYDetected();
        // 必须在 build 之前设置关联对象，避免 addSubview 触发递归创建。
        objc_setAssociatedObject(tabBar, &kLTMirrorKey, self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self build];
    }
    return self;
}

- (void)build {
    UIView *bar = self.hostBar;
    if (!bar) return;

    CGFloat h = [LTPrefs barHeight];
    CGFloat side = [LTPrefs sideInset];
    CGFloat bottom = [LTPrefs bottomInset];
    CGRect vb = bar.bounds;
    if (CGRectIsEmpty(vb)) {
        vb = CGRectMake(0, 0, [UIScreen mainScreen].bounds.size.width, 83.0);
    }

    CGFloat width = CGRectGetWidth(vb) - side * 2;
    CGFloat y = CGRectGetHeight(vb) - h - bottom;

    _container = [[UIView alloc] initWithFrame:CGRectMake(side, y, width, h)];
    _container.backgroundColor = [UIColor clearColor];
    _container.userInteractionEnabled = YES;
    _container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;

    _glass = [[LTCustomGlassView alloc] initWithFrame:_container.bounds];
    _glass.glassRadius = ([LTPrefs cornerRadius] > 0) ? [LTPrefs cornerRadius] : h / 2.0;
    _glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_container addSubview:_glass];

    _capsule = [[UIView alloc] initWithFrame:_container.bounds];
    _capsule.backgroundColor = [UIColor clearColor];
    _capsule.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_container addSubview:_capsule];

    // 独立圆形相机（+）键。
    CGFloat keySize = h;
    _cameraKey = [[UIView alloc] initWithFrame:CGRectMake(width - keySize, 0, keySize, keySize)];
    _cameraKey.backgroundColor = [UIColor clearColor];
    _cameraKey.layer.cornerRadius = keySize / 2.0;
    if (@available(iOS 13.0, *)) _cameraKey.layer.cornerCurve = kCACornerCurveContinuous;
    _cameraKey.layer.shadowColor = [UIColor blackColor].CGColor;
    _cameraKey.layer.shadowOpacity = 0.28;
    _cameraKey.layer.shadowRadius = 12.0;
    _cameraKey.layer.shadowOffset = CGSizeMake(0, 5);
    _cameraKey.hidden = YES;

    UIBlurEffect *be = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
    UIVisualEffectView *bev = [[UIVisualEffectView alloc] initWithEffect:be];
    bev.frame = _cameraKey.bounds;
    bev.layer.cornerRadius = keySize / 2.0;
    bev.layer.masksToBounds = YES;
    bev.userInteractionEnabled = NO;
    if (@available(iOS 13.0, *)) bev.layer.cornerCurve = kCACornerCurveContinuous;
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

    if (self.overlayMode) {
        // DYYY 共存：把玻璃视图放到 window 上，绝不修改原生底栏。
        UIWindow *win = bar.window;
        if (!win) win = [UIApplication sharedApplication].keyWindow;
        if (win) {
            CGRect conv = [bar.superview convertRect:bar.frame toView:win];
            _container.frame = CGRectMake(conv.origin.x + side,
                                          conv.origin.y + CGRectGetHeight(conv) - h - bottom,
                                          CGRectGetWidth(conv) - side * 2, h);
            [win addSubview:_container];
            // 放到底栏之上、其它弹窗之下。
            _container.layer.zPosition = 999;
        } else {
            [bar addSubview:_container];
        }
    } else {
        [bar addSubview:_container];
    }

    [self apply];
}

- (void)synchronize {
    if (self.applying || self.invalidated) return;
    [self apply];
}

- (void)apply {
    UIView *bar = self.hostBar;
    if (!bar || self.invalidated) return;
    self.applying = YES;

    NSArray *buttons = LTGet(bar, @"tabBarButtons");
    if (![buttons isKindOfClass:[NSArray class]]) buttons = @[];
    self.lastButtons = buttons;

    if (!self.overlayMode) {
        // 仅在非 DYYY 模式下隐藏原生底栏像素。
        [self hideOriginalContent:bar buttons:buttons];
    }

    // 确定选中项。
    NSInteger selectedIndex = -1;
    for (NSInteger i = 0; i < (NSInteger)buttons.count; i++) {
        id b = buttons[i];
        if (LTTypeOfButton(b) == 2) continue;
        id sel = LTGet(b, @"selected");
        if ([sel respondsToSelector:@selector(boolValue)] && [sel boolValue]) {
            selectedIndex = i;
            break;
        }
    }
    if (selectedIndex < 0) {
        UIView *realBar = self.overlayMode ? LTFindNativeTabBar() : bar;
        id vc = LTControllerForView(realBar);
        if (LTHas(vc, NSSelectorFromString(@"selectedIndex"))) {
            id raw = LTGet(vc, @"selectedIndex");
            if ([raw isKindOfClass:[NSNumber class]]) selectedIndex = [raw integerValue];
        }
    }

    // 重叠模式下只显示玻璃，不创建按钮（避免和 DYYY 的按钮重排冲突）。
    if (self.overlayMode) {
        [self applyOverlayOnly:bar buttons:buttons];
        self.applying = NO;
        return;
    }

    // 构建签名。
    NSMutableString *sig = [NSMutableString string];
    NSMutableArray *visible = [NSMutableArray array];
    id cameraButton = nil;
    for (id b in buttons) {
        NSInteger type = LTTypeOfButton(b);
        NSString *title = LTTitleOfButton(b) ?: @"";
        NSString *badge = LTBadgeForButton(b) ?: @"";
        id selVal = LTGet(b, @"selected");
        BOOL selected = (selectedIndex >= 0 && selectedIndex < (NSInteger)buttons.count &&
                         b == buttons[selectedIndex]) ||
                        (selVal && [selVal respondsToSelector:@selector(boolValue)] && [selVal boolValue]);
        [sig appendFormat:@"%@|%@|%@|%d;", @(type), title, badge, selected];
        if (type == 2) cameraButton = b;
        else [visible addObject:b];
    }

    UIColor *ink = [UIColor labelColor];
    for (id b in buttons) {
        UIColor *c = LTGet(LTGet(LTGet(b, @"innerView"), @"label"), @"textColor");
        if ([c isKindOfClass:[UIColor class]]) {
            UIColor *resolved = c;
            if (@available(iOS 13.0, *)) {
                UITraitCollection *tc = bar.window.windowScene.traitCollection;
                if (tc) resolved = [c resolvedColorWithTraitCollection:tc];
            }
            CGFloat r=0,g=0,b2=0,a=0;
            if ([resolved getRed:&r green:&g blue:&b2 alpha:&a]) {
                CGFloat brightness = 0.299*r + 0.587*g + 0.114*b2;
                if (brightness < 0.35) { ink = [UIColor blackColor]; break; }
                else if (brightness > 0.75) { ink = [UIColor whiteColor]; break; }
            }
        }
    }
    [LTTabItemView setInkColor:ink];
    [self.glass applyStyleForUserInterfaceStyle:ink == [UIColor whiteColor]
        ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight];

    BOOL rebuild = ![self.lastSignature isEqualToString:sig] || self.items.count != visible.count;
    self.lastSignature = sig;

    if (rebuild) {
        for (LTTabItemView *v in self.items) [v removeFromSuperview];
        [self.items removeAllObjects];

        CGFloat count = MAX(visible.count, 1);
        CGFloat capsuleW = CGRectGetWidth(self.capsule.bounds) - ([LTPrefs barHeight] + 8.0);
        CGFloat itemW = capsuleW / count;
        for (NSInteger i = 0; i < (NSInteger)visible.count; i++) {
            id b = visible[i];
            LTTabItemView *item = [[LTTabItemView alloc] initWithFrame:
                CGRectMake(i * itemW, 0, itemW, CGRectGetHeight(self.capsule.bounds))];
            item.index = i;
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

    NSInteger capsuleSelected = -1;
    for (LTTabItemView *item in self.items) {
        id sv = LTGet(item.originalButton, @"selected");
        BOOL sel = (item.index == selectedIndex) || (sv && [sv respondsToSelector:@selector(boolValue)] && [sv boolValue]);
        item.itemSelected = sel;
        if (sel) capsuleSelected = [self.items indexOfObject:item];
    }
    if (capsuleSelected >= 0 && capsuleSelected < (NSInteger)self.items.count) {
        LTTabItemView *sel = self.items[capsuleSelected];
        [self.glass setSelectionFrame:CGRectInset(sel.frame, 4, 5) animated:YES];
    }

    self.applying = NO;
}

// DYYY 共存：只把玻璃视图定位到底栏位置，不创建/镜像任何按钮。
- (void)applyOverlayOnly:(UIView *)bar buttons:(NSArray *)buttons {
    UIWindow *win = bar.window ?: [UIApplication sharedApplication].keyWindow;
    if (!win) return;

    // 隐藏我们自己的胶囊按钮（DYYY 已经管理原生按钮）。
    self.capsule.hidden = YES;
    self.cameraKey.hidden = YES;

    CGRect conv = [bar.superview convertRect:bar.frame toView:win];
    CGFloat side = [LTPrefs sideInset];
    CGFloat bottom = [LTPrefs bottomInset];
    CGFloat h = [LTPrefs barHeight];
    _container.frame = CGRectMake(conv.origin.x + side,
                                  conv.origin.y + CGRectGetHeight(conv) - h - bottom,
                                  CGRectGetWidth(conv) - side * 2, h);

    // 让点击穿透到 DYYY 管理的原生底栏。
    _container.userInteractionEnabled = NO;

    // 颜色跟随原生底栏的选中文字颜色。
    UIColor *ink = [UIColor labelColor];
    for (id b in buttons) {
        UIColor *c = LTGet(LTGet(LTGet(b, @"innerView"), @"label"), @"textColor");
        if ([c isKindOfClass:[UIColor class]]) {
            UIColor *resolved = c;
            if (@available(iOS 13.0, *)) {
                UITraitCollection *tc = win.windowScene.traitCollection;
                if (tc) resolved = [c resolvedColorWithTraitCollection:tc];
            }
            CGFloat r=0,g=0,b2=0,a=0;
            if ([resolved getRed:&r green:&g blue:&b2 alpha:&a]) {
                CGFloat brightness = 0.299*r + 0.587*g + 0.114*b2;
                if (brightness < 0.35) { ink = [UIColor blackColor]; break; }
                else if (brightness > 0.75) { ink = [UIColor whiteColor]; break; }
            }
        }
    }
    [self.glass applyStyleForUserInterfaceStyle:ink == [UIColor whiteColor]
        ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight];
}

- (void)hideOriginalContent:(UIView *)bar buttons:(NSArray *)buttons {
    for (UIView *v in bar.subviews) {
        if (v == self.container) continue;
        v.hidden = YES;
        v.userInteractionEnabled = NO;
    }
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
    [self.container removeFromSuperview];
    [LTTabItemView setInkColor:nil];
}

@end
