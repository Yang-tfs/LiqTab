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

        // Shadow lives on self's layer; the capsule itself clips its children,
        // but the shadow path is set to the capsule so it escapes correctly.
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.28;
        self.layer.shadowRadius = 14.0;
        self.layer.shadowOffset = CGSizeMake(0, 6);

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
    switch (style) {
        case 1: return [UIBlurEffect effectWithStyle:
                    dark ? UIBlurEffectStyleSystemThinMaterialDark : UIBlurEffectStyleSystemThinMaterialLight];
        case 2: return [UIBlurEffect effectWithStyle:
                    dark ? UIBlurEffectStyleSystemMaterialDark : UIBlurEffectStyleSystemMaterialLight];
        case 3: return [UIBlurEffect effectWithStyle:
                    dark ? UIBlurEffectStyleSystemThickMaterialDark : UIBlurEffectStyleSystemThickMaterialLight];
        case 4: return [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        default: return [UIBlurEffect effectWithStyle:
                    dark ? UIBlurEffectStyleSystemUltraThinMaterialDark : UIBlurEffectStyleSystemUltraThinMaterialLight];
    }
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
    if (style == UIUserInterfaceStyleUnspecified) {
        style = self.traitCollection.userInterfaceStyle;
    }
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
    _tintView.backgroundColor = dark
        ? [[UIColor blackColor] colorWithAlphaComponent:0.10]
        : [[UIColor whiteColor] colorWithAlphaComponent:0.07];

    CGFloat sheen = dark ? 0.14 : 0.30;
    _specularLayer.colors = @[
        (id)[[UIColor whiteColor] colorWithAlphaComponent:sheen].CGColor,
        (id)[[UIColor whiteColor] colorWithAlphaComponent:sheen * 0.18].CGColor,
        (id)[UIColor clearColor].CGColor
    ];
    _rimLayer.strokeColor = (dark
        ? [[UIColor whiteColor] colorWithAlphaComponent:0.16]
        : [[UIColor whiteColor] colorWithAlphaComponent:0.30]).CGColor;
    _topHairline.strokeColor = (dark
        ? [[UIColor whiteColor] colorWithAlphaComponent:0.22]
        : [[UIColor whiteColor] colorWithAlphaComponent:0.50]).CGColor;

    _selectionPill.backgroundColor = (dark
        ? [[UIColor whiteColor] colorWithAlphaComponent:0.13]
        : [[UIColor blackColor] colorWithAlphaComponent:0.08]);
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
