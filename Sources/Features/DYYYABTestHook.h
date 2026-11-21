#import <Foundation/Foundation.h>

// 声明 DYYYABTestHook 类的接口
@interface DYYYABTestHook : NSObject

/** 判断当前是否为覆写模式 */
+ (BOOL)isPatchMode;

/** 获取本地文件是否已加载的状态 */
+ (BOOL)isLocalConfigLoaded;

/** 获取禁止下发配置的状态 */
+ (BOOL)isABTestBlockEnabled;

/** 设置禁止下发配置的状态 */
+ (void)setABTestBlockEnabled:(BOOL)enabled;

/** 清除本地加载的ABTest数据，为下次调用 loadLocalABTestConfig 做准备 */
+ (void)cleanLocalABTestData;

/** 加载本地ABTest配置文件 */
+ (void)loadLocalABTestConfig;

/** 串行校验并原子导入本地配置，完成前释放安全作用域；仅成功才发布状态和通知。 */
+ (void)importLocalABTestConfigFromURL:(NSURL * _Nullable)url
                          completion:(void (^ _Nullable)(BOOL success, NSError * _Nullable error))completion;

/** 串行删除配置，成功或明确不存在才清除状态；完成回调和成功通知均在主线程。 */
+ (void)deleteLocalABTestConfigWithCompletion:(void (^ _Nullable)(BOOL success, NSError * _Nullable error))completion;

/** 应用本地ABTest配置数据 (负责根据模式处理并应用到 Manager) */
+ (void)applyFixedABTestData;

/** 获取当前ABTest数据 (从 AWEABTestManager 获取) */
+ (NSDictionary *)getCurrentABTestData;

/** 当前是否处于远程模式 */
+ (BOOL)isRemoteMode;

/**
 * 从网络检查并下载最新配置。
 * @param notify 完成后是否显示提示
 */
+ (void)checkForRemoteConfigUpdate:(BOOL)notify;

@end
