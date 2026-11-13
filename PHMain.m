//
//  PHMain.m
//  插件入口
//
//  注入形态：自签环境下的独立 dylib（不依赖 substrate / ellekit）。
//  启动路径：
//    __attribute__((constructor))
//      → 等 UIApplicationDidFinishLaunching / 前台激活
//      → swizzle MtopExtRequest 参数入口（抄写 fishAdCode/gps/asac）
//      → 挂悬浮球
//      → 按间隔判断是否自动跑批
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "PHCompat.h"
#import "PHMtop.h"
#import "PHEngine.h"
#import "PHHUD.h"

static BOOL gLaunched = NO;
static BOOL gHooked = NO;

#pragma mark - MTOP 参数捕获

static void (*g_orig_addBiz1)(id, SEL, id, id);
static void (*g_orig_addBizN)(id, SEL, id);

static void ph_addBizParameter(id self, SEL _cmd, id value, id key) {
    if (g_orig_addBiz1) g_orig_addBiz1(self, _cmd, value, key);
    if ([key isKindOfClass:[NSString class]] && value) {
        @try {
            [[PHLocContext shared] captureFromBizParams:@{key: value}];
        } @catch (__unused NSException *e) {}
    }
}

static void ph_addBizParameters(id self, SEL _cmd, id dict) {
    if (g_orig_addBizN) g_orig_addBizN(self, _cmd, dict);
    if ([dict isKindOfClass:[NSDictionary class]]) {
        @try {
            [[PHLocContext shared] captureFromBizParams:dict];
        } @catch (__unused NSException *e) {}
    }
}

static void PHInstallHooks(void) {
    if (gHooked) return;
    Class reqCls = NSClassFromString(@"MtopExtRequest");
    if (!reqCls) {
        PHLOG(@"[hook] MtopExtRequest 尚未加载，稍后重试");
        return;
    }
    gHooked = YES;

    g_orig_addBiz1 = (void (*)(id, SEL, id, id))[PHRuntime hookInstance:reqCls
                                                                    sel:NSSelectorFromString(@"addBizParameter:forKey:")
                                                                 newImp:(IMP)ph_addBizParameter];

    IMP n = (IMP)ph_addBizParameters;
    Method m = class_getInstanceMethod(reqCls, NSSelectorFromString(@"addBizParameters:"));
    if (m) {
        g_orig_addBizN = (void (*)(id, SEL, id))method_setImplementation(m, n);
        PHLOG(@"[hook] -[MtopExtRequest addBizParameters:] ok");
    }
}

#pragma mark - 自动跑批

static void PHMaybeAutoRun(NSString *reason) {
    PHConfig *cfg = [PHConfig shared];
    if (!cfg.enabled || !cfg.autoRun) return;

    NSTimeInterval last = [cfg lastRunAt];
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSTimeInterval gap = cfg.intervalH * 3600.0;

    if (last > 0 && (now - last) < gap) {
        double left = (gap - (now - last)) / 60.0;
        PHLOG(@"[auto] 距上次 %.0f 分钟，未到间隔（还需 %.0f 分钟）", (now - last) / 60.0, left);
        return;
    }
    if ([PHEngine shared].running) return;

    PHLOG(@"[auto] 触发自动跑批（%@）", reason);
    [[PHEngine shared] runWithCompletion:^(NSString *report, NSInteger ok, NSInteger fail) {
        [[PHHUD shared] toast:[NSString stringWithFormat:@"自动跑批完成 · 成功 %ld · 失败 %ld", (long)ok, (long)fail)];
    }];
}

#pragma mark - 启动装配

static void PHBoot(void) {
    if (gLaunched) return;
    gLaunched = YES;

    PHLOG(@"==========================================");
    PHLOG(@"闲鱼小猪手 iOS 已注入 · %@", [[NSBundle mainBundle] bundleIdentifier]);
    PHLOG(@"==========================================");

    PHInstallHooks();

    // MTOP 框架需要等宿主初始化；先探测，失败则轮询
    __block NSInteger tries = 0;
    __block void (^probe)(void) = nil;
    probe = ^{
        if ([[PHMtop shared] prepare]) {
            [[PHHUD shared] attach];
            // 再等几秒让首页登录态出来，避免首批请求 401
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                PHMaybeAutoRun(@"启动");
            });
            probe = nil;
            return;
        }
        if (++tries > 30) {
            PHLOG(@"[boot] MTOP 探测超时，仍挂载 UI");
            [[PHHUD shared] attach];
            probe = nil;
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), probe);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), probe);

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *n) {
        PHInstallHooks();
        [[PHHUD shared] refresh];
        // 回前台时检查一次间隔（同一次启动内只跑一次由 running 标记兜底）
        static NSTimeInterval lastCheck = 0;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (now - lastCheck > 300) {
            lastCheck = now;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                PHMaybeAutoRun(@"回前台");
            });
        }
    }];
}

__attribute__((constructor))
static void PHConstructor(void) {
    @autoreleasepool {
        // 只在闲鱼进程内工作
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.taobao.fleamarket"]) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
                PHBoot();
            } else {
                [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                                  object:nil
                                                                   queue:[NSOperationQueue mainQueue]
                                                              usingBlock:^(__unused NSNotification *n) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        PHBoot();
                    });
                }];
                // 兜底：某些自签环境不派发 DidFinishLaunching
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    PHBoot();
                });
            }
        });
    }
}
