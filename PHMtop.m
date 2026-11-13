//
//  PHMtop.m
//

#import "PHMtop.h"
#import "PHCompat.h"

/// 内部方法前置声明（实现内定义，供 Token 调用）
@interface PHMtop (Internal)
+ (nullable NSDictionary *)extractJSON:(id)resp;
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
    NSDictionary *json = nil;
    NSString *e = err;

    if (resp) {
        json = [PHMtop extractJSON:resp];
        if (!json) {
            // 响应体不是 JSON，把原始 body 塞进去便于诊断
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
        // isSucceed == NO 但没有 error 对象时也标记
        SEL isOk = NSSelectorFromString(@"isSucceed");
        if ([resp respondsToSelector:isOk]) {
            BOOL ok = ((BOOL (*)(id, SEL))[resp methodForSelector:isOk])(resp, isOk);
            if (!ok && !e) e = @"response.isSucceed = NO";
        }
    }

    PHMtopCompletion cb = self.completion;
    if (cb) cb(json, e);
}

// 协议方法（MtopExtRequestDelegate）
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
    }
    return self;
}

- (BOOL)ready {
    return _service != nil;
}

- (BOOL)prepare {
    if (_service) return YES;

    Class svcCls = [PHRuntime cls:@"MtopService"];
    if (!svcCls) {
        PHLOG(@"[mtop] MtopService 未找到（宿主 MTOP 框架尚未加载）");
        return NO;
    }
    id svc = nil;
    @try {
        svc = [PHRuntime invoke:svcCls sel:@"getInstance"];
    } @catch (NSException *e) {
        PHLOG(@"[mtop] getInstance 抛异常: %@", e.reason);
    }
    if (!svc) {
        PHLOG(@"[mtop] MtopService.getInstance 返回 nil");
        return NO;
    }
    // 形状校验：必须能 async_call:delegate:
    if (![svc respondsToSelector:NSSelectorFromString(@"async_call:delegate:")]) {
        PHLOG(@"[mtop] MtopService 实例缺少 async_call:delegate:，接口不匹配");
        return NO;
    }
    _service = svc;
    PHLOG(@"[mtop] 协议栈就绪: %@ <%p>", NSStringFromClass([svc class]), svc);
    return YES;
}

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

- (void)call:(NSString *)api
     version:(NSString *)version
      params:(NSDictionary *)params
  completion:(PHMtopCompletion)completion {

    if (![self prepare]) {
        if (completion) completion(nil, @"MTOP 协议栈未就绪");
        return;
    }

    Class reqCls = [PHRuntime cls:@"MtopExtRequest"];
    if (!reqCls) {
        if (completion) completion(nil, @"MtopExtRequest 类缺失");
        return;
    }

    id req = nil;
    @try {
        req = [[reqCls alloc] initWithApiName:api apiVersion:version];
    } @catch (NSException *e) {
        if (completion) completion(nil, [NSString stringWithFormat:@"构造请求异常: %@", e.reason]);
        return;
    }
    if (!req) {
        if (completion) completion(nil, @"构造请求返回 nil");
        return;
    }

    // 业务参数
    for (NSString *k in params) {
        id v = params[k];
        if (!v || v == [NSNull null]) continue;
        @try {
            [PHRuntime invoke:req sel:@"addBizParameter:forKey:" arg1:v arg2:k];
        } @catch (__unused NSException *e) {}
    }

    // 请求属性：开 WUA、需要 ecode、需要登录态、超时、回调不回主线程
    @try {
        SEL s = NSSelectorFromString(@"setIsEnableWUA:");
        if ([req respondsToSelector:s]) {
            ((void (*)(id, SEL, BOOL))[req methodForSelector:s])(req, s, YES);
        }
        s = NSSelectorFromString(@"setIsNeedEcode:");
        if ([req respondsToSelector:s]) {
            ((void (*)(id, SEL, BOOL))[req methodForSelector:s])(req, s, YES);
        }
        s = NSSelectorFromString(@"setIsNeedAuth:");
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

    // 兜底：succeedBlock / failedBlock（部分 MTOP 版本在 delegate 为空时才走 block）
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

    PHLOGV(@"[mtop] → %@ v%@ params=%@", api, version, params);

    // 发送：统一回主线程调用，规避 SDK 内部对线程的假设
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
        // 超时兜底
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(28 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
            [token fire:nil err:@"timeout"];
            @synchronized (self->_lock) { [self->_pending removeObjectForKey:rid]; }
        });
    });
}

- (NSDictionary *)callSync:(NSString *)api
                   version:(NSString *)version
                    params:(NSDictionary *)params
                    errMsg:(NSString **)errMsg
                   timeout:(NSTimeInterval)timeout {

    if ([NSThread isMainThread]) {
        // 主线程等待会冻结 UI 且可能与 SDK 回调互锁，直接拒绝
        if (errMsg) *errMsg = @"callSync 不能在主线程调用";
        return nil;
    }

    __block NSDictionary *out = nil;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [self call:api version:version params:params completion:^(NSDictionary *json, NSString *e) {
        out = json;
        err = e;
        dispatch_semaphore_signal(sem);
    }];

    long r = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    if (r != 0) {
        if (errMsg) *errMsg = @"timeout";
        return nil;
    }
    if (errMsg) *errMsg = err;
    return out;
}

@end
