//
//  PHMtop.h
//  MTOP 直调客户端
//
//  多引擎设计：不同宿主版本对「谁来补鉴权」的处理不一样，
//  单一路径踩空就是全盘失败，所以这里做优先降级。
//
//  iOS 侧调用面（已从 Runner 7.29.10 二进制实证）：
//    引擎 A  MtopApiRequest     - initWithApiName:version: / addParameter:forKey: / sync / response
//    引擎 B  MtopService        + getInstance / - async_call:delegate:
//            MtopExtRequest     - initWithApiName:apiVersion: / addBizParameter:forKey:
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 构建标识，启动时打进日志，用来确认设备上跑的是哪个版本
#define PH_BUILD_ID "1.1.0"

typedef void (^PHMtopCompletion)(NSDictionary *_Nullable json, NSString *_Nullable errMsg);

typedef NS_ENUM(NSInteger, PHMtopEngine) {
    PHMtopEngineAuto = 0,       // 优先 MtopApiRequest，失败降级 MtopExtRequest
    PHMtopEngineApiRequest = 1, // 只用阿里便捷封装 MtopApiRequest
    PHMtopEngineExtRequest = 2, // 只用 MtopExtRequest + MtopService
};

@interface PHMtop : NSObject

+ (instancetype)shared;

/// 宿主 MTOP 协议栈是否已就绪
@property (nonatomic, readonly) BOOL ready;

/// 自动模式下实际命中的引擎
@property (nonatomic, readonly) PHMtopEngine activeEngine;

/// 选择引擎（默认自动）
@property (nonatomic, assign) PHMtopEngine engine;

/// 探测并缓存 MtopService 单例
- (BOOL)prepare;

- (void)call:(NSString *)api
     version:(NSString *)version
      params:(nullable NSDictionary *)params
  completion:(PHMtopCompletion)completion;

- (nullable NSDictionary *)callSync:(NSString *)api
                            version:(NSString *)version
                             params:(nullable NSDictionary *)params
                            errMsg:(NSString *_Nullable *_Nullable)errMsg
                            timeout:(NSTimeInterval)timeout;

/// 从响应里取 ret[0]（如 "SUCCESS::调用成功"）
+ (nullable NSString *)ret0:(nullable NSDictionary *)json;

/// 提取 code / msg / ret，用于诊断
+ (NSString *)describe:(nullable NSDictionary *)json;

/// 自检：对同一接口跑一遍各引擎，返回可读报告
- (void)diagnose:(void (^)(NSString *report))completion;

@end

NS_ASSUME_NONNULL_END
