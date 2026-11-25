//
//  LiqTabInternal.h
//  LiqTab — iOS 16.3.1 liquid floating tab bar for Douyin 41.2.0
//
//  Shared internal declarations. Nothing here depends on Substrate/Logos.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LTOperatingMode) {
    LTOperatingModeAuto   = 0, // Try Douyin's built-in fake glass, fall back to custom renderer
    LTOperatingModeCustom = 1, // Always use our own UIVisualEffectView renderer
    LTOperatingModeNative = 2, // Only force Douyin's own flags, never draw our own bar
};

#pragma mark - Preferences

@interface LTPrefs : NSObject
+ (BOOL)enabled;
+ (LTOperatingMode)mode;
+ (CGFloat)sideInset;
+ (CGFloat)bottomInset;
+ (CGFloat)barHeight;
+ (CGFloat)cornerRadius;
+ (NSInteger)blurStyle;
+ (BOOL)showLabels;
+ (BOOL)hapticsEnabled;
+ (BOOL)debugLog;
+ (BOOL)forceNativeFlags; // whether to inject ABTest keys at all
+ (NSInteger)glassAppearance; // 0 auto, 1 light (乳白磨砂), 2 dark (深色磨砂)
+ (BOOL)showSelectionPill;
@end

#pragma mark - Glass view

@interface LTCustomGlassView : UIView
@property (nonatomic, assign) CGFloat glassRadius;
@property (nonatomic, strong, readonly) UIVisualEffectView *blurView;
@property (nonatomic, strong, readonly) UIView *tintView;
@property (nonatomic, strong, readonly) UIView *selectionPill;
- (void)applyStyleForUserInterfaceStyle:(UIUserInterfaceStyle)style;
- (void)setSelectionFrame:(CGRect)frame animated:(BOOL)animated;
@end

#pragma mark - Mirrored item

@interface LTTabItemView : UIControl
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, weak, nullable) id originalButton;
@property (nonatomic, assign) BOOL itemSelected;
@property (nonatomic, copy, nullable) void (^tapBlock)(LTTabItemView *item);
+ (void)setInkColor:(nullable UIColor *)color;
- (void)applyTint;
@end

#pragma mark - Mirror controller

@interface LTTabBarMirror : NSObject
- (instancetype)initWithTabBar:(UIView *)tabBar NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)apply;
- (void)synchronize;
- (void)detach;
@property (nonatomic, readonly) BOOL applied;
@property (nonatomic, readonly) BOOL attached;
- (BOOL)isAttachedToBar:(UIView *)bar;
@end

#pragma mark - Utilities

void LTLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
BOOL LTViewContainsKind(UIView *root, Class cls);
IMP LTReplaceMethod(Class cls, SEL sel, IMP newImp);

// Shared associated-object key (must be the SAME address in every translation unit).
extern char kLTMirrorKey;

NS_ASSUME_NONNULL_END
