//
//  LTPrefs.m
//  LiqTab
//

#import "LiqTabInternal.h"
#import <objc/runtime.h>

// All preferences are plain NSUserDefaults so they can be tweaked without a
// preference bundle. If you add a settings UI later, just write these keys.

static NSString * const kEnabledKey      = @"LiqTab.enabled";
static NSString * const kModeKey         = @"LiqTab.mode";
static NSString * const kSideInsetKey    = @"LiqTab.sideInset";
static NSString * const kBottomInsetKey  = @"LiqTab.bottomInset";
static NSString * const kBarHeightKey    = @"LiqTab.barHeight";
static NSString * const kCornerRadiusKey = @"LiqTab.cornerRadius";
static NSString * const kBlurStyleKey    = @"LiqTab.blurStyle";
static NSString * const kShowLabelsKey   = @"LiqTab.showLabels";
static NSString * const kHapticsKey      = @"LiqTab.haptics";
static NSString * const kDebugLogKey     = @"LiqTab.debugLog";
static NSString * const kForceNativeKey  = @"LiqTab.forceNativeFlags";

@implementation LTPrefs

+ (NSUserDefaults *)defaults {
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:@"com.yang.liqtab"];
        if (!d) d = [NSUserDefaults standardUserDefaults];
    });
    return d;
}

+ (BOOL)enabled {
    id v = [[self defaults] objectForKey:kEnabledKey];
    return v ? [v boolValue] : YES; // enabled by default
}

+ (LTOperatingMode)mode {
    id v = [[self defaults] objectForKey:kModeKey];
    NSInteger raw = v ? [v integerValue] : 0;
    if (raw < 0 || raw > 2) raw = 0;
    return (LTOperatingMode)raw;
}

+ (CGFloat)sideInset {
    id v = [[self defaults] objectForKey:kSideInsetKey];
    return v ? [v floatValue] : 14.0;
}

+ (CGFloat)bottomInset {
    id v = [[self defaults] objectForKey:kBottomInsetKey];
    return v ? [v floatValue] : 14.0;
}

+ (CGFloat)barHeight {
    id v = [[self defaults] objectForKey:kBarHeightKey];
    CGFloat h = v ? [v floatValue] : 58.0;
    return MIN(MAX(h, 44.0), 80.0);
}

+ (CGFloat)cornerRadius {
    id v = [[self defaults] objectForKey:kCornerRadiusKey];
    CGFloat r = v ? [v floatValue] : 0.0; // 0 = capsule (height/2)
    return r;
}

+ (NSInteger)blurStyle {
    id v = [[self defaults] objectForKey:kBlurStyleKey];
    NSInteger n = v ? [v integerValue] : 0;
    if (n < 0 || n > 4) n = 0;
    return n;
}

+ (BOOL)showLabels {
    id v = [[self defaults] objectForKey:kShowLabelsKey];
    return v ? [v boolValue] : YES;
}

+ (BOOL)hapticsEnabled {
    id v = [[self defaults] objectForKey:kHapticsKey];
    return v ? [v boolValue] : YES;
}

+ (BOOL)debugLog {
    id v = [[self defaults] objectForKey:kDebugLogKey];
    return v ? [v boolValue] : NO;
}

+ (BOOL)forceNativeFlags {
    id v = [[self defaults] objectForKey:kForceNativeKey];
    return v ? [v boolValue] : YES;
}

@end

void LTLog(NSString *fmt, ...) {
    if (![LTPrefs debugLog]) return;
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[LiqTab] %@", msg);
}

BOOL LTViewContainsKind(UIView *root, Class cls) {
    if (!root || !cls) return NO;
    if ([root isKindOfClass:cls]) return YES;
    for (UIView *sub in root.subviews) {
        if (LTViewContainsKind(sub, cls)) return YES;
    }
    return NO;
}

// Generic swizzle helper. Uses class_getInstanceMethod so it also replaces
// inherited implementations correctly.
IMP LTReplaceMethod(Class cls, SEL sel, IMP newImp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    const char *types = method_getTypeEncoding(m);
    IMP old = class_replaceMethod(cls, sel, newImp, types);
    if (!old) {
        // Method was inherited; add our own and return the super implementation.
        class_addMethod(cls, sel, newImp, types ?: "v@:");
        old = class_getMethodImplementation(class_getSuperclass(cls), sel);
    }
    return old;
}
