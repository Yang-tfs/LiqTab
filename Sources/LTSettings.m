//
//  LTSettings.m
//  LiqTab — 在抖音设置页注入「LiqTab 液态底栏」入口与设置面板。
//
//  参考 DYKiller / DYYY 的做法，但用纯 Objective-C Runtime（无 Logos/Substrate），
//  以便和 DYYY 共存。DYYY 也 hook 了同样的两个方法，但我们只动「返回的数组」，
//  不改视图层级，所以不会造成布局递归卡死。
//

#import "LiqTabInternal.h"
#import <objc/runtime.h>
#import <objc/message.h>

static char kLTViewModelKey;       // 我们手动创建的设置页挂 viewmodel
static char LTOwnItemKey;          // 标记「本插件的设置项」，避免误伤 DYYY 的 cell

static NSString * const kEntrySectionTitle = @"LiqTab";
static NSString * const kMainPageMarker    = @"账号";   // 抖音设置主页分区标题
static NSString * const kAltMainMarker     = @"Account"; // 英文兜底

// 前向声明（函数在使用之后才定义）
static UIViewController *LTCurrentSettingsVC(void);
static UIViewController *LTMakeSettingsPage(NSString *title, NSArray *sections);
static NSArray *LTBuildDetailSections(void);

#pragma mark - 反射访问器（全部 KVC，零硬链接私有符号）

static id LTObj(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (NSException *e) { return nil; }
}
static void LTSetObj(id obj, NSString *key, id value) {
    if (!obj) return;
    @try { [obj setValue:value forKey:key]; }
    @catch (NSException *e) { }
}
static BOOL LTHasProp(id obj, NSString *key) {
    return obj && [obj respondsToSelector:NSSelectorFromString(key)];
}

#pragma mark - 保存的原 IMP（链式调用）

static IMP sOrigSectionDataArray = NULL;
static IMP sOrigViewModelGetter  = NULL;
static BOOL sHooksInstalled = NO;

#pragma mark - 设置项工厂

static id LTMakeItem(NSString *identifier, NSString *title, NSString *detail, NSInteger cellType) {
    Class itemCls = NSClassFromString(@"AWESettingItemModel");
    if (!itemCls) return nil;
    id item = [[itemCls alloc] init];
    LTSetObj(item, @"identifier", identifier);
    LTSetObj(item, @"title", title);
    LTSetObj(item, @"detail", detail ?: @"");
    LTSetObj(item, @"type", @0);
    LTSetObj(item, @"cellType", @(cellType));
    LTSetObj(item, @"isEnable", @YES);
    // 打标：本插件自己的项
    objc_setAssociatedObject(item, &LTOwnItemKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return item;
}

// 开关行（cellType 6）
static id LTMakeSwitch(NSString *key, NSString *title, NSString *detail) {
    id item = LTMakeItem(key, title, detail, 6);
    if (!item) return nil;
    BOOL initialOn = [[LTPrefs valueForSettingKey:key] boolValue];
    // 未设置过的开关给默认值（总开关、胶囊、震动默认开）。
    if (![LTPrefs valueForSettingKey:key]) initialOn = YES;
    LTSetObj(item, @"isSwitchOn", @(initialOn));

    __weak id weakItem = item;
    void (^changed)(void) = ^{
        __strong id it = weakItem;
        if (!it) return;
        BOOL on = ![LTObj(it, @"isSwitchOn") boolValue];
        LTSetObj(it, @"isSwitchOn", @(on));
        LTLog(@"设置开关 %@ -> %@", key, on ? @"开" : @"关");
        [LTPrefs setValue:@(on) forSettingKey:key];
    };
    if (LTHasProp(item, @"setSwitchChangedBlock:")) {
        [item performSelector:NSSelectorFromString(@"setSwitchChangedBlock:") withObject:changed];
    }
    return item;
}

// 可点击选择行（cellType 26）：用 actionSheet 选值
static id LTMakeChoice(NSString *key, NSString *title, NSArray<NSString *> *options,
                       NSInteger current, NSString *iconName) {
    id item = LTMakeItem(key, title, options[current], 26);
    if (!item) return nil;
    if (iconName && LTHasProp(item, @"setSvgIconImageName:")) {
        LTSetObj(item, @"svgIconImageName", iconName);
    }

    __weak id weakItem = item;
    void (^tapped)(void) = ^{
        __strong id it = weakItem;
        if (!it) return;
        UIViewController *presenter = LTCurrentSettingsVC();
        if (!presenter) return;
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSInteger i = 0; i < (NSInteger)options.count; i++) {
            [sheet addAction:[UIAlertAction actionWithTitle:options[i]
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) {
                [LTPrefs setValue:@(i) forSettingKey:key];
                LTSetObj(it, @"detail", options[i]);
                [LTPrefs setValue:@(i) forSettingKey:key]; // 发通知刷新玻璃
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        // iPad 弹窗需要设置 popoverPresentationController
        if (sheet.popoverPresentationController) {
            sheet.popoverPresentationController.sourceView = presenter.view;
            sheet.popoverPresentationController.sourceRect = CGRectMake(
                CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
        }
        [presenter presentViewController:sheet animated:YES completion:nil];
    };
    if (LTHasProp(item, @"setCellTappedBlock:")) {
        [item performSelector:NSSelectorFromString(@"setCellTappedBlock:") withObject:tapped];
    }
    return item;
}

// 数值型选择行：显示文案与写入的实际值分开（尺寸 preference 存的是 pt 数值）。
static id LTMakeValueChoice(NSString *key, NSString *title, NSArray<NSString *> *titles,
                            NSArray<NSNumber *> *values, NSInteger current, NSString *iconName) {
    NSInteger safe = MIN(MAX(current, 0), (NSInteger)titles.count - 1);
    id item = LTMakeItem(key, title, titles[safe], 26);
    if (!item) return nil;
    if (iconName && LTHasProp(item, @"setSvgIconImageName:")) {
        LTSetObj(item, @"svgIconImageName", iconName);
    }
    __weak id weakItem = item;
    void (^tapped)(void) = ^{
        __strong id it = weakItem;
        if (!it) return;
        UIViewController *presenter = LTCurrentSettingsVC();
        if (!presenter) return;
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
            [sheet addAction:[UIAlertAction actionWithTitle:titles[i]
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction *a) {
                [LTPrefs setValue:values[i] forSettingKey:key];
                LTSetObj(it, @"detail", titles[i]);
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        if (sheet.popoverPresentationController) {
            sheet.popoverPresentationController.sourceView = presenter.view;
            sheet.popoverPresentationController.sourceRect = CGRectMake(
                CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 1, 1);
        }
        [presenter presentViewController:sheet animated:YES completion:nil];
    };
    if (LTHasProp(item, @"setCellTappedBlock:")) {
        [item performSelector:NSSelectorFromString(@"setCellTappedBlock:") withObject:tapped];
    }
    return item;
}

// 二级页面入口（cellType 26，直接 push 页面）
static id LTMakePageEntry(NSString *identifier, NSString *title, NSString *detail,
                          NSString *iconName, NSArray * (^buildSections)(void)) {
    id item = LTMakeItem(identifier, title, detail, 26);
    if (!item) return nil;
    if (iconName && LTHasProp(item, @"setSvgIconImageName:")) {
        LTSetObj(item, @"svgIconImageName", iconName);
    }
    void (^tapped)(void) = ^{
        NSArray *sections = buildSections ? buildSections() : nil;
        if (!sections) return;
        UIViewController *presenter = LTCurrentSettingsVC();
        UINavigationController *nav = presenter.navigationController;
        if (!nav) return;
        [nav pushViewController:LTMakeSettingsPage(title, sections) animated:YES];
    };
    if (LTHasProp(item, @"setCellTappedBlock:")) {
        [item performSelector:NSSelectorFromString(@"setCellTappedBlock:") withObject:tapped];
    }
    return item;
}

#pragma mark - 页面与 section 构造

static id LTMakeSection(NSString *header, NSString *footer, NSArray *items) {
    Class secCls = NSClassFromString(@"AWESettingSectionModel");
    if (!secCls) return nil;
    id sec = [[secCls alloc] init];
    LTSetObj(sec, @"sectionHeaderTitle", header);
    if (LTHasProp(sec, @"setSectionHeaderHeight:")) LTSetObj(sec, @"sectionHeaderHeight", @40);
    LTSetObj(sec, @"type", @0);
    LTSetObj(sec, @"itemArray", items ?: @[]);
    if (footer.length && LTHasProp(sec, @"setSectionFooterTitle:")) {
        LTSetObj(sec, @"sectionFooterTitle", footer);
        if (LTHasProp(sec, @"setUseNewFooterLayout:")) LTSetObj(sec, @"useNewFooterLayout", @YES);
    }
    return sec;
}

static UIViewController *LTMakeSettingsPage(NSString *title, NSArray *sections) {
    Class vcCls = NSClassFromString(@"AWESettingBaseViewController");
    Class vmCls = NSClassFromString(@"AWESettingsViewModel");
    if (!vcCls || !vmCls) return nil;
    id page = [[vcCls alloc] init];
    if (LTHasProp(page, @"setUseCardUIStyle:")) LTSetObj(page, @"useCardUIStyle", @YES);
    if (LTHasProp(page, @"setColorStyle:")) LTSetObj(page, @"colorStyle", @2);

    id vm = [[vmCls alloc] init];
    if (LTHasProp(vm, @"setColorStyle:")) LTSetObj(vm, @"colorStyle", @2);
    LTSetObj(vm, @"sectionDataArray", sections);

    // 手动创建的页面 viewModel getter 会返回 nil，用关联对象兜底。
    objc_setAssociatedObject(page, &kLTViewModelKey, vm, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 设置导航标题（手动建页没有 title setter）
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *view = ((UIViewController *)page).view;
        Class navCls = NSClassFromString(@"AWENavigationBar");
        for (UIView *sub in view.subviews) {
            if (navCls && [sub isKindOfClass:navCls]) {
                UILabel *label = LTObj(sub, @"titleLabel");
                if ([label isKindOfClass:[UILabel class]]) label.text = title;
                break;
            }
        }
    });
    return (UIViewController *)page;
}

// 当前正在显示的设置页（由 viewModel getter hook 记录）
static UIViewController *sCurrentSettingsVC = nil; // weak-ish: 不做 strong 持有
static UIViewController *LTCurrentSettingsVC(void) {
    if (sCurrentSettingsVC && sCurrentSettingsVC.view.window) return sCurrentSettingsVC;
    // 兜底：从 keyWindow 的 nav 栈找 AWESettingBaseViewController
    UIWindow *win = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
    } else {
        win = [[UIApplication sharedApplication] keyWindow];
    }
    UIViewController *vc = win.rootViewController;
    Class settingsVCCls = NSClassFromString(@"AWESettingBaseViewController");
    int guard = 0;
    while (vc && guard++ < 20) {
        if (settingsVCCls && [vc isKindOfClass:settingsVCCls]) return vc;
        UIViewController *next = nil;
        if ([vc isKindOfClass:[UINavigationController class]]) {
            next = ((UINavigationController *)vc).topViewController;
        }
        if (!next) next = vc.presentedViewController;
        if (next == vc) break;  // 防止自引用死循环
        vc = next;
    }
    return nil;
}

#pragma mark - 设置面板内容

static NSArray *LTBuildMainSections(void) {
    NSString *ver = @"1.0";
    id entry = LTMakeItem(@"LiqTabEntry", @"LiqTab 液态底栏", ver, 26);
    if (LTHasProp(entry, @"setSvgIconImageName:")) LTSetObj(entry, @"svgIconImageName", @"ic_gearsimplify_outlined_20");
    __weak id weakEntry = entry;
    void (^tapped)(void) = ^{
        UIViewController *presenter = LTCurrentSettingsVC();
        UINavigationController *nav = presenter.navigationController;
        if (!nav) return;
        [nav pushViewController:LTMakeSettingsPage(@"LiqTab 液态底栏", LTBuildDetailSections()) animated:YES];
    };
    if (LTHasProp(entry, @"setCellTappedBlock:")) [entry performSelector:NSSelectorFromString(@"setCellTappedBlock:") withObject:tapped];
    id sec = LTMakeSection(kEntrySectionTitle, @"iOS 16.3+ · 与 DYYY 共存", @[entry]);
    return sec ? @[sec] : @[];
}

static NSArray *LTBuildDetailSections(void) {
    NSMutableArray *items = [NSMutableArray array];

    // 总开关
    id enable = LTMakeSwitch(@"enabled", @"启用液态底栏", @"关闭后恢复原生底栏");
    if (enable) [items addObject:enable];

    // 材质外观（核心，用户最常调）
    NSInteger appIdx = [LTPrefs glassAppearance];
    id app = LTMakeChoice(@"glassAppearance", @"玻璃外观", @[@"自动", @"乳白磨砂", @"深色磨砂"],
                          appIdx, @"ic_palette_outlined_20");
    if (app) [items addObject:app];

    // 模糊强度
    NSInteger blurIdx = [LTPrefs blurStyle];
    id blur = LTMakeChoice(@"blurStyle", @"模糊强度", @[@"清透", @"薄磨砂", @"标准磨砂", @"厚磨砂", @"纯深色"],
                           blurIdx, @"ic_blur_on_outlined_20");
    if (blur) [items addObject:blur];

    // 选中胶囊
    id pill = LTMakeSwitch(@"showSelectionPill", @"显示选中胶囊", @"选中项显示高亮胶囊");
    if (pill) [items addObject:pill];

    // 点击震动
    id haptics = LTMakeSwitch(@"haptics", @"点击震动反馈", nil);
    if (haptics) [items addObject:haptics];

    // 调试日志（默认关：LTMakeSwitch 对未设置项默认 YES，这里显式写默认值 NO）
    if (![LTPrefs valueForSettingKey:@"debugLog"]) [LTPrefs setValue:@NO forSettingKey:@"debugLog"];
    id debug = LTMakeSwitch(@"debugLog", @"调试日志", @"需重启抖音，日志输出到控制台");
    if (debug) [items addObject:debug];

    id sec1 = LTMakeSection(@"外观", @"设置即时生效，无需重启抖音", items);

    // 尺寸（写入实际 pt 数值）
    NSMutableArray *sizeItems = [NSMutableArray array];
    CGFloat curSide = [LTPrefs sideInset];
    NSInteger sideIdx = 1;
    if (curSide <= 8) sideIdx = 0; else if (curSide >= 26) sideIdx = 3; else if (curSide >= 20) sideIdx = 2;
    id side = LTMakeValueChoice(@"sideInset", @"左右边距", @[@"8 pt", @"14 pt", @"20 pt", @"26 pt"],
                                @[@8, @14, @20, @26], sideIdx, nil);
    if (side) [sizeItems addObject:side];

    CGFloat curH = [LTPrefs barHeight];
    NSInteger hIdx = 1;
    if (curH <= 50) hIdx = 0; else if (curH >= 66) hIdx = 2;
    id height = LTMakeValueChoice(@"barHeight", @"胶囊高度", @[@"50 pt", @"58 pt", @"66 pt"],
                                  @[@50, @58, @66], hIdx, nil);
    if (height) [sizeItems addObject:height];
    id sec2 = LTMakeSection(@"尺寸", nil, sizeItems);

    // 运行模式：默认自动，原生不生效时必定用自绘兜底
    NSInteger modeIdx = [LTPrefs mode];
    id mode = LTMakeChoice(@"mode", @"运行模式",
                           @[@"自动（推荐）", @"纯自绘", @"仅原生"],
                           modeIdx, nil);
    NSMutableArray *modeItems = [NSMutableArray array];
    if (mode) [modeItems addObject:mode];
    id sec3 = LTMakeSection(@"高级", @"纯自绘=只用玻璃胶囊；仅原生=只试抖音自带实现", modeItems);

    NSMutableArray *result = [NSMutableArray array];
    if (sec1) [result addObject:sec1];
    if (sec2) [result addObject:sec2];
    if (sec3) [result addObject:sec3];
    return result;
}

#pragma mark - Hook 实现

// -[AWESettingsViewModel sectionDataArray]
static NSArray *LTSectionDataArrayHook(id self, SEL _cmd) {
    NSArray *sections = nil;
    if (sOrigSectionDataArray) {
        sections = ((NSArray *(*)(id, SEL))sOrigSectionDataArray)(self, _cmd);
    }
    if (![sections isKindOfClass:[NSArray class]]) return sections;

    BOOL isMain = NO, exists = NO;
    for (id s in sections) {
        NSString *title = LTObj(s, @"sectionHeaderTitle");
        if (![title isKindOfClass:[NSString class]]) continue;
        if ([title isEqualToString:kMainPageMarker] || [title isEqualToString:kAltMainMarker]) isMain = YES;
        if ([title isEqualToString:kEntrySectionTitle]) exists = YES;
    }
    if (!isMain || exists) return sections;

    NSMutableArray *result = [NSMutableArray arrayWithArray:sections];
    NSArray *ourSections = LTBuildMainSections();
    // 插到第二位（第 0 位常留给 DYYY / DYKiller 的入口）
    NSInteger idx = MIN(1, (NSInteger)result.count);
    [result insertObjects:ourSections
                atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(idx, ourSections.count)]];
    return result;
}

// -[AWESettingBaseViewController viewModel] getter
static id LTViewModelGetterHook(id self, SEL _cmd) {
    id vm = nil;
    if (sOrigViewModelGetter) vm = ((id (*)(id, SEL))sOrigViewModelGetter)(self, _cmd);
    if (!vm) {
        id attached = objc_getAssociatedObject(self, &kLTViewModelKey);
        if (attached) {
            // 记录当前设置页（弱引用语义：只在不持有 window 时清掉）
            sCurrentSettingsVC = (UIViewController *)self;
            return attached;
        }
    }
    if ([self isKindOfClass:NSClassFromString(@"AWESettingBaseViewController")] && vm) {
        sCurrentSettingsVC = (UIViewController *)self;
    }
    return vm;
}

void LTInstallSettingsHooks(void) {
    if (sHooksInstalled) return;

    Class vmCls = NSClassFromString(@"AWESettingsViewModel");
    Class vcCls = NSClassFromString(@"AWESettingBaseViewController");
    if (!vmCls || !vcCls) {
        LTLog(@"设置相关类未找到，跳过设置入口注入");
        return;
    }

    // hook sectionDataArray
    SEL sel1 = NSSelectorFromString(@"sectionDataArray");
    Method m1 = class_getInstanceMethod(vmCls, sel1);
    if (m1) {
        sOrigSectionDataArray = method_getImplementation(m1);
        IMP rep = (IMP)LTSectionDataArrayHook;
        if (!class_replaceMethod(vmCls, sel1, rep, method_getTypeEncoding(m1))) {
            class_addMethod(vmCls, sel1, rep, method_getTypeEncoding(m1));
        }
    }

    // hook viewModel getter
    SEL sel2 = NSSelectorFromString(@"viewModel");
    Method m2 = class_getInstanceMethod(vcCls, sel2);
    if (m2) {
        sOrigViewModelGetter = method_getImplementation(m2);
        IMP rep = (IMP)LTViewModelGetterHook;
        if (!class_replaceMethod(vcCls, sel2, rep, method_getTypeEncoding(m2))) {
            class_addMethod(vcCls, sel2, rep, method_getTypeEncoding(m2));
        }
    }

    sHooksInstalled = YES;
    LTLog(@"设置入口注入已安装");
}
