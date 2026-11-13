//
//  PHEngine.h
//  任务自动化引擎（iOS）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PHEngine : NSObject

+ (instancetype)shared;

/// 是否正在跑批
@property (nonatomic, readonly) BOOL running;

/// 启动一次完整跑批（内部后台串行队列执行，回调在主线程）
- (void)runWithCompletion:(void (^_Nullable)(NSString *report, NSInteger okCount, NSInteger failCount))completion;

/// 中止
- (void)abort;

@end

NS_ASSUME_NONNULL_END
