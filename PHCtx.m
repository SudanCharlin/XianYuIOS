//
//  PHCtx.m
//  宿主上下文借用层
//
//  问题：自己 new 出来的 MTOP 请求是「干净」的 —— 没有 ttid、没有 userID、
//  没有页面上下文，网关会按匿名流量处理，回一句「服务器繁忙，请稍后再试」。
//
//  做法：不猜字段，直接观察 App 自己发出的请求。
//    · hook -[MtopService async_call:delegate:]：记下它用的是哪个 service 实例，
//      并把该请求上的 ttid / userID / 页面信息抄成模板；
//    · hook -[MtopExtRequest initWithApiName:apiVersion:]：新请求一创建就把模板套上；
//    · hook +[MtopService getInstance]：优先返回宿主真实用过的实例。
//
//  这样既不需要改 PHMtop，也不依赖任何私有头文件。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "PHCompat.h"

#define PHCTX_BUILD "1.3.0"

static id gSvc = nil;
static NSMutableDictionary<NSString *, id> *gTpl = nil;
static BOOL gInstalled = NO;

static void (*orig_asyncCall)(id, SEL, id, id);
static id (*orig_initReq)(id, SEL, id, id);
static id (*orig_getInstance)(id, SEL);

static NSArray<NSString *> *PHCtxKeys(void) {
    return @[@"ttid", @"userID", @"pageName", @"pageUrl", @"wuaPageName", @"wuaCtrlName", @"loginExtInfo"];
}

/// ttid -> setTtid: / userID -> setUserID: / wuaPageName -> setWuaPageName:
static NSString *PHCtxSetter(NSString *key) {
    NSString *cap = [key stringByReplacingCharactersInRange:NSMakeRange(0, 1)
                                                 withString:[[key substringToIndex:1] uppercaseString]];
    return [NSString stringWithFormat:@"set%@:", cap];
}

static void PHCtxApply(id req) {
    if (!req || !gTpl.count) return;
    for (NSString *k in gTpl) {
        NSString *setter = PHCtxSetter(k);
        @try {
            [PHRuntime invoke:req sel:setter arg:gTpl[k]];
        } @catch (__unused NSException *e) {}
    }
}

static void PHCtxCapture(id req) {
    if (!req) return;
    if (!gTpl) gTpl = [NSMutableDictionary dictionary];
    for (NSString *k in PHCtxKeys()) {
        if (gTpl[k]) continue;
        id v = nil;
        @try { v = [PHRuntime invoke:req sel:k]; } @catch (__unused NSException *e) {}
        if (!v || v == [NSNull null]) continue;
        gTpl[k] = v;
        NSString *shown = v;
        if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 20) {
            shown = [[(NSString *)v substringToIndex:10] stringByAppendingString:@"…"];
        }
        PHLOG(@"[ctx] 抄到 %@ = %@", k, shown);
    }
}

/// 宿主真实用过的 service 实例。默认实例可能没挂登录/鉴权模块。
static id ph_getInstance(id cls, SEL cmd) {
    if (gSvc) return gSvc;
    id v = orig_getInstance ? orig_getInstance(cls, cmd) : nil;
    if (v && !gSvc) gSvc = v;
    return v;
}

static void ph_asyncCall(id svc, SEL cmd, id req, id delegate) {
    @try {
        if (!gSvc && [svc respondsToSelector:NSSelectorFromString(@"async_call:delegate:")]) {
            gSvc = svc;
            PHLOG(@"[ctx] 捕获宿主 MtopService 实例 %p", (void *)svc);
        }
        PHCtxCapture(req);
        PHCtxApply(req);
    } @catch (__unused NSException *e) {}

    if (orig_asyncCall) orig_asyncCall(svc, cmd, req, delegate);
}

static id ph_initReq(id self, SEL cmd, id api, id ver) {
    id r = orig_initReq ? orig_initReq(self, cmd, api, ver) : nil;
    @try { PHCtxApply(r); } @catch (__unused NSException *e) {}
    return r;
}

static void PHCtxInstall(void) {
    if (gInstalled) return;

    Class svcCls = NSClassFromString(@"MtopService");
    Class reqCls = NSClassFromString(@"MtopExtRequest");
    if (!svcCls || !reqCls) return;

    gInstalled = YES;

    Method mGet = class_getClassMethod(svcCls, NSSelectorFromString(@"getInstance"));
    if (mGet) {
        orig_getInstance = (id (*)(id, SEL))method_setImplementation(mGet, (IMP)ph_getInstance);
        PHLOG(@"[ctx] hook +[MtopService getInstance]");
    }

    Method mSend = class_getInstanceMethod(svcCls, NSSelectorFromString(@"async_call:delegate:"));
    if (mSend) {
        orig_asyncCall = (void (*)(id, SEL, id, id))method_setImplementation(mSend, (IMP)ph_asyncCall);
        PHLOG(@"[ctx] hook -[MtopService async_call:delegate:]");
    }

    Method mInit = class_getInstanceMethod(reqCls, NSSelectorFromString(@"initWithApiName:apiVersion:"));
    if (mInit) {
        orig_initReq = (id (*)(id, SEL, id, id))method_setImplementation(mInit, (IMP)ph_initReq);
        PHLOG(@"[ctx] hook -[MtopExtRequest initWithApiName:apiVersion:]");
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
