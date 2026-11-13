//
//  PHMtop.m
//

#import "PHMtop.h"
#import "PHCompat.h"

/// 内部方法前置声明（实现内定义，供 Token 调用）
@interface PHMtop (Internal)
+ (nullable NSDictionary *)extractJSON:(id)resp;
+ (nullable NSDictionary *)parseResponse:(id)resp errMsg:(NSString *_Nullable *_Nullable)errOut;
@end

/// 运行时构造 MtopExtRequest / MtopApiRequest 的最小协议形状。
@protocol PHMtopReqInit <NSObject>
- (id)initWithApiName:(NSString *)apiName apiVersion:(NSString *)apiVersion;
@end

@protocol PHMtopApiReqInit <NSObject>
- (id)initWithApiName:(NSString *)apiName version:(NSString *)version;
@end

/// 每次请求的接收凭据：同时挂 delegate 与 succeedBlock，谁先回来用谁（once 去重）
@interface PHMtopToken : NSObject
@property (nonatomic, copy) PHMtopCompletion completion;
@property (nonatomic, strong) id request;
@property (nonatomic, assign) BOOL fired;
@property (nonatomic, assign) NSTimeInterval t0;
- (void)fire:(nullable id)resp err:(nullable NSString *)err;
@end

@implementation PHMtopToken

- (void)fire:(id)resp err:(NSString *)err {
    @synchronized (self) {
        if (self.fired) return;
        self.fired = YES;
    }
    NSString *e = err;
    NSDictionary *json = [PHMtop parseResponse:resp errMsg:&e];

    PHMtopCompletion cb = self.completion;
    if (cb) cb(json, e);
}

- (void)started:(id)request { }

- (void)succeed:(id)request response:(id)response {
    [self fire:response err:nil];
}

- (void)failed:(id)request response:(id)response {
    [self fire:response err:@"request failed"];
}

@end


@implementation PHMtop {
    id _service;
    dispatch_queue_t _cbQueue;
    NSMutableDictionary<NSString *, PHMtopToken *> *_pending;
    NSObject *_lock;
    PHMtopEngine _activeEngine;
}

+ (instancetype)shared {
    static PHMtop *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PHMtop new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cbQueue = dispatch_queue_create("com.piggyhand.ph.mtop.cb", DISPATCH_QUEUE_SERIAL);
        _pending = [NSMutableDictionary dictionary];
        _lock = [NSObject new];
        _engine = PHMtopEngineAuto;
        _activeEngine = PHMtopEngineAuto;
    }
    return self;
}

- (PHMtopEngine)activeEngine { return _activeEngine; }

- (BOOL)ready {
    return _service != nil || [PHRuntime cls:@"MtopApiRequest"] != nil;
}

- (BOOL)prepare {
    if (_service) return YES;

    Class apiCls = [PHRuntime cls:@"MtopApiRequest"];
    Class svcCls = [PHRuntime cls:@"MtopService"];
    if (!apiCls && !svcCls) {
        PHLOG(@"[mtop] 既无 MtopApiRequest 也无 MtopService，宿主 MTOP 尚未加载");
        return NO;
    }

    if (svcCls) {
        id svc = nil;
        @try {
            svc = [PHRuntime invoke:svcCls sel:@"getInstance"];
        } @catch (NSException *e) {
            PHLOG(@"[mtop] MtopService.getInstance 异常: %@", e.reason);
        }
        if (svc && [svc respondsToSelector:NSSelectorFromString(@"async_call:delegate:")]) {
            _service = svc;
            PHLOG(@"[mtop] MtopService 就绪: %@ <%p>", NSStringFromClass([svc class]), svc);
        } else if (svc) {
            PHLOG(@"[mtop] MtopService 实例缺少 async_call:delegate:");
        }
    }

    if (apiCls) {
        PHLOG(@"[mtop] MtopApiRequest 可用（引擎 A）");
    }
    return (apiCls != nil) || (_service != nil);
}

#pragma mark - 响应解析

+ (NSDictionary *)extractJSON:(id)resp {
    id j = [PHRuntime invoke:resp sel:@"json"];
    if ([j isKindOfClass:[NSDictionary class]]) return j;
    if ([j isKindOfClass:[NSArray class]]) return @{@"_array": j};

    id body = [PHRuntime invoke:resp sel:@"body"];
    if ([body isKindOfClass:[NSDictionary class]]) return body;
    if ([body isKindOfClass:[NSData class]]) {
        id p = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
        if ([p isKindOfClass:[NSDictionary class]]) return p;
    }
    if ([body isKindOfClass:[NSString class]]) {
        id p = [NSJSONSerialization JSONObjectWithData:[(NSString *)body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        if ([p isKindOfClass:[NSDictionary class]]) return p;
    }
    return nil;
}

+ (NSDictionary *)parseResponse:(id)resp errMsg:(NSString **)errOut {
    NSString *e = (errOut ? *errOut : nil);
    NSDictionary *json = nil;

    if (resp) {
        json = [self extractJSON:resp];
        if (!json) {
            id body = [PHRuntime invoke:resp sel:@"body"];
            if (body) json = @{@"_raw": [body description] ?: @""};
        }
        if (!e) {
            id ec = [PHRuntime invoke:resp sel:@"error"];
            if (ec) {
                NSString *d = [PHRuntime invoke:ec sel:@"localizedDescription"] ?: [ec description];
                if (d.length) e = d;
            }
        }
        SEL isOk = NSSelectorFromString(@"isSucceed");
        if ([resp respondsToSelector:isOk]) {
            BOOL ok = ((BOOL (*)(id, SEL))[resp methodForSelector:isOk])(resp, isOk);
            if (!ok && !e) e = @"isSucceed = NO";
        }
    }
    if (errOut) *errOut = e;
    return json;
}

+ (NSString *)ret0:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    id ret = json[@"ret"];
    if ([ret isKindOfClass:[NSArray class]] && [ret count] > 0) {
        id v = [ret firstObject];
        return [v isKindOfClass:[NSString class]] ? v : [v description];
    }
    if ([ret isKindOfClass:[NSString class]]) return ret;
    return nil;
}

+ (NSString *)describe:(NSDictionary *)json {
    if (![json isKindOfClass:[NSDictionary class]]) return @"(无响应体)";
    NSMutableString *s = [NSMutableString string];

    NSString *ret = [self ret0:json];
    [s appendFormat:@"ret=%@", ret ?: @"(nil)"];

    for (NSString *k in @[@"code", @"msg", @"message", @"api", @"v", @"data"]) {
        id v = json[k];
        if (!v || v == [NSNull null]) continue;
        if ([k isEqualToString:@"data"]) {
            if ([v isKindOfClass:[NSDictionary class]]) {
                id c = ((NSDictionary *)v)[@"code"];
                id m = ((NSDictionary *)v)[@"msg"] ?: ((NSDictionary *)v)[@"message"];
                if (c) [s appendFormat:@" | data.code=%@", c];
                if (m) [s appendFormat:@" | data.msg=%@", m];
            }
            continue;
        }
        [s appendFormat:@" | %@=%@", k, v];
    }

    if (s.length > 300) return [[s substringToIndex:300] stringByAppendingString:@"…"];
    return s;
}

/// 响应是否「有效且非鉴权类失败」
+ (BOOL)usable:(NSDictionary *)json {
    NSString *ret = [self ret0:json];
    if (!ret.length) return NO;
    if ([ret containsString:@"SUCCESS"]) return YES;
    for (NSString *kw in @[@"SESSION", @"ILLEGAL", @"AUTH", @"TOKEN", @"LOGIN", @"授权", @"登录"]) {
        if ([ret rangeOfString:kw].location != NSNotFound) return NO;
    }
    return YES;
}

#pragma mark - 引擎 A：MtopApiRequest

- (NSDictionary *)callViaApiRequest:(NSString *)api
                            version:(NSString *)version
                             params:(NSDictionary *)params
                             errMsg:(NSString **)errOut
                            timeout:(NSTimeInterval)timeout {

    Class cls = [PHRuntime cls:@"MtopApiRequest"];
    if (!cls) {
        if (errOut) *errOut = @"MtopApiRequest 类缺失";
        return nil;
    }

    id req = nil;
    @try {
        id allocated = [cls alloc];
        req = [(id<PHMtopApiReqInit>)allocated initWithApiName:api version:version];
    } @catch (NSException *e) {
        if (errOut) *errOut = [NSString stringWithFormat:@"ApiRequest 构造异常: %@", e.reason];
        return nil;
    }
    if (!req) {
        if (errOut) *errOut = @"ApiRequest 构造返回 nil";
        return nil;
    }

    for (NSString *k in params) {
        id v = params[k];
        if (!v || v == [NSNull null]) continue;
        @try {
            [PHRuntime invoke:req sel:@"addParameter:forKey:" arg1:v arg2:k];
        } @catch (__unused NSException *e) {}
    }

    SEL syncSel = NSSelectorFromString(@"sync");
    if (![req respondsToSelector:syncSel]) {
        if (errOut) *errOut = @"MtopApiRequest 无 sync";
        return nil;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSString *innerErr = nil;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            ((void (*)(id, SEL))[req methodForSelector:syncSel])(req, syncSel);
        } @catch (NSException *e) {
            innerErr = [NSString stringWithFormat:@"sync 异常: %@", e.reason];
        }
        dispatch_semaphore_signal(sem);
    });

    long r = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    if (r != 0) {
        if (errOut) *errOut = @"ApiRequest sync 超时";
        return nil;
    }
    if (innerErr) {
        if (errOut) *errOut = innerErr;
        return nil;
    }

    id resp = nil;
    @try { resp = [PHRuntime invoke:req sel:@"response"]; } @catch (__unused NSException *e) {}
    return [PHMtop parseResponse:resp errMsg:errOut];
}

#pragma mark - 引擎 B：MtopExtRequest + MtopService

- (void)callViaExtRequest:(NSString *)api
                  version:(NSString *)version
                   params:(NSDictionary *)params
               completion:(PHMtopCompletion)completion {

    if (!_service) {
        if (completion) completion(nil, @"MtopService 不可用");
        return;
    }

    Class reqCls = [PHRuntime cls:@"MtopExtRequest"];
    if (!reqCls) {
        if (completion) completion(nil, @"MtopExtRequest 类缺失");
        return;
    }

    id req = nil;
    @try {
        id allocated = [reqCls alloc];
        req = [(id<PHMtopReqInit>)allocated initWithApiName:api apiVersion:version];
    } @catch (NSException *e) {
        if (completion) completion(nil, [NSString stringWithFormat:@"构造请求异常: %@", e.reason]);
        return;
    }
    if (!req) {
        if (completion) completion(nil, @"构造请求返回 nil");
        return;
    }

    for (NSString *k in params) {
        id v = params[k];
        if (!v || v == [NSNull null]) continue;
        @try {
            [PHRuntime invoke:req sel:@"addBizParameter:forKey:" arg1:v arg2:k];
        } @catch (__unused NSException *e) {}
    }

    @try {
        SEL s = NSSelectorFromString(@"setIsEnableWUA:");
        if ([req respondsToSelector:s]) {
            ((void (*)(id, SEL, BOOL))[req methodForSelector:s])(req, s, YES);
        }
        s = NSSelectorFromString(@"setIsNeedEcode:");
        if ([req respondsToSelector:s]) {
            ((void (*)(id, SEL, BOOL))[req methodForSelector:s])(req, s, YES);
        }
        s = NSSelectorFromString(@"setIsNotUseMainThreadCallback:");
        if ([req respondsToSelector:s]) {
            ((void (*)(id, SEL, BOOL))[req methodForSelector:s])(req, s, YES);
        }
        s = NSSelectorFromString(@"setNetworkTimeout:");
        if ([req respondsToSelector:s]) {
            ((void (*)(id, SEL, int))[req methodForSelector:s])(req, s, 25);
        }
    } @catch (__unused NSException *e) {}

    PHMtopToken *token = [PHMtopToken new];
    token.completion = completion;
    token.request = req;
    token.t0 = [NSDate date].timeIntervalSince1970;

    NSString *rid = nil;
    @try { rid = [PHRuntime invoke:req sel:@"getRequestId"]; } @catch (__unused NSException *e) {}
    if (![rid isKindOfClass:[NSString class]] || rid.length == 0) {
        rid = [NSString stringWithFormat:@"%p-%d", req, (int)(token.t0 * 1000) % 100000];
    }
    @synchronized (_lock) { _pending[rid] = token; }

    @try {
        SEL sb = NSSelectorFromString(@"setSucceedBlock:");
        if ([req respondsToSelector:sb]) {
            id blk = ^(id resp) { [token fire:resp err:nil]; };
            ((void (*)(id, SEL, id))[req methodForSelector:sb])(req, sb, blk);
        }
        SEL fb = NSSelectorFromString(@"setFailedBlock:");
        if ([req respondsToSelector:fb]) {
            id blk = ^(id resp) { [token fire:resp err:@"failed block"]; };
            ((void (*)(id, SEL, id))[req methodForSelector:fb])(req, fb, blk);
        }
    } @catch (__unused NSException *e) {}

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            IMP imp = [self->_service methodForSelector:NSSelectorFromString(@"async_call:delegate:")];
            if (imp) {
                ((void (*)(id, SEL, id, id))imp)(self->_service,
                                                 NSSelectorFromString(@"async_call:delegate:"),
                                                 req, token);
            } else {
                [token fire:nil err:@"async_call:delegate: 不可用"];
            }
        } @catch (NSException *e) {
            [token fire:nil err:[NSString stringWithFormat:@"发送异常: %@", e.reason]];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(28 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
            [token fire:nil err:@"timeout"];
            @synchronized (self->_lock) { [self->_pending removeObjectForKey:rid]; }
        });
    });
}

- (NSDictionary *)callExtSync:(NSString *)api
                      version:(NSString *)version
                       params:(NSDictionary *)params
                       errMsg:(NSString **)errOut
                      timeout:(NSTimeInterval)timeout {
    __block NSDictionary *out = nil;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [self callViaExtRequest:api version:version params:params completion:^(NSDictionary *json, NSString *e) {
        out = json;
        err = e;
        dispatch_semaphore_signal(sem);
    }];

    long r = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    if (r != 0) {
        if (errOut) *errOut = @"ExtRequest 超时";
        return nil;
    }
    if (errOut) *errOut = err;
    return out;
}

#pragma mark - 统一入口

- (void)call:(NSString *)api
     version:(NSString *)version
      params:(NSDictionary *)params
  completion:(PHMtopCompletion)completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *err = nil;
        NSDictionary *json = [self callSync:api version:version params:params errMsg:&err timeout:30];
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(json, err); });
        }
    });
}

- (NSDictionary *)callSync:(NSString *)api
                   version:(NSString *)version
                    params:(NSDictionary *)params
                    errMsg:(NSString **)errMsg
                   timeout:(NSTimeInterval)timeout {

    if ([NSThread isMainThread]) {
        if (errMsg) *errMsg = @"callSync 不能在主线程调用";
        return nil;
    }
    if (![self prepare]) {
        if (errMsg) *errMsg = @"MTOP 协议栈未就绪";
        return nil;
    }

    NSDictionary *resultA = nil;
    NSDictionary *resultB = nil;
    NSString *errA = nil;
    NSString *errB = nil;

    if (self.engine != PHMtopEngineExtRequest) {
        resultA = [self callViaApiRequest:api version:version params:params errMsg:&errA timeout:timeout];
        if ([PHMtop usable:resultA]) {
            _activeEngine = PHMtopEngineApiRequest;
            PHLOG(@"[mtop][A] %@ -> %@", api, [PHMtop describe:resultA]);
            if (errMsg) *errMsg = nil;
            return resultA;
        }
        PHLOG(@"[mtop][A] %@ 不可用: %@", api, errA ?: [PHMtop describe:resultA]);
    }

    if (self.engine != PHMtopEngineApiRequest) {
        resultB = [self callExtSync:api version:version params:params errMsg:&errB timeout:timeout];
        if ([PHMtop usable:resultB]) {
            _activeEngine = PHMtopEngineExtRequest;
            PHLOG(@"[mtop][B] %@ -> %@", api, [PHMtop describe:resultB]);
            if (errMsg) *errMsg = nil;
            return resultB;
        }
        PHLOG(@"[mtop][B] %@ 不可用: %@", api, errB ?: [PHMtop describe:resultB]);
    }

    NSDictionary *best = resultB ?: resultA;
    if (errMsg) *errMsg = errB ?: errA;
    return best;
}

#pragma mark - 自检

- (void)diagnose:(void (^)(NSString *))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSMutableString *r = [NSMutableString string];
        [r appendFormat:@"诊断 " PH_BUILD_ID " · %@\n", [NSDate date]];

        Class apiCls = NSClassFromString(@"MtopApiRequest");
        Class svcCls = NSClassFromString(@"MtopService");
        Class reqCls = NSClassFromString(@"MtopExtRequest");
        [r appendFormat:@"类: ApiRequest=%@ Service=%@ ExtRequest=%@\n",
             apiCls ? @"YES" : @"NO", svcCls ? @"YES" : @"NO", reqCls ? @"YES" : @"NO"];

        BOOL ok = [self prepare];
        [r appendFormat:@"prepare=%@ service=%p\n", ok ? @"YES" : @"NO", (void *)self->_service];

        NSString *ttid = nil, *uid = nil;
        if (self->_service) {
            @try { ttid = [PHRuntime invoke:self->_service sel:@"getTtid"]; } @catch (__unused NSException *e) {}
            @try { uid = [PHRuntime invoke:self->_service sel:@"getUserId"]; } @catch (__unused NSException *e) {}
        }
        [r appendFormat:@"ttid=%@ uid=%@\n", ttid ?: @"(nil)", uid ?: @"(nil)"];

        NSString *api = @"mtop.taobao.idle.coin.signin";
        NSString *ver = @"1.0";

        NSString *eA = nil;
        NSDictionary *a = [self callViaApiRequest:api version:ver params:@{} errMsg:&eA timeout:25];
        [r appendFormat:@"\n[A] ApiRequest\n  %@\n  err=%@\n", [PHMtop describe:a], eA ?: @"-"];

        NSString *eB = nil;
        NSDictionary *b = [self callExtSync:api version:ver params:@{} errMsg:&eB timeout:25];
        [r appendFormat:@"\n[B] ExtRequest\n  %@\n  err=%@\n", [PHMtop describe:b], eB ?: @"-"];

        if (a.count) {
            NSData *d = [NSJSONSerialization dataWithJSONObject:a options:0 error:NULL];
            NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
            if (s.length > 700) s = [[s substringToIndex:700] stringByAppendingString:@"…"];
            [r appendFormat:@"\n[A] 原文: %@\n", s];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(r);
        });
    });
}

@end
