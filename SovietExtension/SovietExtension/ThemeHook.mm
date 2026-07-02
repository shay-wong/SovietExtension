//
//  ThemeHook.m
//  SovietExtension
//
//  Created by MustangYM on 2026/6/20.
//

#import "ThemeHook.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "RevokePatch.h"

#pragma mark - UserDefaults Keys

/// 是否启用迷离模式。
static NSString * const kYMThemeMistyMode = @"kThemeMistyMode.SOVIET";

/// QNSView 透明度。1.0 = 不透明；越小越透。
static NSString * const kYMThemeMistyQNSAlpha = @"kThemeMistyQNSAlpha.SOVIET";

/// 是否启用 WindowServer 背景模糊。
static NSString * const kYMThemeMistyWindowBlurEnabled = @"kThemeMistyWindowBlurEnabled.SOVIET";

/// 背景模糊半径。
static NSString * const kYMThemeMistyWindowBlurRadius = @"kThemeMistyWindowBlurRadius.SOVIET";

/// carrier 风格：dark / light。
static NSString * const kYMThemeMistyCarrierStyle = @"kThemeMistyCarrierStyle.SOVIET";
static NSString * const kYMThemeMistyCarrierStyleDark = @"dark";
static NSString * const kYMThemeMistyCarrierStyleLight = @"light";

/// 是否定期重新应用 blur。
static NSString * const kYMThemeMistyKeepAlive = @"kThemeMistyKeepAlive.SOVIET";

#pragma mark - 默认值

static const BOOL kYMDefaultMistyModeEnabled = YES;
static const CGFloat kYMDefaultQNSViewAlphaValue = 0.90f;
static const BOOL kYMDefaultWindowBackgroundBlurEnabled = YES;
static const int kYMDefaultWindowBackgroundBlurRadius = 35;
static const BOOL kYMDefaultBlurKeepAliveEnabled = YES;
static NSString * const kYMDefaultCarrierStyle = @"dark";

/// 用户不直接设置这个值。
/// 深色 carrier：你测试出的最佳值 0.3。
/// 浅色 carrier：你测试出的最佳值 0.015。
static const CGFloat kYMCarrierAlphaDark = 0.30f;
static const CGFloat kYMCarrierAlphaLight = 0.015f;

static const NSTimeInterval kYMBlurKeepAliveInterval = 2.0;

#pragma mark - 私有 CGS 接口声明

/// 这里不直接链接私有符号，而是运行时 dlsym，避免链接阶段报错。
typedef int YMCGSConnectionID;
typedef int YMCGSWindowID;
typedef int (*YMCGSMainConnectionIDFunc)(void);
typedef CGError (*YMCGSSetWindowBackgroundBlurRadiusFunc)(YMCGSConnectionID cid,
                                                          YMCGSWindowID wid,
                                                          int radius);

static YMCGSMainConnectionIDFunc gYMCGSMainConnectionID = NULL;
static YMCGSSetWindowBackgroundBlurRadiusFunc gYMCGSSetWindowBackgroundBlurRadius = NULL;
static BOOL gYMCGSBlurResolved = NO;
static BOOL gYMCGSBlurResolveFailedLogged = NO;

#pragma mark - 原始 IMP

typedef BOOL (*YMIsOpaqueIMP)(id self, SEL _cmd);
typedef void (*YMVoidIMP)(id self, SEL _cmd);
typedef void (*YMOneObjectIMP)(id self, SEL _cmd, id arg);

static YMIsOpaqueIMP gOrig_QNSView_isOpaque = NULL;
static YMVoidIMP gOrig_QNSView_viewDidMoveToWindow = NULL;
static YMVoidIMP gOrig_QNSView_viewDidMoveToSuperview = NULL;
static YMOneObjectIMP gOrig_QNSView_setLayer = NULL;

#pragma mark - 状态

static BOOL gYMStarted = NO;
static BOOL gYMQNSViewHookInstalled = NO;
static BOOL gYMBlurKeepAliveStarted = NO;

/// 防止处理背景过程中触发 setLayer / view move 后递归。
static BOOL gYMApplyingBlurBackground = NO;

/// 用于记录窗口上一次应用的 blur radius，避免重复刷日志。
static char kYMAppliedBlurRadiusAssociatedKey;
static char kYMAppliedBlurWindowNumberAssociatedKey;

#pragma mark - 配置读取

static void YMRegisterMistyThemeDefaults(void) {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kYMThemeMistyMode: @(kYMDefaultMistyModeEnabled),
        kYMThemeMistyQNSAlpha: @(kYMDefaultQNSViewAlphaValue),
        kYMThemeMistyWindowBlurEnabled: @(kYMDefaultWindowBackgroundBlurEnabled),
        kYMThemeMistyWindowBlurRadius: @(kYMDefaultWindowBackgroundBlurRadius),
        kYMThemeMistyCarrierStyle: kYMDefaultCarrierStyle,
        kYMThemeMistyKeepAlive: @(kYMDefaultBlurKeepAliveEnabled),
    }];
}

static BOOL YMBoolSetting(NSString *key, BOOL defaultValue) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:key] == nil) {
        return defaultValue;
    }
    return [defaults boolForKey:key];
}

static CGFloat YMFloatSetting(NSString *key, CGFloat defaultValue) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:key] == nil) {
        return defaultValue;
    }
    return (CGFloat)[defaults doubleForKey:key];
}

static NSInteger YMIntegerSetting(NSString *key, NSInteger defaultValue) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:key] == nil) {
        return defaultValue;
    }
    return [defaults integerForKey:key];
}

static NSString *YMStringSetting(NSString *key, NSString *defaultValue) {
    NSString *value = [[NSUserDefaults standardUserDefaults] stringForKey:key];
    if (value.length == 0) {
        return defaultValue;
    }
    return value;
}

static BOOL YMMistyModeEnabled(void) {
    return YMBoolSetting(kYMThemeMistyMode, kYMDefaultMistyModeEnabled);
}

static BOOL YMWindowBackgroundBlurEnabled(void) {
    if (!YMMistyModeEnabled()) return NO;
    return YMBoolSetting(kYMThemeMistyWindowBlurEnabled, kYMDefaultWindowBackgroundBlurEnabled);
}

static CGFloat YMQNSViewAlphaValue(void) {
    if (!YMMistyModeEnabled()) {
        return 1.0f;
    }

    CGFloat alpha = YMFloatSetting(kYMThemeMistyQNSAlpha, kYMDefaultQNSViewAlphaValue);
    alpha = MAX(0.20f, MIN(1.0f, alpha));
    return alpha;
}

static int YMWindowBackgroundBlurRadius(void) {
    if (!YMWindowBackgroundBlurEnabled()) {
        return 0;
    }

    NSInteger radius = YMIntegerSetting(kYMThemeMistyWindowBlurRadius, kYMDefaultWindowBackgroundBlurRadius);
    radius = MAX(0, MIN(100, radius));
    return (int)radius;
}

static BOOL YMBlurKeepAliveEnabled(void) {
    return YMBoolSetting(kYMThemeMistyKeepAlive, kYMDefaultBlurKeepAliveEnabled);
}

static BOOL YMCarrierStyleIsDark(void) {
    NSString *style = YMStringSetting(kYMThemeMistyCarrierStyle, kYMDefaultCarrierStyle);
    return ![style isEqualToString:kYMThemeMistyCarrierStyleLight];
}

static CGFloat YMWindowBlurCarrierAlpha(void) {
    if (!YMWindowBackgroundBlurEnabled() || YMWindowBackgroundBlurRadius() <= 0) {
        return 0.0f;
    }

    return YMCarrierStyleIsDark() ? kYMCarrierAlphaDark : kYMCarrierAlphaLight;
}

#pragma mark - 工具：判断 QNSView

static BOOL YMIsQNSView(NSView *view) {
    if (!view) return NO;

    Class qnsClass = NSClassFromString(@"QNSView");
    if (!qnsClass) return NO;

    return [view isKindOfClass:qnsClass];
}

/// 递归查找指定 view 树里是否存在 QNSView。
/// 只要窗口里没有 QNSView，就绝对不是微信 Qt 主界面窗口，不能套迷离模式。
static BOOL YMViewTreeContainsQNSView(NSView *view) {
    if (!view) return NO;

    if (YMIsQNSView(view)) {
        return YES;
    }

    NSArray<NSView *> *subviews = [view.subviews copy];
    for (NSView *subview in subviews) {
        if (YMViewTreeContainsQNSView(subview)) {
            return YES;
        }
    }

    return NO;
}

static BOOL YMShouldApplyMistyEffectToWindow(NSWindow *window, NSView *specificQNSView) {
    if (!window || !window.contentView) {
        return NO;
    }

    // 菜单栏图标、菜单、popover、tooltip 通常不是 normal level。
    // 微信主窗口 / 聊天窗口一般是 NSNormalWindowLevel。
    if (window.level != NSNormalWindowLevel) {
        return NO;
    }

    NSString *windowClassName = NSStringFromClass(window.class);
    NSArray<NSString *> *blockedClassKeywords = @[
        @"Status",
        @"Menu",
        @"Popover",
        @"Tooltip",
        @"Toolbar",
        @"TouchBar",
        @"Panel"
    ];

    for (NSString *keyword in blockedClassKeywords) {
        if ([windowClassName rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return NO;
        }
    }

    // 顶部菜单栏图标 / 状态栏相关窗口尺寸通常很小。
    // 微信主窗口和独立聊天窗口一般远大于这个阈值。
    NSRect frame = window.frame;
    if (frame.size.width < 360.0 || frame.size.height < 360.0) {
        return NO;
    }

    if (specificQNSView) {
        if (!YMIsQNSView(specificQNSView)) {
            return NO;
        }

        if (specificQNSView.window != window) {
            return NO;
        }

        return YES;
    }

    return YMViewTreeContainsQNSView(window.contentView);
}

#pragma mark - 工具：CGS 背景模糊

static BOOL YMResolveCGSBlurSymbolsIfNeeded(void) {
    if (gYMCGSBlurResolved) {
        return gYMCGSMainConnectionID && gYMCGSSetWindowBackgroundBlurRadius;
    }

    gYMCGSBlurResolved = YES;

    // 通常这两个符号可以从当前进程已经加载的 CoreGraphics / ApplicationServices 里找到。
    gYMCGSMainConnectionID = (YMCGSMainConnectionIDFunc)dlsym(RTLD_DEFAULT, "CGSMainConnectionID");
    gYMCGSSetWindowBackgroundBlurRadius = (YMCGSSetWindowBackgroundBlurRadiusFunc)dlsym(RTLD_DEFAULT, "CGSSetWindowBackgroundBlurRadius");

    if (!gYMCGSMainConnectionID || !gYMCGSSetWindowBackgroundBlurRadius) {
        void *handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY);
        if (handle) {
            if (!gYMCGSMainConnectionID) {
                gYMCGSMainConnectionID = (YMCGSMainConnectionIDFunc)dlsym(handle, "CGSMainConnectionID");
            }
            if (!gYMCGSSetWindowBackgroundBlurRadius) {
                gYMCGSSetWindowBackgroundBlurRadius = (YMCGSSetWindowBackgroundBlurRadiusFunc)dlsym(handle, "CGSSetWindowBackgroundBlurRadius");
            }
        }
    }

    if (!gYMCGSMainConnectionID || !gYMCGSSetWindowBackgroundBlurRadius) {
        void *handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
        if (handle) {
            if (!gYMCGSMainConnectionID) {
                gYMCGSMainConnectionID = (YMCGSMainConnectionIDFunc)dlsym(handle, "CGSMainConnectionID");
            }
            if (!gYMCGSSetWindowBackgroundBlurRadius) {
                gYMCGSSetWindowBackgroundBlurRadius = (YMCGSSetWindowBackgroundBlurRadiusFunc)dlsym(handle, "CGSSetWindowBackgroundBlurRadius");
            }
        }
    }

    BOOL ok = gYMCGSMainConnectionID && gYMCGSSetWindowBackgroundBlurRadius;
    if (!ok && !gYMCGSBlurResolveFailedLogged) {
        gYMCGSBlurResolveFailedLogged = YES;
        YMLog(@"CGS 背景模糊接口解析失败，当前系统可能不可用：CGSMainConnectionID=%p CGSSetWindowBackgroundBlurRadius=%p",
              gYMCGSMainConnectionID,
              gYMCGSSetWindowBackgroundBlurRadius);
    }

    return ok;
}

static void YMApplyWindowBackgroundBlur(NSWindow *window) {
    if (!window) return;

    NSInteger windowNumber = window.windowNumber;
    if (windowNumber <= 0) {
        // windowNumber 为 0 通常说明窗口还没真正进入 WindowServer，稍后 refresh 会再应用。
        return;
    }

    int radius = YMWindowBackgroundBlurRadius();

    // 如果 radius 为 0，也要调用一次 CGS，把旧 blur 关掉。
    if (!YMResolveCGSBlurSymbolsIfNeeded()) {
        return;
    }

    NSNumber *oldRadius = objc_getAssociatedObject(window, &kYMAppliedBlurRadiusAssociatedKey);
    NSNumber *oldWindowNumber = objc_getAssociatedObject(window, &kYMAppliedBlurWindowNumberAssociatedKey);
    if (oldRadius && oldWindowNumber &&
        oldRadius.intValue == radius &&
        oldWindowNumber.integerValue == windowNumber) {
        return;
    }

    YMCGSConnectionID cid = gYMCGSMainConnectionID();
    CGError err = gYMCGSSetWindowBackgroundBlurRadius(cid, (YMCGSWindowID)windowNumber, radius);

    objc_setAssociatedObject(window,
                             &kYMAppliedBlurRadiusAssociatedKey,
                             @(radius),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window,
                             &kYMAppliedBlurWindowNumberAssociatedKey,
                             @(windowNumber),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    YMLog(@"已应用窗口背景模糊：window=%@ windowNumber=%ld radius=%d err=%d",
          window,
          (long)windowNumber,
          radius,
          err);
}

#pragma mark - Cocoa 层：窗口与 View 透明 / blur carrier

static NSColor *YMWindowBlurCarrierColor(void) {
    if (!YMWindowBackgroundBlurEnabled() || YMWindowBackgroundBlurRadius() <= 0) {
        return [NSColor clearColor];
    }

    CGFloat alpha = MAX(0.0, MIN(1.0, YMWindowBlurCarrierAlpha()));
    CGFloat white = YMCarrierStyleIsDark() ? 0.0 : 1.0;

    return [NSColor colorWithCalibratedWhite:white alpha:alpha];
}

static void YMMakeWindowTransparent(NSWindow *window) {
    if (!window) return;

    window.opaque = NO;

    window.backgroundColor = YMWindowBlurCarrierColor();


    YMApplyWindowBackgroundBlur(window);
}

static void YMMakeViewTransparent(NSView *view) {
    if (!view) return;

    view.wantsLayer = YES;
    view.layer.opaque = NO;
    view.layer.backgroundColor = NSColor.clearColor.CGColor;

    if ([view respondsToSelector:@selector(setAlphaValue:)]) {
        // 这里不要设成 0，否则整个 Qt 内容都会不可见。
        view.alphaValue = YMQNSViewAlphaValue();
    }
}

static void YMMakeContainerBlurCarrier(NSView *container) {
    if (!container) return;

    container.wantsLayer = YES;
    container.layer.opaque = NO;

    container.layer.backgroundColor = YMWindowBlurCarrierColor().CGColor;
}

static void YMInstallBlurBackgroundBehindQNSView(NSView *qnsView) {
    if (!YMIsQNSView(qnsView)) return;
    if (gYMApplyingBlurBackground) return;

    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YMInstallBlurBackgroundBehindQNSView(qnsView);
        });
        return;
    }

    gYMApplyingBlurBackground = YES;

    @try {
        NSWindow *window = qnsView.window;
        if (!window) return;

        // 只处理真正的微信主界面 / 聊天界面窗口。
        // 避免误伤 macOS 菜单栏顶部的微信图标、菜单窗口、popover、设置窗口等。
        if (!YMShouldApplyMistyEffectToWindow(window, qnsView)) {
            return;
        }

        NSView *container = qnsView.superview ?: window.contentView;
        if (!container) return;

        // QNSView 必须已经是 container 的直接子 view，否则不要强行处理。
        if (qnsView.superview != container) {
            return;
        }

        YMMakeWindowTransparent(window);
        YMMakeContainerBlurCarrier(container);
        YMMakeViewTransparent(qnsView);

    }
    @finally {
        gYMApplyingBlurBackground = NO;
    }
}

static void YMInstallBlurBackgroundBehindQNSViewAsync(NSView *qnsView) {
    if (!qnsView) return;

    __weak NSView *weakView = qnsView;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSView *strongView = weakView;
        if (!strongView) return;

        YMInstallBlurBackgroundBehindQNSView(strongView);
    });
}

static void YMRefreshViewTree(NSView *view) {
    if (!view) return;

    if (YMIsQNSView(view)) {
        YMInstallBlurBackgroundBehindQNSView(view);
        return;
    }

    NSArray<NSView *> *subviews = [view.subviews copy];
    for (NSView *subview in subviews) {
        YMRefreshViewTree(subview);
    }
}

static void YMRefreshAllWindows(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YMRefreshAllWindows();
        });
        return;
    }

    YMRegisterMistyThemeDefaults();

    for (NSWindow *window in NSApp.windows) {
        if (!YMShouldApplyMistyEffectToWindow(window, nil)) {
            continue;
        }

        YMMakeWindowTransparent(window);

        // 只给真正的微信 Qt 主窗口设置 blur carrier。
        // 这样不会影响 macOS 菜单栏顶部的微信图标 / 菜单 / popover。
        YMMakeContainerBlurCarrier(window.contentView);

        YMRefreshViewTree(window.contentView);
    }
}

static void YMBlurKeepAliveTick(void) {
    if (!gYMBlurKeepAliveStarted) return;

    if (YMBlurKeepAliveEnabled()) {
        YMRefreshAllWindows();
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kYMBlurKeepAliveInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YMBlurKeepAliveTick();
    });
}

static void YMStartBlurKeepAliveIfNeeded(void) {
    if (gYMBlurKeepAliveStarted) return;

    gYMBlurKeepAliveStarted = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        YMBlurKeepAliveTick();
    });
}

#pragma mark - Runtime Hook：QNSView

static BOOL YM_QNSView_isOpaque(id self, SEL _cmd) {
    // 不要对所有 QNSView 都强制返回 NO。
    // 菜单栏图标 / 小窗口里如果也有 QNSView，强制非 opaque 也可能造成异常透明。
    if ([self isKindOfClass:[NSView class]]) {
        NSView *view = (NSView *)self;
        NSWindow *window = view.window;
        if (YMShouldApplyMistyEffectToWindow(window, view)) {
            return NO;
        }
    }

    if (gOrig_QNSView_isOpaque) {
        return gOrig_QNSView_isOpaque(self, _cmd);
    }

    return YES;
}

static void YM_QNSView_viewDidMoveToWindow(id self, SEL _cmd) {
    if (gOrig_QNSView_viewDidMoveToWindow) {
        gOrig_QNSView_viewDidMoveToWindow(self, _cmd);
    }

    if ([self isKindOfClass:[NSView class]]) {
        YMInstallBlurBackgroundBehindQNSViewAsync((NSView *)self);
    }
}

static void YM_QNSView_viewDidMoveToSuperview(id self, SEL _cmd) {
    if (gOrig_QNSView_viewDidMoveToSuperview) {
        gOrig_QNSView_viewDidMoveToSuperview(self, _cmd);
    }

    if ([self isKindOfClass:[NSView class]]) {
        YMInstallBlurBackgroundBehindQNSViewAsync((NSView *)self);
    }
}

static void YM_QNSView_setLayer(id self, SEL _cmd, id layer) {
    if (gOrig_QNSView_setLayer) {
        gOrig_QNSView_setLayer(self, _cmd, layer);
    }

    if ([self isKindOfClass:[NSView class]]) {
        // 不在这里直接改 alpha。
        // setLayer: 可能发生在菜单栏图标 / 小窗口里的 QNSView 上，统一交给
        // YMInstallBlurBackgroundBehindQNSView 内部的窗口过滤逻辑判断。
        YMInstallBlurBackgroundBehindQNSViewAsync((NSView *)self);
    }
}

/// 只替换一次，避免 oldImp 被覆盖成自己的 hook，导致无限递归。
static void YMReplaceInstanceMethodOnce(Class cls, SEL sel, IMP newImp, IMP *oldImpStorage) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        YMLog(@"找不到方法：%@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }

    IMP currentImp = method_getImplementation(method);

    if (currentImp == newImp) {
        YMLog(@"方法已经 hook，跳过：%@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }

    IMP oldImp = method_setImplementation(method, newImp);

    // 只在第一次保存原始 IMP。
    if (oldImpStorage && *oldImpStorage == NULL) {
        *oldImpStorage = oldImp;
    }

    YMLog(@"已 hook 方法：%@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
}

static void YMInstallQNSViewHooks(void) {
    if (gYMQNSViewHookInstalled) {
        return;
    }

    Class qnsClass = NSClassFromString(@"QNSView");
    if (!qnsClass) {
        YMLog(@"QNSView 类不存在，稍后重试");
        return;
    }

    gYMQNSViewHookInstalled = YES;

    YMReplaceInstanceMethodOnce(qnsClass,
                                @selector(isOpaque),
                                (IMP)YM_QNSView_isOpaque,
                                (IMP *)&gOrig_QNSView_isOpaque);

    YMReplaceInstanceMethodOnce(qnsClass,
                                @selector(viewDidMoveToWindow),
                                (IMP)YM_QNSView_viewDidMoveToWindow,
                                (IMP *)&gOrig_QNSView_viewDidMoveToWindow);

    YMReplaceInstanceMethodOnce(qnsClass,
                                @selector(viewDidMoveToSuperview),
                                (IMP)YM_QNSView_viewDidMoveToSuperview,
                                (IMP *)&gOrig_QNSView_viewDidMoveToSuperview);

    YMReplaceInstanceMethodOnce(qnsClass,
                                @selector(setLayer:),
                                (IMP)YM_QNSView_setLayer,
                                (IMP *)&gOrig_QNSView_setLayer);
}

#pragma mark - 启动入口

@implementation ThemeHook

+ (void)start {
    if (gYMStarted) {
        return;
    }

    gYMStarted = YES;

    YMLog(@"start");

    dispatch_async(dispatch_get_main_queue(), ^{
        YMRegisterMistyThemeDefaults();
        YMInstallQNSViewHooks();
        YMRefreshAllWindows();
        YMStartBlurKeepAliveIfNeeded();

        // 微信 / Qt 有些窗口和 layer 会延后创建，所以延迟再刷几次。
        // 注意：YMInstallQNSViewHooks 内部已经防重复。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YMInstallQNSViewHooks();
            YMRefreshAllWindows();
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YMInstallQNSViewHooks();
            YMRefreshAllWindows();
        });
    });
}

+ (void)setBackgroundImagePath:(NSString *)path {
    // 当前版本已经从背景图 / NSVisualEffectView 切换为 WindowServer 可调背景模糊。
    // 保留这个接口只是为了兼容旧调用，避免外部代码调用时报错。
    (void)path;
    YMRefreshAllWindows();
}

+ (void)refreshAllQNSViews {
    YMRegisterMistyThemeDefaults();
    YMRefreshAllWindows();
    YMStartBlurKeepAliveIfNeeded();
}

@end

__attribute__((constructor))
static void YMWeChatAntiRevokePatchEntry(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            [ThemeHook start];
        });
    }
}
