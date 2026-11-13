//
//  PHCompat.h
//  XianYuPiggyHand (iOS)
//
//  兼容层：日志 / 配置 / 运行时工具 / 位置凭证捕获。
//  设计前提：运行在【非越狱 · 自签】环境，只能使用公开 ObjC Runtime，
//  不链接 substrate / ellekit / libhooker，全部函数用 dynamic_lookup 解析。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

#define PHLOG(fmt, ...) [PHLog log:fmt, ##__VA_ARGS__]
#define PHLOGV(fmt, ...) [PHLog logV:fmt, ##__VA_ARGS__]

/// 轻量日志：内存环形缓冲（给 UI 用）+ 落盘
@interface PHLog : NSObject
+ (void)log:(NSString *)fmt, ...;
+ (void)logV:(NSString *)fmt, ...;          // 详细日志，受 verbose 开关控制
+ (void)reset;
+ (NSArray<NSString *> *)snapshot;
+ (NSString *)journalPath;
@end

/// 配置持久化：沙盒 Documents/ph_config.json（自签重签后仍随容器保留）
@interface PHConfig : NSObject
+ (instancetype)shared;

@property (nonatomic, assign) BOOL enabled;          // 总开关
@property (nonatomic, assign) BOOL autoRun;          // 启动后自动跑批
@property (nonatomic, assign) NSInteger intervalH;   // 跑批间隔（1-12 小时）
@property (nonatomic, assign) BOOL doSignin;         // 每日签到
@property (nonatomic, assign) BOOL doPlaySignin;     // 玩一玩签到
@property (nonatomic, assign) BOOL doPolish;         // 擦亮宝贝
@property (nonatomic, assign) BOOL doShop;           // 小店日福利
@property (nonatomic, assign) BOOL doTasks;          // 任务链（触发+领奖）
@property (nonatomic, assign) BOOL doBrowse;         // 浏览任务
@property (nonatomic, assign) BOOL doLottery;        // 夺宝
@property (nonatomic, assign) BOOL verbose;          // 详细日志
@property (nonatomic, assign) BOOL showBall;         // 悬浮球

- (void)save;
- (NSTimeInterval)lastRunAt;
- (void)markRun;
@end

/// 本机位置/凭证上下文：从闲鱼自身发出的 MTOP 请求里抄写 fishAdCode / gps / asac
/// 取不到就省略字段（服务端对缺字段照常服务），绝不使用硬编码假值。
@interface PHLocContext : NSObject
+ (instancetype)shared;
- (void)captureFromBizParams:(NSDictionary *)params;
- (nullable NSString *)fishAdCode;
- (nullable NSString *)gps;
- (nullable NSString *)asac;
/// "fishAdCode":"..","gps":"..",  结尾带逗号；无值时返回空串
- (NSString *)jsonPair;
/// {"fishAdCode":"..","gps":".."}  无值时为 "{}"
- (NSString *)jsonPairObj;
@end

/// ObjC Runtime 工具
@interface PHRuntime : NSObject
+ (nullable Class)cls:(NSString *)name;
+ (BOOL)cls:(NSString *)name respondsToSel:(NSString *)sel;
+ (BOOL)obj:(id)obj respondsToSel:(NSString *)sel;
/// 替换实例方法实现，返回原 IMP（可为 NULL）
+ (nullable IMP)hookInstance:(Class)cls sel:(SEL)sel newImp:(IMP)imp;
/// 安全调用返回值 id 的方法
+ (nullable id)invoke:(id)target sel:(NSString *)sel;
+ (nullable id)invoke:(id)target sel:(NSString *)sel arg:(nullable id)arg;
+ (nullable id)invoke:(id)target sel:(NSString *)sel arg1:(nullable id)a1 arg2:(nullable id)a2;
@end

NS_ASSUME_NONNULL_END
