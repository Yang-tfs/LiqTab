//
//  LTCustomGlassView.m
//  LiqTab — public-API "liquid glass" look for iOS 15/16.
//
//  Layers (back → front), mirroring the structure reverse-engineered from
//  Apple's iOS 26 UIGlassEffect:
//    • UIVisualEffectView with a system material blur (backdrop deformation)
//    • adaptive tint overlay (lightness/saturation)
//    • soft drop shadow on the wrapper (outside the capsule clip)
//    • top specular gradient + hairline outline + rim stroke
//

#import "LiqTabInternal.h"

@interface LTCustomGlassView ()
@property (nonatomic, strong, readwrite) UIVisualEffectView *blurView;
@property (nonatomic, strong, readwrite) UIView *tintView;
@property (nonatomic, strong, readwrite) UIView *selectionPill;
@property (nonatomic, strong) CAGradientLayer *specularLayer;
@property (nonatomic, strong) CAShapeLayer *rimLayer;
@property (nonatomic, strong) CAShapeLayer *topHairline;
@property (nonatomic, assign) UIUserInterfaceStyle lastStyle;
- (UIVisualEffect *)preferredEffectForStyle:(NSInteger)style dark:(BOOL)dark;
- (UIBlurEffect *)blurEffectForStyle:(NSInteger)style dark:(BOOL)dark;
@end

@implementation LTCustomGlassView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        _glassRadius = 26.0;
        _lastStyle = UIUserInterfaceStyleUnspecified;

        // 极淡投影：叠在原生底栏下当背景，投影要几乎看不见。
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.05;
        self.layer.shadowRadius = 10.0;
        self.layer.shadowOffset = CGSizeMake(0, 2);

        UIVisualEffect *blur = [self preferredEffectForStyle:[LTPrefs blurStyle]
                                                 dark:(self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark)];
        _blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        _blurView.frame = self.bounds;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blurView.userInteractionEnabled = NO;
        if (@available(iOS 13.0, *)) {
            _blurView.layer.cornerCurve = kCACornerCurveContinuous;
        }
        _blurView.layer.masksToBounds = YES;
        [self addSubview:_blurView];

        // Content additions must go in contentView (Apple requirement).
        _tintView = [[UIView alloc] initWithFrame:self.bounds];
        _tintView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _tintView.userInteractionEnabled = NO;
        [_blurView.contentView addSubview:_tintView];

        _specularLayer = [CAGradientLayer layer];
        _specularLayer.startPoint = CGPointMake(0.5, 0.0);
        _specularLayer.endPoint = CGPointMake(0.5, 1.0);
        _specularLayer.locations = @[@0.0, @0.42, @0.85];
        [_tintView.layer addSublayer:_specularLayer];

        _rimLayer = [CAShapeLayer layer];
        _rimLayer.fillColor = nil;
        _rimLayer.lineWidth = 0.8;
        [_tintView.layer addSublayer:_rimLayer];

        _topHairline = [CAShapeLayer layer];
        _topHairline.fillColor = nil;
        _topHairline.lineWidth = 1.0;
        [_tintView.layer addSublayer:_topHairline];

        // Selection pill (inside the blur view so it sits above the tint).
        _selectionPill = [[UIView alloc] initWithFrame:CGRectZero];
        _selectionPill.userInteractionEnabled = NO;
        _selectionPill.alpha = 0.0;
        _selectionPill.layer.cornerCurve = kCACornerCurveContinuous;
        [_blurView.contentView addSubview:_selectionPill];

        [self applyStyleForUserInterfaceStyle:self.traitCollection.userInterfaceStyle];
    }
    return self;
}

- (UIBlurEffect *)blurEffectForStyle:(NSInteger)style dark:(BOOL)dark {
    // 默认走 UltraThin：最透亮，不像一块白塑料。
    switch (style) {
        case 3: return [UIBlurEffect effectWithStyle:
                    dark ? UIBlurEffectStyleSystemThickMaterialDark : UIBlurEffectStyleSystemThickMaterialLight];
        case 4: return [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        case 2: return [UIBlurEffect effectWithStyle:
                    dark ? UIBlurEffectStyleSystemMaterialDark : UIBlurEffectStyleSystemMaterialLight];
        default: return [UIBlurEffect effectWithStyle:
                    dark ? UIBlurEffectStyleSystemUltraThinMaterialDark
                         : UIBlurEffectStyleSystemUltraThinMaterialLight];
    }
}

// iOS 15/16 上最接近 iOS 26 UIGlassEffect 的材质：私有 _UICustomBlurEffect。
// 巨魔（TrollStore）环境下私有 API 可用；失败时回落到公开 UIBlurEffect。
// 相比系统 material，它能独立控制 blurRadius / saturation / tint / zoom，
// 其中 zoom>1 让背景轻微放大，模拟玻璃透镜的折射错觉。
- (UIVisualEffect *)preferredEffectForStyle:(NSInteger)style dark:(BOOL)dark {
    // 清透档：半径减小，避免糊成一片白雾。
    CGFloat radius = (style == 3) ? 24.0 : (style == 2) ? 18.0 : (style == 4) ? 20.0 : 12.0;
    CGFloat saturation = (style == 4) ? 0.0 : (dark ? 1.2 : 1.1);

    // 首选：抖音 41.2.0 自己的做法（IPA 二进制实证）。
    // 在 AwemeCore 的 tabbar 相关代码区（AWETabBarControllerPadProtocol 附近）
    // 发现字符串 `_blurRadius` / `_saturationDeltaFactor` 以及 block 签名
    // `@16@?0@"UIBlurEffect"8` —— 说明抖音就是拿标准 UIBlurEffect 再 KVC
    // 改这两个私有 ivar 来做它的 "fake liquid glass"。这是最有把握的一条路。
    UIBlurEffect *base = [self blurEffectForStyle:style dark:dark];
    @try {
        [base setValue:@(radius) forKey:@"_blurRadius"];
        [base setValue:@(saturation) forKey:@"_saturationDeltaFactor"];
        LTLog(@"UIBlurEffect KVC 私有 ivar 成功: radius=%.1f saturation=%.2f", radius, saturation);
        return base;
    } @catch (NSException *e) {
        LTLog(@"UIBlurEffect 私有 ivar KVC 失败: %@", e.reason);
    }

    // 次选：_UICustomBlurEffect，能额外控制 colorTint / zoom（背景放大→折射错觉）。
    Class custom = NSClassFromString(@"_UICustomBlurEffect");
    if (custom) {
        id effect = [[custom alloc] init];
        @try {
            [effect setValue:@(radius) forKey:@"blurRadius"];
            [effect setValue:@(saturation) forKey:@"saturationFactor"];
            [effect setValue:(dark ? [UIColor blackColor] : [UIColor whiteColor]) forKey:@"colorTint"];
            [effect setValue:@(dark ? 0.10 : 0.06) forKey:@"colorTintAlpha"];
            [effect setValue:@1.06 forKey:@"zoom"];
            return (UIVisualEffect *)effect;
        } @catch (NSException *e) {
            LTLog(@"_UICustomBlurEffect 配置失败，回落公开 UIBlurEffect: %@", e.reason);
        }
    }
    return base;
}

// 把偏好里的强制外观套到传入的 style 上。
- (UIUserInterfaceStyle)resolveStyle:(UIUserInterfaceStyle)style {
    NSInteger pref = [LTPrefs glassAppearance];
    if (pref == 1) return UIUserInterfaceStyleLight;
    if (pref == 2) return UIUserInterfaceStyleDark;
    if (style == UIUserInterfaceStyleUnspecified) style = self.traitCollection.userInterfaceStyle;
    return style;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    _blurView.frame = b;
    _tintView.frame = b;

    self.layer.cornerRadius = _glassRadius;
    if (@available(iOS 13.0, *)) self.layer.cornerCurve = kCACornerCurveContinuous;
    _blurView.layer.cornerRadius = _glassRadius;
    _selectionPill.layer.cornerRadius = MAX(_glassRadius - 6.0, 6.0);
    _selectionPill.layer.cornerCurve = kCACornerCurveContinuous;

    UIBezierPath *capsule = [UIBezierPath bezierPathWithRoundedRect:b cornerRadius:_glassRadius];
    self.layer.shadowPath = capsule.CGPath;

    UIBezierPath *rim = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(b, 0.4, 0.4)
                                                  cornerRadius:MAX(_glassRadius - 0.4, 0)];
    _rimLayer.path = rim.CGPath;

    UIBezierPath *line = [UIBezierPath bezierPath];
    [line moveToPoint:CGPointMake(_glassRadius * 0.7, 0.75)];
    [line addLineToPoint:CGPointMake(CGRectGetWidth(b) - _glassRadius * 0.7, 0.75)];
    _topHairline.path = line.CGPath;

    _specularLayer.frame = b;
    _specularLayer.cornerRadius = _glassRadius;
    _specularLayer.masksToBounds = YES;
}

- (void)applyStyleForUserInterfaceStyle:(UIUserInterfaceStyle)style {
    style = [self resolveStyle:style];
    _lastStyle = style;
    BOOL reduce = UIAccessibilityIsReduceTransparencyEnabled();

    if (reduce) {
        _blurView.hidden = YES;
        _tintView.backgroundColor = (style == UIUserInterfaceStyleDark)
            ? [UIColor colorWithWhite:0.13 alpha:1.0]
            : [UIColor colorWithWhite:0.97 alpha:1.0];
        _specularLayer.colors = @[(id)[UIColor clearColor].CGColor,
                                  (id)[UIColor clearColor].CGColor,
                                  (id)[UIColor clearColor].CGColor];
        _rimLayer.strokeColor = [UIColor clearColor].CGColor;
        _topHairline.strokeColor = [UIColor clearColor].CGColor;
        return;
    }

    _blurView.hidden = NO;
    BOOL dark = (style == UIUserInterfaceStyleDark);
    // 让材质跟随明暗：深色内容用 dark material，避免变成一块浅灰板。
    _blurView.effect = [self preferredEffectForStyle:[LTPrefs blurStyle] dark:dark];

    // 清透玻璃：只留很淡的染色，不再糊一层白霜。
    _tintView.backgroundColor = dark
        ? [[UIColor whiteColor] colorWithAlphaComponent:0.04]
        : [[UIColor colorWithWhite:0.5 alpha:1.0] colorWithAlphaComponent:0.08];

    // 顶部高光：很克制的一点柔光，避免"白色塑料条"。
    CGFloat sheen = dark ? 0.10 : 0.22;
    _specularLayer.colors = @[
        (id)[[UIColor whiteColor] colorWithAlphaComponent:sheen].CGColor,
        (id)[[UIColor whiteColor] colorWithAlphaComponent:sheen * 0.20].CGColor,
        (id)[UIColor clearColor].CGColor
    ];
    _rimLayer.strokeColor = (dark
        ? [[UIColor whiteColor] colorWithAlphaComponent:0.14]
        : [[UIColor whiteColor] colorWithAlphaComponent:0.28]).CGColor;
    _topHairline.strokeColor = (dark
        ? [[UIColor whiteColor] colorWithAlphaComponent:0.18]
        : [[UIColor whiteColor] colorWithAlphaComponent:0.34]).CGColor;

    // 选中胶囊：克制的高亮，不再是一块刺眼的白色。
    _selectionPill.backgroundColor = (dark
        ? [[UIColor whiteColor] colorWithAlphaComponent:0.10]
        : [[UIColor whiteColor] colorWithAlphaComponent:0.22]);
}

- (void)setSelectionFrame:(CGRect)frame animated:(BOOL)animated {
    if (CGRectEqualToRect(_selectionPill.frame, frame)) return;
    void (^apply)(void) = ^{
        self->_selectionPill.frame = frame;
        self->_selectionPill.alpha = 1.0;
    };
    if (animated && !UIAccessibilityIsReduceMotionEnabled()) {
        [UIView animateWithDuration:0.28
                              delay:0
             usingSpringWithDamping:0.82
              initialSpringVelocity:0.2
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:apply
                         completion:nil];
    } else {
        apply();
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self applyStyleForUserInterfaceStyle:self.traitCollection.userInterfaceStyle];
}

@end
