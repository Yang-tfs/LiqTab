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
@end

@implementation LTCustomGlassView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        _glassRadius = 26.0;
        _lastStyle = UIUserInterfaceStyleUnspecified;

        // 轻投影：参考图是极淡的浮起感，不要厚重黑影。
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.12;
        self.layer.shadowRadius = 16.0;
        self.layer.shadowOffset = CGSizeMake(0, 4);

        UIBlurEffect *blur = [self blurEffectForStyle:[LTPrefs blurStyle]
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
    // 统一用 SystemThinMaterial：模糊足、又足够透，接近参考图的高斯磨砂。
    // 0/1 走 thin（最接近参考），2 走 regular，3 更厚，4 纯 dark。
    switch (style) {
        case 3: return [UIBlurEffect effectWithStyle:
                    dark ? UIBlurEffectStyleSystemThickMaterialDark : UIBlurEffectStyleSystemThickMaterialLight];
        case 4: return [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        case 2: return [UIBlurEffect effectWithStyle:
                    dark ? UIBlurEffectStyleSystemMaterialDark : UIBlurEffectStyleSystemMaterialLight];
        default: return [UIBlurEffect effectWithStyle:
                    dark ? UIBlurEffectStyleSystemUltraThinMaterialDark
                         : UIBlurEffectStyleSystemThinMaterialLight];
    }
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
    _blurView.effect = [self blurEffectForStyle:[LTPrefs blurStyle] dark:dark];

    // 乳白磨砂（参考图）：白霜感明显、但仍是半透明，能透出模糊的背景。
    // 深色磨砂：只做很轻的压暗，保证白色图标可读，不要糊成黑板。
    _tintView.backgroundColor = dark
        ? [[UIColor whiteColor] colorWithAlphaComponent:0.06]
        : [[UIColor whiteColor] colorWithAlphaComponent:0.34];

    // 顶部高光：参考图是明显的柔光过渡。
    CGFloat sheen = dark ? 0.18 : 0.55;
    _specularLayer.colors = @[
        (id)[[UIColor whiteColor] colorWithAlphaComponent:sheen].CGColor,
        (id)[[UIColor whiteColor] colorWithAlphaComponent:sheen * 0.28].CGColor,
        (id)[UIColor clearColor].CGColor
    ];
    _rimLayer.strokeColor = (dark
        ? [[UIColor whiteColor] colorWithAlphaComponent:0.24]
        : [[UIColor whiteColor] colorWithAlphaComponent:0.62]).CGColor;
    _topHairline.strokeColor = (dark
        ? [[UIColor whiteColor] colorWithAlphaComponent:0.28]
        : [[UIColor whiteColor] colorWithAlphaComponent:0.80]).CGColor;

    // 选中胶囊：参考图里是比玻璃更亮的一层。
    _selectionPill.backgroundColor = (dark
        ? [[UIColor whiteColor] colorWithAlphaComponent:0.14]
        : [[UIColor whiteColor] colorWithAlphaComponent:0.55]);
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
