//
//  PHCompat.m
//

#import "PHCompat.h"

#pragma mark - PHLog

static NSMutableArray<NSString *> *gLines = nil;
static NSObject *gLock = nil;
static NSDateFormatter *gFmt = nil;

@implementation PHLog

+ (void)initialize {
    if (self == [PHLog class]) {
        gLines = [NSMutableArray array];
        gLock = [NSObject new];
        gFmt = [NSDateFormatter new];
        gFmt.dateFormat = @"HH:mm:ss.SSS";
    }
}

+ (NSString *)journalPath {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) docs = NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:@"ph_journal.log"];
}

+ (void)append:(NSString *)line {
    @synchronized (gLock) {
        [gLines addObject:line];
        if (gLines.count > 400) [gLines removeObjectsInRange:NSMakeRange(0, gLines.count - 400)];
    }
    // 落盘：追加写，超过 512KB 截断重建
    NSString *p = [self journalPath];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:p contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:p];
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (__unused NSException *e) {}
}

+ (void)log:(NSString *)fmt, ... {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [gFmt stringFromDate:[NSDate date]], s];
    NSLog(@"[PiggyHand] %@", s);
    [self append:line];
}

+ (void)logV:(NSString *)fmt, ... {
    if (![PHConfig shared].verbose) return;
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [self log:@"%@", s];
}

+ (void)reset {
    @synchronized (gLock) { [gLines removeAllObjects]; }
}

+ (NSArray<NSString *> *)snapshot {
    @synchronized (gLock) { return [gLines copy]; }
}

@end

#pragma mark - PHConfig

@implementation PHConfig {
    NSMutableDictionary *_d;
}

+ (instancetype)shared {
    static PHConfig *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PHConfig new]; });
    return s;
}

- (NSString *)path {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) docs = NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:@"ph_config.json"];
}

- (instancetype)init {
    if ((self = [super init])) {
        _d = [NSMutableDictionary dictionary];
        NSData *raw = [NSData dataWithContentsOfFile:[self path]];
        if (raw) {
            id j = [NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL];
            if ([j isKindOfClass:[NSDictionary class]]) _d = [j mutableCopy];
        }
        if (_d.count == 0) {
            _d[@"enabled"] = @YES;
            _d[@"autoRun"] = @YES;
            _d[@"intervalH"] = @4;
            _d[@"doSignin"] = @YES;
            _d[@"doPlaySignin"] = @YES;
            _d[@"doPolish"] = @YES;
            _d[@"doShop"] = @YES;
            _d[@"doTasks"] = @YES;
            _d[@"doBrowse"] = @YES;
            _d[@"doLottery"] = @NO;
            _d[@"verbose"] = @NO;
            _d[@"showBall"] = @YES;
        }
    }
    return self;
}

#define PH_BOOL_GET(k) (([_d[@#k] respondsToSelector:@selector(boolValue)] ? [_d[@#k] boolValue] : NO))
#define PH_BOOL_SET(k, v) do { _d[@#k] = @(v); [self save]; } while (0)

- (BOOL)enabled { return PH_BOOL_GET(enabled); }
- (void)setEnabled:(BOOL)v { PH_BOOL_SET(enabled, v); }
- (BOOL)autoRun { return PH_BOOL_GET(autoRun); }
- (void)setAutoRun:(BOOL)v { PH_BOOL_SET(autoRun, v); }
- (NSInteger)intervalH {
    NSInteger v = [_d[@"intervalH"] integerValue];
    return (v >= 1 && v <= 12) ? v : 4;
}
- (void)setIntervalH:(NSInteger)v { _d[@"intervalH"] = @(MAX(1, MIN(12, v))); [self save]; }
- (BOOL)doSignin { return PH_BOOL_GET(doSignin); }
- (void)setDoSignin:(BOOL)v { PH_BOOL_SET(doSignin, v); }
- (BOOL)doPlaySignin { return PH_BOOL_GET(doPlaySignin); }
- (void)setDoPlaySignin:(BOOL)v { PH_BOOL_SET(doPlaySignin, v); }
- (BOOL)doPolish { return PH_BOOL_GET(doPolish); }
- (void)setDoPolish:(BOOL)v { PH_BOOL_SET(doPolish, v); }
- (BOOL)doShop { return PH_BOOL_GET(doShop); }
- (void)setDoShop:(BOOL)v { PH_BOOL_SET(doShop, v); }
- (BOOL)doTasks { return PH_BOOL_GET(doTasks); }
- (void)setDoTasks:(BOOL)v { PH_BOOL_SET(doTasks, v); }
- (BOOL)doBrowse { return PH_BOOL_GET(doBrowse); }
- (void)setDoBrowse:(BOOL)v { PH_BOOL_SET(doBrowse, v); }
- (BOOL)doLottery { return PH_BOOL_GET(doLottery); }
- (void)setDoLottery:(BOOL)v { PH_BOOL_SET(doLottery, v); }
- (BOOL)verbose { return PH_BOOL_GET(verbose); }
- (void)setVerbose:(BOOL)v { PH_BOOL_SET(verbose, v); }
- (BOOL)showBall { return PH_BOOL_GET(showBall); }
- (void)setShowBall:(BOOL)v { PH_BOOL_SET(showBall, v); }

- (void)save {
    NSData *d = [NSJSONSerialization dataWithJSONObject:_d options:NSJSONWritingPrettyPrinted error:NULL];
    [d writeToFile:[self path] atomically:YES];
}

- (NSTimeInterval)lastRunAt {
    return [_d[@"lastRunAt"] doubleValue];
}

- (void)markRun {
    _d[@"lastRunAt"] = @([[NSDate date] timeIntervalSince1970]);
    [self save];
}

@end

#pragma mark - PHLocContext

@implementation PHLocContext {
    NSString *_fishAdCode;
    NSString *_gps;
    NSString *_asac;
}

+ (instancetype)shared {
    static PHLocContext *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PHLocContext new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        // 冷启动恢复
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *p = [docs stringByAppendingPathComponent:@"ph_loc.json"];
        NSData *raw = [NSData dataWithContentsOfFile:p];
        if (raw) {
            id j = [NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL];
            if ([j isKindOfClass:[NSDictionary class]]) {
                _fishAdCode = j[@"fishAdCode"];
                _gps = j[@"gps"];
                _asac = j[@"asac"];
            }
        }
    }
    return self;
}

- (NSString *_Nullable)clean:(id)v {
    if (![v isKindOfClass:[NSString class]]) {
        if ([v respondsToSelector:@selector(stringValue)]) v = [v stringValue];
        else return nil;
    }
    NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0 || [[s lowercaseString] isEqualToString:@"null"]) return nil;
    return s;
}

- (void)captureFromBizParams:(NSDictionary *)params {
    if (![params isKindOfClass:[NSDictionary class]] || params.count == 0) return;
    __block BOOL changed = NO;

    // MTOP 的 bizParameters 值可能是 NSString 也可能是 NSNumber，也可能是 JSON 字符串
    void (^scan)(NSDictionary *) = ^(NSDictionary *d) {
        NSString *fa = [self clean:d[@"fishAdCode"]];
        NSString *gp = [self clean:d[@"gps"]];
        NSString *as = [self clean:d[@"asac"]];
        if (fa && ![fa isEqualToString:self->_fishAdCode ?: @""]) { self->_fishAdCode = fa; changed = YES; }
        if (gp && ![gp isEqualToString:self->_gps ?: @""]) { self->_gps = gp; changed = YES; }
        if (as && ![as isEqualToString:self->_asac ?: @""]) { self->_asac = as; changed = YES; }
    };

    scan(params);

    // 某些请求把业务参数整体塞在 data / param 字符串里，做一次浅解析
    for (NSString *k in @[@"data", @"param", @"params"]) {
        id v = params[k];
        if ([v isKindOfClass:[NSString class]] && [v length] > 8) {
            NSData *d = [(NSString *)v dataUsingEncoding:NSUTF8StringEncoding];
            id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
            if ([j isKindOfClass:[NSDictionary class]]) scan(j);
        } else if ([v isKindOfClass:[NSDictionary class]]) {
            scan(v);
        }
    }

    if (changed) {
        PHLOG(@"[loc] captured fishAdCode=%@ gps=%@ asac=%@",
              _fishAdCode ?: @"(nil)", _gps ?: @"(nil)", _asac.length > 8 ? [[_asac substringToIndex:4] stringByAppendingString:@"***"] : (_asac ?: @"(nil)"));
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        if (_fishAdCode) m[@"fishAdCode"] = _fishAdCode;
        if (_gps) m[@"gps"] = _gps;
        if (_asac) m[@"asac"] = _asac;
        NSData *d = [NSJSONSerialization dataWithJSONObject:m options:0 error:NULL];
        [d writeToFile:[docs stringByAppendingPathComponent:@"ph_loc.json"] atomically:YES];
    }
}

- (NSString *)fishAdCode { return _fishAdCode; }
- (NSString *)gps { return _gps; }
- (NSString *)asac { return _asac; }

- (NSString *)jsonPair {
    NSMutableString *sb = [NSMutableString string];
    if (_fishAdCode) [sb appendFormat:@"\"fishAdCode\":\"%@\",", _fishAdCode];
    if (_gps) [sb appendFormat:@"\"gps\":\"%@\",", _gps];
    return sb;
}

- (NSString *)jsonPairObj {
    NSString *p = [self jsonPair];
    if ([p hasSuffix:@","]) p = [p substringToIndex:p.length - 1];
    return [NSString stringWithFormat:@"{%@}", p];
}

@end

#pragma mark - PHRuntime

@implementation PHRuntime

+ (Class)cls:(NSString *)name {
    return NSClassFromString(name);
}

+ (BOOL)cls:(NSString *)name respondsToSel:(NSString *)sel {
    Class c = NSClassFromString(name);
    if (!c) return NO;
    return [c respondsToSelector:NSSelectorFromString(sel)] || [[c instance] respondsToSelector:NSSelectorFromString(sel)];
}

+ (BOOL)obj:(id)obj respondsToSel:(NSString *)sel {
    return [obj respondsToSelector:NSSelectorFromString(sel)];
}

+ (IMP)hookInstance:(Class)cls sel:(SEL)sel newImp:(IMP)imp {
    if (!cls || !sel || !imp) return NULL;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        PHLOG(@"[hook] MISS -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel));
        return NULL;
    }
    IMP old = method_setImplementation(m, imp);
    PHLOG(@"[hook] -[%@ %@] ok", NSStringFromClass(cls), NSStringFromSelector(sel));
    return old;
}

+ (id)invoke:(id)target sel:(NSString *)sel {
    if (!target) return nil;
    SEL s = NSSelectorFromString(sel);
    if (![target respondsToSelector:s]) return nil;
    IMP imp = [target methodForSelector:s];
    if (!imp) return nil;
    return ((id (*)(id, SEL))imp)(target, s);
}

+ (id)invoke:(id)target sel:(NSString *)sel arg:(id)arg {
    if (!target) return nil;
    SEL s = NSSelectorFromString(sel);
    if (![target respondsToSelector:s]) return nil;
    IMP imp = [target methodForSelector:s];
    if (!imp) return nil;
    return ((id (*)(id, SEL, id))imp)(target, s, arg);
}

+ (id)invoke:(id)target sel:(NSString *)sel arg1:(id)a1 arg2:(id)a2 {
    if (!target) return nil;
    SEL s = NSSelectorFromString(sel);
    if (![target respondsToSelector:s]) return nil;
    IMP imp = [target methodForSelector:s];
    if (!imp) return nil;
    return ((id (*)(id, SEL, id, id))imp)(target, s, a1, a2);
}

@end
