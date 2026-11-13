//
//  PHCtx.m
//  宿主上下文借用层（保守版 + 崩溃保护）
//
//  上一版替换了 +[MtopService getInstance]，让 App 拿到我们捕获的实例 —— 这会破坏
//  宿主内部对单例的假设，几秒后闪退。这一版不再替换任何单例。
//
//  只保留一个钩子，且「只补空字段」：
//    · 在 -[MtopService async_call:delegate:] 里记下宿主请求的凭证字段；
//    · 发送前逐个字段检查，只把空着的补上。
//  宿主自己填好的值全程不被覆盖。
//
//  另附崩溃保护：装钩子前写标记，稳定运行 25s 后清除。若下次启动发现标记还在，
//  说明上次装完就挂了，本次直接跳过安装。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "PHCompat.h"

#define PHCTX_BUILD "1.4.1"

static id gSvc = nil;
static NSMutableDictionary<NSString *, id> *gTpl = nil;
static NSObject *gLock = nil;
static BOOL gInstalled = NO;

static void (*orig_asyncCall)(id, SEL, id, id);

static NSArray<NSString *> *PHCtxKeys(void) {
    return @[@"ttid", @"userID", @"pageName", @"pageUrl", @"wuaPageName", @"wuaCtrlName", @"loginExtInfo"];
}

/// ttid -> setTtid: / userID -> setUserID: / wuaPageName -> setWuaPageName:
static NSString *PHCtxSetter(NSString *key) {
    NSString *cap = [key stringByReplacingCharactersInRange:NSMakeRange(0, 1)
                                                 withString:[[key substringToIndex:1] uppercaseString]];
    return [NSString stringWithFormat:@"set%@:", cap];
}

static BOOL PHValueEmpty(id v) {
    if (!v || v == [NSNull null]) return YES;
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v length] == 0;
    return NO;
}

static void PHCtxApply(id req) {
    if (!req) return;

    NSDictionary *snap = nil;
    @synchronized (gLock) { snap = [gTpl copy]; }
    if (!snap.count) return;

    for (NSString *k in snap) {
        id cur = nil;
        @try { cur = [PHRuntime invoke:req sel:k]; } @catch (__unused NSException *e) {}
        if (!PHValueEmpty(cur)) continue;

        NSString *setter = PHCtxSetter(k);
        @try {
            [PHRuntime invoke:req sel:setter arg:snap[k]];
        } @catch (__unused NSException *e) {}
    }
}

static void PHCtxCapture(id req) {
    if (!req) return;
    NSMutableDictionary<NSString *, id> *fresh = [NSMutableDictionary dictionary];

    @synchronized (gLock) {
        if (!gTpl) gTpl = [NSMutableDictionary dictionary];
        for (NSString *k in PHCtxKeys()) {
            if (gTpl[k]) continue;
            id v = nil;
            @try { v = [PHRuntime invoke:req sel:k]; } @catch (__unused NSException *e) {}
            if (!v || v == [NSNull null]) continue;
            gTpl[k] = v;
            fresh[k] = v;
        }
    }

    for (NSString *k in fresh) {
        id v = fresh[k];
        NSString *shown = v;
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 20) {
            shown = [[(NSString *)v substringToIndex:10] stringByAppendingString:@"…"];
        }
        PHLOG(@"[ctx] 抄到 %@ = %@", k, shown);
    }
}

static void ph_asyncCall(id svc, SEL cmd, id req, id delegate) {
    @try {
        if (!gSvc && [svc respondsToSelector:NSSelectorFromString(@"async_call:delegate:")]) {
            gSvc = svc;
            PHLOG(@"[ctx] 观察到宿主 MtopService 实例 %p", (void *)svc);
        }
        PHCtxCapture(req);
        PHCtxApply(req);
    } @catch (__unused NSException *e) {}

    if (orig_asyncCall) orig_asyncCall(svc, cmd, req, delegate);
}

static void PHCtxInstall(void) {
    if (gInstalled) return;
    if (!gLock) gLock = [NSObject new];

    Class svcCls = NSClassFromString(@"MtopService");
    Class reqCls = NSClassFromString(@"MtopExtRequest");
    if (!svcCls || !reqCls) return;

    gInstalled = YES;

    Method mSend = class_getInstanceMethod(svcCls, NSSelectorFromString(@"async_call:delegate:"));
    if (mSend) {
        orig_asyncCall = (void (*)(id, SEL, id, id))method_setImplementation(mSend, (IMP)ph_asyncCall);
        PHLOG(@"[ctx] hook -[MtopService async_call:delegate:]");
    }

    PHLOG(@"[ctx] PHCtx " PHCTX_BUILD " 已就绪");
}

/// 崩溃保护标记：安装前写入，稳定运行 25 秒后删除。
static NSString *PHCtxGuardPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) docs = NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:@"ph_ctx_guard"];
}

__attribute__((constructor))
static void PHCtxBoot(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.taobao.fleamarket"]) {
            return;
        }

        if ([[NSFileManager defaultManager] fileExistsAtPath:PHCtxGuardPath()]) {
            PHLOG(@"[ctx] 上次启动在安装钩子后异常退出，本次跳过安装（删除 Documents/ph_ctx_guard 可恢复）");
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __block NSInteger tries = 0;
            __block void (^poll)(void) = nil;
            poll = ^{
                PHCtxInstall();
                if (gInstalled) {
                    poll = nil;
                    [@"" writeToFile:PHCtxGuardPath() atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        [[NSFileManager defaultManager] removeItemAtPath:PHCtxGuardPath() error:NULL];
                        PHLOG(@"[ctx] 稳定运行 25s，已清除崩溃保护标记");
                    });
                    return;
                }
                if (++tries > 40) { PHLOG(@"[ctx] 安装超时，宿主 MTOP 类未出现"); poll = nil; return; }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), poll);
            };
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), poll);
        });
    }
}
//
//  PHCtx.m
//  宿主上下文借用层（保守版）
//
//  上一版替换了 +[MtopService getInstance]，让 App 拿到我们捕获的实例 —— 这会破坏
//  宿主内部对单例的假设（不同 account site 是不同实例），几秒后闪退。
//
//  这一版只保留一个钩子，且「只补空字段」：
//    · 在 -[MtopService async_call:delegate:] 里记下宿主请求的凭证字段；
//    · 发送前，逐个字段检查，只把空着的补上。
//  宿主自己填好的值全程不被覆盖，也不替换任何单例。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "PHCompat.h"

#define PHCTX_BUILD "1.4.0"

static id gSvc = nil;
static NSMutableDictionary<NSString *, id> *gTpl = nil;
static NSObject *gLock = nil;
static BOOL gInstalled = NO;

static void (*orig_asyncCall)(id, SEL, id, id);

static NSArray<NSString *> *PHCtxKeys(void) {
    return @[@"ttid", @"userID", @"pageName", @"pageUrl", @"wuaPageName", @"wuaCtrlName", @"loginExtInfo"];
}

/// ttid -> setTtid: / userID -> setUserID: / wuaPageName -> setWuaPageName:
static NSString *PHCtxSetter(NSString *key) {
    NSString *cap = [key stringByReplacingCharactersInRange:NSMakeRange(0, 1)
                                                 withString:[[key substringToIndex:1] uppercaseString]];
    return [NSString stringWithFormat:@"set%@:", cap];
}

static BOOL PHValueEmpty(id v) {
    if (!v || v == [NSNull null]) return YES;
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v length] == 0;
    return NO;
}

static void PHCtxApply(id req) {
    if (!req) return;

    NSDictionary *snap = nil;
    @synchronized (gLock) { snap = [gTpl copy]; }
    if (!snap.count) return;

    for (NSString *k in snap) {
        id cur = nil;
        @try { cur = [PHRuntime invoke:req sel:k]; } @catch (__unused NSException *e) {}
        if (!PHValueEmpty(cur)) continue;

        NSString *setter = PHCtxSetter(k);
        @try {
            [PHRuntime invoke:req sel:setter arg:snap[k]];
        } @catch (__unused NSException *e) {}
    }
}

static void PHCtxCapture(id req) {
    if (!req) return;
    NSMutableDictionary<NSString *, id> *fresh = [NSMutableDictionary dictionary];

    @synchronized (gLock) {
        if (!gTpl) gTpl = [NSMutableDictionary dictionary];
        for (NSString *k in PHCtxKeys()) {
            if (gTpl[k]) continue;
            id v = nil;
            @try { v = [PHRuntime invoke:req sel:k]; } @catch (__unused NSException *e) {}
            if (!v || v == [NSNull null]) continue;
            gTpl[k] = v;
            fresh[k] = v;
        }
    }

    for (NSString *k in fresh) {
        id v = fresh[k];
        NSString *shown = v;
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 20) {
            shown = [[(NSString *)v substringToIndex:10] stringByAppendingString:@"…"];
        }
        PHLOG(@"[ctx] 抄到 %@ = %@", k, shown);
    }
}

static void ph_asyncCall(id svc, SEL cmd, id req, id delegate) {
    @try {
        if (!gSvc && [svc respondsToSelector:NSSelectorFromString(@"async_call:delegate:")]) {
            gSvc = svc;
            PHLOG(@"[ctx] 观察到宿主 MtopService 实例 %p", (void *)svc);
        }
        PHCtxCapture(req);
        PHCtxApply(req);
    } @catch (__unused NSException *e) {}

    if (orig_asyncCall) orig_asyncCall(svc, cmd, req, delegate);
}

static void PHCtxInstall(void) {
    if (gInstalled) return;
    if (!gLock) gLock = [NSObject new];

    Class svcCls = NSClassFromString(@"MtopService");
    Class reqCls = NSClassFromString(@"MtopExtRequest");
    if (!svcCls || !reqCls) return;

    gInstalled = YES;

    Method mSend = class_getInstanceMethod(svcCls, NSSelectorFromString(@"async_call:delegate:"));
    if (mSend) {
        orig_asyncCall = (void (*)(id, SEL, id, id))method_setImplementation(mSend, (IMP)ph_asyncCall);
        PHLOG(@"[ctx] hook -[MtopService async_call:delegate:]");
    }

    PHLOG(@"[ctx] PHCtx " PHCTX_BUILD " 已就绪");
}

__attribute__((constructor))
static void PHCtxBoot(void) {
    @autoreleasepool {
        if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.taobao.fleamarket"]) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __block NSInteger tries = 0;
            __block void (^poll)(void) = nil;
            poll = ^{
                PHCtxInstall();
                if (gInstalled) { poll = nil; return; }
                if (++tries > 40) { PHLOG(@"[ctx] 安装超时，宿主 MTOP 类未出现"); poll = nil; return; }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), poll);
            };
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), poll);
        });
    }
}
