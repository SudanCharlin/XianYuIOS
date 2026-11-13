//
//  PHMtop.h
//  MTOP 直调客户端
//
//  原理（与安卓模块同构）：不自己实现签名/登录态，直接借用闲鱼自身的
//  MTOP 协议栈发送请求 —— 登录态(sid/cookie)、WUA、设备指纹、ttid
//  全部由宿主 SDK 自动附加。
//
//  iOS 侧调用面（已从 Runner 7.29.10 二进制实证）：
//    MtopService      + getInstance                     -> MtopService*
//    MtopService      - async_call:delegate:            v32@0:8@16@24
//    MtopService      - sync_call:                      @24@0:8@16
//    MtopExtRequest   - initWithApiName:apiVersion:     @32@0:8@16@24
//    MtopExtRequest   - addBizParameter:forKey:         @32@0:8@16@24
//    MtopExtRequest   - setIsEnableWUA:                 v20@0:8B16
//    MtopExtResponse  - json / body / isSucceed
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^PHMtopCompletion)(NSDictionary *_Nullable json, NSString *_Nullable errMsg);

@interface PHMtop : NSObject

+ (instancetype)shared;

/// 宿主 MTOP 协议栈是否已就绪（App 启动后需等待其初始化）
@property (nonatomic, readonly) BOOL ready;

/// 探测并缓存 MtopService 单例
- (BOOL)prepare;

/// 异步调用。回调在内部队列执行，json 为响应体根字典。
- (void)call:(NSString *)api
     version:(NSString *)version
      params:(nullable NSDictionary *)params
  completion:(PHMtopCompletion)completion;

/// 同步调用：必须在【非主线程】调用，内部等待回调。
- (nullable NSDictionary *)callSync:(NSString *)api
                            version:(NSString *)version
                             params:(nullable NSDictionary *)params
                            errMsg:(NSString *_Nullable *_Nullable)errMsg
                            timeout:(NSTimeInterval)timeout;

/// 从响应里取 ret[0]（如 "SUCCESS::调用成功"）
+ (nullable NSString *)ret0:(nullable NSDictionary *)json;

@end

NS_ASSUME_NONNULL_END
