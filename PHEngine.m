//
//  PHEngine.m
//
//  业务链完全对齐安卓模块 piggyhand-fish v1.0.2 的 FishTaskAuto：
//    coin.signin → play.sign.in → item.polish → shop.daily.benefit
//    → queryolivertasklist(sceneId=496) → 分类(可领/可触发/浏览/搜一搜/夺宝)
//    → 触发 → 复领 → 收尾复查
//
//  刻意保留的两个反脆弱设计（来自安卓侧实战教训）：
//   1. triggerBody 字段闸：fromToken/groupId 缺任一 → 不发请求。
//      云端对缺字段固定回 PARAM_ILLEGAL，发了只会污染日志。
//   2. 毒化闸：同类任务连续 2 次 PARAM 类失败 → 本轮不再发同类。
//

#import "PHEngine.h"
#import "PHCompat.h"
#import "PHMtop.h"

static NSString *const kSceneId = @"496";

@interface PHEngine ()
@property (nonatomic, assign) BOOL running;
@property (nonatomic, assign) BOOL stopFlag;
@end

@implementation PHEngine {
    dispatch_queue_t _q;
    NSMutableArray<NSString *> *_report;
    NSInteger _ok;
    NSInteger _fail;
    NSMutableDictionary<NSString *, NSNumber *> *_poison;
    NSArray<NSString *> *_itemPool;
}

+ (instancetype)shared {
    static PHEngine *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PHEngine new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _q = dispatch_queue_create("com.piggyhand.ph.engine", DISPATCH_QUEUE_SERIAL);
        _report = [NSMutableArray array];
        _poison = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)abort {
    self.stopFlag = YES;
}

#pragma mark - 小工具

- (void)say:(NSString *)fmt, ... {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [_report addObject:s];
    PHLOG(@"%@", s);
}

- (void)sleep:(NSTimeInterval)t {
    // 分片休眠，保证 abort 及时生效
    NSTimeInterval end = [NSDate date].timeIntervalSince1970 + t;
    while ([NSDate date].timeIntervalSince1970 < end) {
        if (self.stopFlag) return;
        [NSThread sleepForTimeInterval:0.1];
    }
}

static NSString *PHStr(id obj, NSString *key) {
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    id v = [(NSDictionary *)obj objectForKey:key];
    if (!v || v == [NSNull null]) return nil;
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v respondsToSelector:@selector(stringValue)]) return [v stringValue];
    return nil;
}

static NSDictionary *PHDict(id obj, NSString *key) {
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    id v = [(NSDictionary *)obj objectForKey:key];
    return [v isKindOfClass:[NSDictionary class]] ? v : nil;
}

/// 数值型字段：能转数字就转 NSNumber，保持与安卓 JSONObject.put(int) 一致的线上形状
static id PHNum(NSString *s) {
    if (!s.length) return nil;
    NSScanner *sc = [NSScanner scannerWithString:s];
    long long ll = 0;
    if ([sc scanLongLong:&ll] && sc.isAtEnd) return @(ll);
    return s;
}

- (NSDictionary *)call:(NSString *)api version:(NSString *)ver params:(NSDictionary *)params label:(NSString *)label {
    if (self.stopFlag) return nil;
    NSString *err = nil;
    NSDictionary *json = [[PHMtop shared] callSync:api version:ver params:params errMsg:&err timeout:30];
    NSString *ret = [PHMtop ret0:json];
    PHLOGV(@"[%@] %@ → ret=%@ err=%@", label, api, ret ?: @"(nil)", err ?: @"-");
    if (!json) {
        [self say:@"[%@] 无响应 (%@)", label, err ?: @"unknown"];
    }
    return json;
}

- (BOOL)isSuccess:(NSDictionary *)json {
    NSString *ret = [PHMtop ret0:json];
    return ret && [ret containsString:@"SUCCESS"];
}

- (BOOL)isParamErr:(NSDictionary *)json {
    NSString *ret = [PHMtop ret0:json];
    if (!ret) return NO;
    return [ret containsString:@"PARAM_ILLEGAL"] || [ret containsString:@"PARAM_INVALID"];
}

- (void)noteTrigger:(NSString *)type json:(NSDictionary *)json {
    if ([self isSuccess:json]) {
        [_poison removeObjectForKey:type];
    } else if ([self isParamErr:json]) {
        _poison[type] = @([_poison[type] integerValue] + 1);
    }
}

- (BOOL)triggerBlocked:(NSString *)type {
    return [_poison[type] integerValue] >= 2;
}

#pragma mark - 主流程

- (void)runWithCompletion:(void (^)(NSString *, NSInteger, NSInteger))completion {
    @synchronized (self) {
        if (self.running) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(@"已在执行中", 0, 0); });
            }
            return;
        }
        self.running = YES;
        self.stopFlag = NO;
    }

    dispatch_async(_q, ^{
        [_report removeAllObjects];
        _ok = 0; _fail = 0;
        _itemPool = nil;
        [_poison removeAllObjects];

        NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;
        [self say:@"=== 跑批开始 · 闲鱼 iOS ==="];

        if (![[PHMtop shared] prepare]) {
            [self say:@"MTOP 协议栈未就绪，请在闲鱼首页停留几秒后重试"];
            [self finish:t0 completion:completion];
            return;
        }

        PHConfig *cfg = [PHConfig shared];

        if (cfg.doSignin) {
            [self stepSignin];
            [self sleep:1.0];
        }
        if (cfg.doPlaySignin) {
            [self stepPlaySignin];
            [self sleep:1.0];
        }
        if (cfg.doPolish) {
            [self stepPolish];
            [self sleep:1.0];
        }
        if (cfg.doShop) {
            [self stepShop];
            [self sleep:1.0];
        }
        if (cfg.doTasks) {
            [self stepTasks];
            [self sleep:1.0];
            [self stepClaimPass:@"复核"];
        }
        if (cfg.doLottery) {
            [self stepLottery];
        }

        [self finish:t0 completion:completion];
    });
}

- (void)finish:(NSTimeInterval)t0 completion:(void (^)(NSString *, NSInteger, NSInteger))completion {
    NSTimeInterval cost = [NSDate date].timeIntervalSince1970 - t0;
    [self say:@"=== 跑批结束 · 成功 %ld · 失败 %ld · 用时 %.0fs ===", (long)_ok, (long)_fail, cost];
    NSString *txt = [_report componentsJoinedByString:@"\n"];
    [[PHConfig shared] markRun];

    self.running = NO;
    if (completion) {
        NSInteger ok = _ok, fail = _fail;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(txt, ok, fail); });
    }
}

#pragma mark - 单点步骤

- (void)stepSignin {
    NSDictionary *j = [self call:@"mtop.taobao.idle.coin.signin" version:@"1.0" params:@{} label:@"签到"];
    if ([self isSuccess:j]) { _ok++; [self say:@"[签到] SUCCESS"]; }
    else {
        NSString *ret = [PHMtop ret0:j];
        if (ret && ([ret containsString:@"SIGNED"] || [ret containsString:@"已签"])) {
            [self say:@"[签到] 今日已签（幂等）"];
        } else {
            _fail++; [self say:@"[签到] %@", ret ?: @"无响应"];
        }
    }
}

- (void)stepPlaySignin {
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    PHLocContext *loc = [PHLocContext shared];
    if (loc.asac) p[@"asac"] = loc.asac;
    if (loc.fishAdCode) p[@"fishAdCode"] = loc.fishAdCode;
    if (loc.gps) p[@"gps"] = loc.gps;
    p[@"playId"] = @4;
    p[@"usertoken"] = @"";

    NSDictionary *j = [self call:@"mtop.taobao.idle.play.sign.in" version:@"1.0" params:p label:@"玩一玩签到"];
    if ([self isSuccess:j]) { _ok++; [self say:@"[玩一玩签到] SUCCESS"]; }
    else {
        NSString *ret = [PHMtop ret0:j];
        if (ret && [ret containsString:@"SIGNED_IN"]) [self say:@"[玩一玩签到] 今日已签"];
        else { _fail++; [self say:@"[玩一玩签到] %@", ret ?: @"无响应"]; }
    }
}

- (void)stepPolish {
    NSDictionary *j = [self call:@"mtop.taobao.idle.item.polish" version:@"2.0"
                          params:@{@"type": @"originaljson"} label:@"擦亮"];
    NSString *ret = [PHMtop ret0:j];
    if ([self isSuccess:j]) {
        NSArray *items = PHDict(j, @"data")[@"exposureItems"];
        _ok++;
        [self say:@"[擦亮] SUCCESS%@", [items isKindOfClass:[NSArray class]] && items.count ? [NSString stringWithFormat:@" · %lu 个宝贝", (unsigned long)items.count] : @"（服务端受理）"];
    } else if (ret && ([ret containsString:@"POLISH_AGAIN"] || [ret containsString:@"POLISH_FAILED3"])) {
        [self say:@"[擦亮] 今日已擦/次数用完"];
    } else {
        _fail++; [self say:@"[擦亮] %@", ret ?: @"无响应"];
    }
}

- (void)stepShop {
    NSDictionary *j = [self call:@"mtop.taobao.idle.startup.shop.daily.benefit" version:@"1.0" params:@{} label:@"小店日福利"];
    if ([self isSuccess:j]) { _ok++; [self say:@"[小店] SUCCESS"]; }
    else { _fail++; [self say:@"[小店] %@", [PHMtop ret0:j] ?: @"无响应"]; }
}

#pragma mark - 任务链

- (NSArray<NSDictionary *> *)fetchTaskList:(NSString *)label {
    NSDictionary *j = [self call:@"mtop.taobao.idle.task.queryolivertasklist" version:@"2.0"
                          params:@{@"sceneId": @496} label:label];
    NSDictionary *data = PHDict(j, @"data");
    id list = data[@"taskList"];
    if (![list isKindOfClass:[NSArray class]]) return nil;

    NSMutableArray *out = [NSMutableArray array];
    for (id t in (NSArray *)list) {
        if ([t isKindOfClass:[NSDictionary class]]) [out addObject:t];
    }
    return out;
}

- (void)stepTasks {
    NSArray<NSDictionary *> *tasks = [self fetchTaskList:@"任务列表"];
    if (!tasks) {
        [self say:@"任务列表获取失败"];
        return;
    }
    [self say:@"任务总数: %lu", (unsigned long)tasks.count];

    NSMutableArray<NSDictionary *> *claimable = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *triggerable = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *browse = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    for (NSDictionary *t in tasks) {
        NSString *deliveryId = PHStr(t, @"deliveryId");
        if (!deliveryId.length || [seen containsObject:deliveryId]) continue;
        [seen addObject:deliveryId];

        NSDictionary *material = PHDict(t, @"materialDTO");
        NSDictionary *benefit = PHDict(t, @"taskBenefitDTO");
        NSString *status = PHStr(t, @"idleTaskStatus");
        NSString *actionType = PHStr(material, @"actionType") ?: @"";
        NSString *action = PHStr(material, @"action") ?: @"";
        BOOL needBenefit = [PHStr(benefit, @"needBenefit") isEqualToString:@"true"];

        // 可领：AWARD，或 COMPLETE 且仍需发奖
        if ([status isEqualToString:@"AWARD"] || ([status isEqualToString:@"COMPLETE"] && needBenefit)) {
            [claimable addObject:t];
            continue;
        }

        if (![status isEqualToString:@"ACCEPTED"]) continue;

        if ([actionType isEqualToString:@"idleCoinFeesAnchor"]) {
            [browse addObject:t];   // 浏览任务：走 nextfresh 商品池
            continue;
        }
        if ([action containsString:@"showAds"]) {
            // 激励视频任务需要真实广告回调，协议层无法伪造，跳过并说明
            [self say:@"[跳过] 激励视频任务「%@」需真实广告播放", PHStr(material, @"title") ?: deliveryId];
            continue;
        }
        if ([action containsString:@"xianyu/search.html"]) {
            // 搜一搜：字段闸后走标准触发 + 搜索行为
            [triggerable addObject:t];
            continue;
        }
        if ([actionType isEqualToString:@"clickFinish"] || [actionType isEqualToString:@"EXCUTE"] ||
            [actionType isEqualToString:@"PLAINVISIT"] || [actionType isEqualToString:@"VISIT"] ||
            [actionType isEqualToString:@"SYSTEM_SWITCH"] || [actionType isEqualToString:@"bbdbindex.html"]) {
            [triggerable addObject:t];
            continue;
        }

        // 其余 ACCEPTED：保守跳过，不发必然失败的请求
        PHLOGV(@"[任务] 未覆盖类型 status=%@ actionType=%@ action=%@ 跳过", status, actionType, action);
    }

    [self say:@"可领:%lu 可触发:%lu 浏览:%lu", (unsigned long)claimable.count,
          (unsigned long)triggerable.count, (unsigned long)browse.count];

    // 1) 先领已有的
    for (NSDictionary *t in claimable) {
        if (self.stopFlag) return;
        [self claimOne:t label:@"领取"];
        [self sleep:1.2];
    }

    // 2) 再触发
    for (NSDictionary *t in triggerable) {
        if (self.stopFlag) return;
        [self triggerOne:t];
        [self sleep:1.2];
    }

    // 3) 触发后再领一轮
    if (triggerable.count) {
        [self stepClaimPass:@"触发后"];
    }

    // 4) 浏览任务
    for (NSDictionary *t in browse) {
        if (self.stopFlag) return;
        [self browseOne:t];
    }
}

- (NSDictionary *)triggerBody:(NSDictionary *)task extra:(NSDictionary *)extra {
    NSString *deliveryId = PHStr(task, @"deliveryId");
    NSString *fromToken = PHStr(task, @"fromToken");
    NSString *groupId = PHStr(task, @"groupId");
    NSString *sceneId = PHStr(task, @"sceneId") ?: kSceneId;

    // 字段闸：缺任一 → 不发
    if (!deliveryId.length || !fromToken.length || !groupId.length) return nil;

    NSMutableDictionary *b = [NSMutableDictionary dictionary];
    b[@"sceneId"] = PHNum(sceneId) ?: @496;
    b[@"deliveryId"] = deliveryId;
    b[@"fromToken"] = fromToken;
    b[@"groupId"] = PHNum(groupId) ?: groupId;
    for (NSString *k in extra) {
        if (!b[k]) b[k] = extra[k];
    }
    return b;
}

- (void)triggerOne:(NSDictionary *)task {
    NSDictionary *material = PHDict(task, @"materialDTO");
    NSString *title = PHStr(material, @"title") ?: PHStr(task, @"deliveryId");
    NSString *actionType = PHStr(material, @"actionType") ?: @"task";
    NSString *action = PHStr(material, @"action") ?: @"";

    if ([self triggerBlocked:actionType]) {
        [self say:@"[触发] %@ 跳过（同类本轮连败 2 次）", title];
        return;
    }

    NSDictionary *body = [self triggerBody:task extra:nil];
    if (!body) {
        [self say:@"[触发] %@ 跳过（列表未下发 fromToken/groupId）", title];
        return;
    }

    NSDictionary *j = [self call:@"mtop.taobao.idle.task.uploadolivertasktrigger" version:@"1.0"
                          params:body label:[NSString stringWithFormat:@"触发 %@", title]];
    [self noteTrigger:actionType json:j];

    if ([self isSuccess:j]) {
        [self say:@"[触发] %@ SUCCESS", title];
        // 搜一搜类任务还需要补一次搜索行为
        if ([action containsString:@"xianyu/search.html"]) {
            [self sleep:0.8];
            [self call:@"mtop.taobao.idlemtopsearch.search" version:@"1.0"
                params:@{@"q": @"闲鱼", @"pageNumber": @1, @"pageSize": @10}
                 label:@"搜一搜行为"];
        }
    } else {
        [self say:@"[触发] %@ %@", title, [PHMtop ret0:j] ?: @"无响应"];
    }
}

- (void)stepClaimPass:(NSString *)tag {
    NSArray<NSDictionary *> *tasks = [self fetchTaskList:[NSString stringWithFormat:@"任务列表·%@", tag]];
    if (!tasks) return;
    for (NSDictionary *t in tasks) {
        if (self.stopFlag) return;
        NSDictionary *benefit = PHDict(t, @"taskBenefitDTO");
        NSString *status = PHStr(t, @"idleTaskStatus");
        BOOL needBenefit = [PHStr(benefit, @"needBenefit") isEqualToString:@"true"];
        if ([status isEqualToString:@"AWARD"] || ([status isEqualToString:@"COMPLETE"] && needBenefit)) {
            [self claimOne:t label:tag];
            [self sleep:1.2];
        }
    }
}

- (void)claimOne:(NSDictionary *)task label:(NSString *)label {
    NSString *deliveryId = PHStr(task, @"deliveryId");
    NSDictionary *material = PHDict(task, @"materialDTO");
    NSString *title = PHStr(material, @"title") ?: deliveryId;
    if (!deliveryId.length) return;

    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    p[@"sceneId"] = kSceneId;          // 领奖用字符串，与安卓实测一致
    p[@"deliveryId"] = deliveryId;
    PHLocContext *loc = [PHLocContext shared];
    if (loc.fishAdCode) p[@"fishAdCode"] = loc.fishAdCode;
    if (loc.gps) p[@"gps"] = loc.gps;

    NSDictionary *j = [self call:@"mtop.taobao.idle.task.getolivertaskbenefit" version:@"1.0"
                          params:p label:[NSString stringWithFormat:@"领奖 %@", title]];

    NSString *ret = [PHMtop ret0:j];
    BOOL ok = [self isSuccess:j];

    // SUCCESS ≠ 真领到：needBenefit 仍为 true 且 rewards 为空视为服务端未发奖
    if (ok) {
        NSDictionary *taskDTO = PHDict(PHDict(j, @"data"), @"taskDTO");
        NSDictionary *benefit = PHDict(taskDTO, @"taskBenefitDTO");
        id rewards = taskDTO[@"rewards"];
        BOOL stillNeed = benefit && [PHStr(benefit, @"needBenefit") isEqualToString:@"true"];
        BOOL noReward = ![rewards isKindOfClass:[NSArray class]] || [(NSArray *)rewards count] == 0;
        if (stillNeed && noReward) ok = NO;
    }

    if (ok) {
        _ok++;
        [self say:@"[%@] %@ 领取成功", label, title];
    } else {
        _fail++;
        [self say:@"[%@] %@ %@", label, title, ret ?: @"无响应"];
    }
}

#pragma mark - 浏览任务

- (NSArray<NSString *> *)itemPool {
    if (_itemPool) return _itemPool;
    NSDictionary *j = [self call:@"mtop.taobao.idlehome.idle.coin.nextfresh" version:@"1.0"
                          params:@{@"enableDx": @YES, @"lastResponseCount": @0, @"pageNumber": @1}
                           label:@"浏览任务商品源"];
    NSMutableArray *ids = [NSMutableArray array];
    id cards = PHDict(j, @"data")[@"cardList"];
    if ([cards isKindOfClass:[NSArray class]]) {
        for (id c in (NSArray *)cards) {
            NSDictionary *cd = PHDict(c, @"cardData");
            if (!cd) continue;
            if ([PHStr(cd, @"bizType") isEqualToString:@"AD"]) continue;
            NSString *itemId = PHStr(cd, @"itemId");
            if (!itemId.length) itemId = PHStr(PHDict(cd, @"trackParams"), @"itemId");
            if (itemId.length) [ids addObject:itemId];
        }
    }
    _itemPool = ids;
    return ids;
}

- (void)browseOne:(NSDictionary *)task {
    NSString *deliveryId = PHStr(task, @"deliveryId");
    NSDictionary *base = [self triggerBody:task extra:nil];
    if (!base) {
        [self say:@"[浏览] 跳过（列表未下发 fromToken/groupId）"];
        return;
    }

    NSArray<NSString *> *pool = [self itemPool];
    if (!pool.count) {
        [self say:@"[浏览] 商品源为空，跳过"];
        return;
    }
    [self say:@"[浏览] 商品源 %lu 个", (unsigned long)pool.count];

    NSInteger needTimes = 10;
    NSInteger done = 0;
    NSInteger failStreak = 0;

    for (NSUInteger i = 0; i < pool.count && i < 60 && !self.stopFlag; i++) {
        NSMutableDictionary *body = [base mutableCopy];
        body[@"implId"] = pool[i];

        NSDictionary *j = [self call:@"mtop.taobao.idle.task.uploadolivertasktrigger" version:@"1.0"
                              params:body label:[NSString stringWithFormat:@"浏览上报 %lu/%lu", (unsigned long)i + 1, (unsigned long)pool.count]];
        [self noteTrigger:[NSString stringWithFormat:@"浏览|%@", deliveryId] json:j];

        if (!j) { [self say:@"[浏览] 上报无响应，中止"]; break; }

        if ([self isSuccess:j]) {
            failStreak = 0;
            done++;
            NSDictionary *taskDTO = PHDict(PHDict(j, @"data"), @"taskDTO");
            NSDictionary *progress = PHDict(taskDTO, @"progressDTO");
            NSInteger nt = [PHStr(progress, @"needTimes") integerValue];
            if (nt > 0) needTimes = nt;
            NSInteger times = [PHStr(progress, @"times") integerValue];
            [self say:@"[浏览] step %lu → %ld/%ld", (unsigned long)i, (long)times, (long)needTimes];
            if (nt > 0 && times >= nt) {
                [self say:@"[浏览] 达到需求次数"];
                break;
            }
        } else {
            failStreak++;
            [self say:@"[浏览] step %lu 失败 %@", (unsigned long)i, [PHMtop ret0:j] ?: @"-"];
            if (failStreak >= 2) { [self say:@"[浏览] 连败 2 次，中止"]; break; }
        }
        [self sleep:5.0];   // 浏览上报需要有节奏，过快服务端不计次
    }

    if (done > 0) {
        [self say:@"[浏览] 完成 %ld 步，进行领奖", (long)done];
        [self claimOne:task label:@"浏览领奖"];
    }
}

#pragma mark - 夺宝

- (void)stepLottery {
    NSDictionary *feeds = [self call:@"mtop.taobao.idle.coin.lottery.feeds" version:@"1.0" params:@{} label:@"夺宝源"];
    if (!feeds) return;

    NSArray *list = PHDict(feeds, @"data")[@"lotteryList"];
    if (![list isKindOfClass:[NSArray class]] || [(NSArray *)list count] == 0) {
        [self say:@"[夺宝] 无可投注项"];
        return;
    }

    NSInteger used = 0;
    for (id item in (NSArray *)list) {
        if (self.stopFlag || used >= 10) break;
        NSString *lotteryId = PHStr(item, @"lotteryId") ?: PHStr(item, @"id");
        if (!lotteryId.length) continue;

        NSMutableDictionary *p = [NSMutableDictionary dictionary];
        p[@"lotteryId"] = lotteryId;
        p[@"count"] = @1;
        PHLocContext *loc = [PHLocContext shared];
        if (loc.fishAdCode) p[@"fishAdCode"] = loc.fishAdCode;
        if (loc.gps) p[@"gps"] = loc.gps;

        NSDictionary *j = [self call:@"mtop.taobao.idle.coin.lottery.bet" version:@"1.0" params:p
                              label:[NSString stringWithFormat:@"夺宝投注 %@", lotteryId]];
        if ([self isSuccess:j]) { used++; _ok++; [self say:@"[夺宝] %@ 投注成功", lotteryId]; }
        else { _fail++; }
        [self sleep:1.5];
    }
    [self say:@"[夺宝] 本轮投注 %ld 次", (long)used];
}

@end
