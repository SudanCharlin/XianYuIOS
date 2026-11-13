//
//  PHHUD.h
//  悬浮球 + 控制面板
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PHHUD : NSObject
+ (instancetype)shared;

- (void)attach;                 // 挂载悬浮球（幂等）
- (void)detach;                 // 移除
- (void)refresh;                // 按配置刷新悬浮球可见性
- (void)presentPanel;           // 直接打开面板
- (void)toast:(NSString *)text; // 轻提示
@end

NS_ASSUME_NONNULL_END
