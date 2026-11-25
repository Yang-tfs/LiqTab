//
//  LTTabItemView.m
//  LiqTab
//

#import "LiqTabInternal.h"
#import <objc/runtime.h>

static UIColor *sInkColor = nil;

@implementation LTTabItemView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor clearColor];
        self.exclusiveTouch = NO;

        _imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.userInteractionEnabled = NO;
        [self addSubview:_imageView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightMedium];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.userInteractionEnabled = NO;
        [self addSubview:_titleLabel];

        _badgeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _badgeLabel.font = [UIFont boldSystemFontOfSize:9.0];
        _badgeLabel.textColor = [UIColor whiteColor];
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        _badgeLabel.backgroundColor = [UIColor systemRedColor];
        _badgeLabel.layer.cornerRadius = 7.0;
        _badgeLabel.clipsToBounds = YES;
        _badgeLabel.hidden = YES;
        _badgeLabel.userInteractionEnabled = NO;
        [self addSubview:_badgeLabel];

        [self addTarget:self
                 action:@selector(didTap)
       forControlEvents:UIControlEventTouchUpInside];
        [self applyTint];
    }
    return self;
}

+ (void)setInkColor:(UIColor *)color {
    sInkColor = color;
}

- (void)setItemSelected:(BOOL)selected {
    _itemSelected = selected;
    [self applyTint];
}

- (void)applyTint {
    UIColor *ink = sInkColor ?: [UIColor labelColor];
    UIColor *normal = [ink colorWithAlphaComponent:0.55];
    UIColor *active = ink;
    UIColor *target = _itemSelected ? active : normal;

    // Render template images with the resolved ink color so the icons match
    // Douyin's own current theme (light/dark and selected/unselected).
    if (self.imageView.image) {
        UIImage *base = self.imageView.image;
        if (base.renderingMode != UIImageRenderingModeAlwaysTemplate) {
            base = [base imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            self.imageView.image = base;
        }
        self.imageView.tintColor = target;
    }
    self.titleLabel.textColor = target;

    if (_itemSelected) {
        self.transform = CGAffineTransformMakeScale(1.08, 1.08);
    } else {
        self.transform = CGAffineTransformIdentity;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    BOOL showTitle = [LTPrefs showLabels] && self.titleLabel.text.length > 0;
    CGFloat imageH = showTitle ? CGRectGetHeight(b) * 0.58 : CGRectGetHeight(b) * 0.72;
    CGFloat imageY = showTitle ? 5.0 : (CGRectGetHeight(b) - imageH) / 2.0;
    self.imageView.frame = CGRectMake(0, imageY, CGRectGetWidth(b), imageH);
    if (showTitle) {
        self.titleLabel.frame = CGRectMake(0, CGRectGetMaxY(self.imageView.frame) + 1.0,
                                           CGRectGetWidth(b), 13.0);
    } else {
        self.titleLabel.frame = CGRectZero;
    }

    if (!self.badgeLabel.hidden) {
        CGSize s = [self.badgeLabel.text sizeWithAttributes:@{NSFontAttributeName: self.badgeLabel.font}];
        CGFloat w = MAX(s.width + 10.0, 14.0);
        self.badgeLabel.frame = CGRectMake(CGRectGetMidX(b) + 7.0, 1.0, w, 14.0);
    }
}

- (void)didTap {
    if (_tapBlock) _tapBlock(self);
    if ([LTPrefs hapticsEnabled]) {
        if (@available(iOS 13.0, *)) {
            UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc]
                initWithStyle:UIImpactFeedbackStyleSoft];
            [g impactOccurred];
        }
    }
}

// Make hit testing slightly taller than the visual frame; the capsule has
// rounded ends so buttons near the edge are still comfortable to tap.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect expanded = CGRectInset(self.bounds, -4, -10);
    if (CGRectContainsPoint(expanded, point)) return self;
    return [super hitTest:point withEvent:event];
}

@end
