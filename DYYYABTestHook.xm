#import "DYYYABTestHook.h"
#import "DYYYConstants.h"
#import "DYYYABConfigValidation.h"
#import "DYYYUtils.h"
#import <objc/runtime.h>

static BOOL s_abTestBlockEnabled = NO;
static BOOL s_isApplyingFixedData = NO;
static NSDictionary *s_localABTestData = nil;
static DYYYABConfigMode s_fileMode = DYYYABConfigModeUnspecified;

// 默认远程配置地址常量
static NSString *const kDefaultRemoteConfigURL = DYYY_DEFAULT_ABTEST_URL;
static NSString *const kDYYYTabBarHeightKey = @"DYYYTabBarHeight";
static NSString *const kDYYYABTestTabBarHeightConfigKey = @"hp_tab_bar_custom_height_config";

static BOOL s_localConfigLoaded = NO;
static NSUInteger s_remoteRequestGeneration = 0;
static dispatch_queue_t s_abTestHookQueue;
static dispatch_once_t s_queueOnceToken;
static void *s_queueSpecificKey = &s_queueSpecificKey;

static dispatch_queue_t DYYYABTestQueue() {
    dispatch_once(&s_queueOnceToken, ^{
      if (!s_abTestHookQueue) {
          s_abTestHookQueue = dispatch_queue_create("com.dyyy.abtesthook.queue", DISPATCH_QUEUE_SERIAL);
          // 标记串行队列，避免队列内同步调用造成死锁
          dispatch_queue_set_specific(s_abTestHookQueue, s_queueSpecificKey, (void *)1, NULL);
      }
    });
    return s_abTestHookQueue;
}

static void DYYYQueueSync(dispatch_block_t block) {
    dispatch_queue_t queue = DYYYABTestQueue();
    if (dispatch_get_specific(s_queueSpecificKey)) {
        block();
    } else {
        dispatch_sync(queue, block);
    }
}

// 队列内直接执行，避免提交后的应用动作排到另一份配置之后。
static void DYYYQueueAsync(dispatch_block_t block) {
    if (dispatch_get_specific(s_queueSpecificKey)) block();
    else dispatch_async(DYYYABTestQueue(), block);
}

static NSString *DYYYABConfigFilePath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [[documents stringByAppendingPathComponent:@"DYYY"] stringByAppendingPathComponent:@"abtest_data_fixed.json"];
}

static void DYYYABConfigShowResult(BOOL notify, NSString *message) {
    if (!notify) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [DYYYUtils showToast:message]; });
}

static void DYYYABConfigFinishLocalOperation(BOOL success, NSError *error, void (^completion)(BOOL, NSError *)) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (success) {
          [[NSNotificationCenter defaultCenter] postNotificationName:DYYY_REMOTE_CONFIG_CHANGED_NOTIFICATION object:nil];
      }
      if (completion) completion(success, error);
    });
}

static NSNumber *DYYYResolveTabBarHeightFromSettings(void) {
    NSString *heightString = [[NSUserDefaults standardUserDefaults] stringForKey:kDYYYTabBarHeightKey];
    if (heightString.length == 0) {
        return nil;
    }

    float parsedValue = 0.0f;
    NSScanner *scanner = [NSScanner scannerWithString:heightString];
    if (![scanner scanFloat:&parsedValue] || !scanner.isAtEnd || parsedValue <= 0.0f) {
        return nil;
    }
    return @(parsedValue);
}

static NSDictionary *DYYYBuildTabBarHeightConfig(NSDictionary *existingConfig, NSNumber *contentHeight) {
    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    if ([existingConfig isKindOfClass:[NSDictionary class]]) {
        [config addEntriesFromDictionary:existingConfig];
    }

    config[@"content_height"] = contentHeight;
    if (!config[@"custom_safe_area_bottom_offet"]) {
        config[@"custom_safe_area_bottom_offet"] = @0;
    }
    if (!config[@"custom_safe_area_bottom_offset_black_set"]) {
        config[@"custom_safe_area_bottom_offset_black_set"] = @[];
    }
    if (!config[@"custom_tab_bar_height_black_set"]) {
        config[@"custom_tab_bar_height_black_set"] = @[];
    }
    if (!config[@"enabled"]) {
        config[@"enabled"] = @YES;
    }
    if (!config[@"overlap_height"]) {
        config[@"overlap_height"] = @14;
    }

    return [config copy];
}

static NSDictionary *DYYYInjectTabBarHeightConfig(NSDictionary *sourceData, NSNumber *contentHeight) {
    if (!contentHeight) {
        return sourceData;
    }

    NSMutableDictionary *patchedData = [NSMutableDictionary dictionaryWithDictionary:sourceData ?: @{}];
    NSDictionary *existingConfig = nil;
    id existingConfigValue = patchedData[kDYYYABTestTabBarHeightConfigKey];
    if ([existingConfigValue isKindOfClass:[NSDictionary class]]) {
        existingConfig = (NSDictionary *)existingConfigValue;
    }
    patchedData[kDYYYABTestTabBarHeightConfigKey] = DYYYBuildTabBarHeightConfig(existingConfig, contentHeight);

    return [patchedData copy];
}

static void DYYYApplyTabBarHeightToCurrentABTestDataIfNeeded(void) {
    NSNumber *contentHeight = DYYYResolveTabBarHeightFromSettings();
    if (!contentHeight) {
        return;
    }

    AWEABTestManager *manager = [%c(AWEABTestManager) sharedManager];
    if (!manager) {
        return;
    }

    NSDictionary *currentData = [manager abTestData];
    if (currentData && ![currentData isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSDictionary *patchedData = DYYYInjectTabBarHeightConfig(currentData ?: @{}, contentHeight);
    if (currentData && [currentData isEqualToDictionary:patchedData]) {
        return;
    }

    s_isApplyingFixedData = YES;
    @try {
        [manager setAbTestData:patchedData];
    } @finally {
        s_isApplyingFixedData = NO;
    }
    NSLog(@"[DYYY] 已通过 ABTest 注入底栏高度: %@", contentHeight);
}

@implementation DYYYABTestHook

/** 依据 DYYYABTestModeString 判断模式：YES 覆写，NO 替换。 */
+ (BOOL)isPatchMode {
    __block BOOL patch = YES;
    DYYYQueueSync(^{
      id saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYABTestModeString"];
      DYYYABConfigMode mode = DYYYABConfigModeForPreference(saved);
      // 非法设置保持旧有覆写回退；未设置或远程模式才服从文件模式。
      patch = (saved && mode == DYYYABConfigModeUnspecified) ? YES : DYYYABConfigUsesPatchMode(mode, s_fileMode);
    });
    return patch;
}

/** 本地文件是否已加载。 */
+ (BOOL)isLocalConfigLoaded {
    __block BOOL loaded = NO;
    DYYYQueueSync(^{
      loaded = s_localConfigLoaded;
    });
    return loaded;
}

/** 当前是否处于远程模式。 */
+ (BOOL)isRemoteMode {
    return DYYYABConfigModeForPreference([[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYABTestModeString"]) == DYYYABConfigModeRemote;
}

/** 禁止下发配置是否开启。 */
+ (BOOL)isABTestBlockEnabled {
    __block BOOL enabled = NO;
    DYYYQueueSync(^{
      enabled = s_abTestBlockEnabled;
    });
    return enabled;
}

/** 设置禁止下发配置开关。 */
+ (void)setABTestBlockEnabled:(BOOL)enabled {
    DYYYQueueAsync(^{
      s_abTestBlockEnabled = enabled;
    });
}

/** 清除内存配置，并使清除前启动的远程请求失效。 */
+ (void)cleanLocalABTestData {
    DYYYQueueAsync(^{
      ++s_remoteRequestGeneration;
      s_localABTestData = nil;
      s_fileMode = DYYYABConfigModeUnspecified;
      s_localConfigLoaded = NO;
      NSLog(@"[DYYY] 本地ABTest配置已清除");
    });
}

/** 仅成功读取有效配置后标记已加载，失败允许后续重试。 */
+ (void)loadLocalABTestConfig {
    DYYYQueueAsync(^{
      if (s_localConfigLoaded) return;
      NSError *error = nil;
      NSData *jsonData = DYYYABConfigReadLocalFileURL([NSURL fileURLWithPath:DYYYABConfigFilePath()], &error);
      DYYYABConfigMode mode = DYYYABConfigModeUnspecified;
      NSDictionary *data = DYYYABConfigParseJSON(jsonData, &mode, &error);
      if (!data) {
          NSLog(@"[DYYY] ABTest本地配置读取或校验失败: %@", error.localizedDescription);
          return;
      }
      s_localABTestData = data;
      s_fileMode = mode;
      s_localConfigLoaded = YES;
      NSLog(@"[DYYY] ABTest本地配置已从文件加载成功");
    });
}

/** 导入和远程提交共用队列及持久化校验，失败不触碰旧状态。 */
+ (void)importLocalABTestConfigFromURL:(NSURL *)url completion:(void (^)(BOOL, NSError *))completion {
    DYYYQueueAsync(^{
      ++s_remoteRequestGeneration;
      NSError *error = nil;
      NSData *jsonData = DYYYABConfigReadLocalFileURL(url, &error);
      NSDictionary *config = nil;
      DYYYABConfigMode mode = DYYYABConfigModeUnspecified;
      if (!jsonData || !DYYYABConfigPersistJSON(jsonData, DYYYABConfigFilePath(), &config, &mode, NULL, &error)) {
          DYYYABConfigFinishLocalOperation(NO, error, completion);
          return;
      }
      s_localABTestData = config;
      s_fileMode = mode;
      s_localConfigLoaded = YES;
      [[NSUserDefaults standardUserDefaults] setBool:NO forKey:DYYY_REMOTE_CONFIG_FLAG_KEY];
      [self applyFixedABTestData];
      DYYYABConfigFinishLocalOperation(YES, nil, completion);
    });
}

/** 删除与导入、网络提交互斥，只有磁盘已删除才清除内存和远程标记。 */
+ (void)deleteLocalABTestConfigWithCompletion:(void (^)(BOOL, NSError *))completion {
    DYYYQueueAsync(^{
      ++s_remoteRequestGeneration;
      NSError *error = nil;
      if (!DYYYABConfigDeleteFile(DYYYABConfigFilePath(), &error)) {
          DYYYABConfigFinishLocalOperation(NO, error, completion);
          return;
      }
      s_localABTestData = nil;
      s_fileMode = DYYYABConfigModeUnspecified;
      s_localConfigLoaded = NO;
      [[NSUserDefaults standardUserDefaults] setBool:NO forKey:DYYY_REMOTE_CONFIG_FLAG_KEY];
      DYYYABConfigFinishLocalOperation(YES, nil, completion);
    });
}

/** 按当前模式把本地 ABTest 数据应用到 Manager，内部含应用条件判断。 */
+ (void)applyFixedABTestData {
    DYYYQueueAsync(^{
      if (!s_abTestBlockEnabled || !s_localABTestData) {
          NSLog(@"[DYYY] 不满足应用本地配置的条件 (禁止下发=%@, 数据是否为空=%@)", s_abTestBlockEnabled ? @"开启" : @"关闭", s_localABTestData ? @"否" : @"是");
          s_isApplyingFixedData = NO; // 确保标志关闭
          return;
      }

      AWEABTestManager *manager = [%c(AWEABTestManager) sharedManager];
      if (!manager) {
          NSLog(@"[DYYY] 无法应用本地配置：AWEABTestManager 实例不可用");
          s_isApplyingFixedData = NO; // 确保标志关闭
          return;
      }

      BOOL usingPatchMode = [self isPatchMode];
      NSDictionary *dataToApply = nil;

      if (usingPatchMode) {
          // 覆写模式：本地配置合并现有配置
          id currentData = [manager abTestData];
          if (currentData && ![currentData isKindOfClass:[NSDictionary class]]) return;
          NSMutableDictionary *mergedData = [NSMutableDictionary dictionaryWithDictionary:currentData ?: @{}];
          [mergedData addEntriesFromDictionary:s_localABTestData];
          dataToApply = [mergedData copy];
      } else {
          // 替换模式：直接使用本地配置
          dataToApply = [s_localABTestData copy];
      }

      NSNumber *contentHeight = DYYYResolveTabBarHeightFromSettings();
      if (contentHeight) {
          dataToApply = DYYYInjectTabBarHeightConfig(dataToApply ?: @{}, contentHeight);
      }

      // 仅本次本地应用临时放行，原生抛出异常也必须恢复拦截状态。
      s_isApplyingFixedData = YES;
      @try {
          [manager setAbTestData:dataToApply];
      } @finally {
          s_isApplyingFixedData = NO;
      }

      NSLog(@"[DYYY] ABTest本地配置已应用");
    });
}

/** 获取当前ABTest数据 */
+ (NSDictionary *)getCurrentABTestData {
    AWEABTestManager *manager = [%c(AWEABTestManager) sharedManager];
    return manager ? [manager abTestData] : nil;
}

/** 网络回调统一回到串行队列，最后发起的请求才有提交资格。 */
+ (void)checkForRemoteConfigUpdate:(BOOL)notify {
    DYYYQueueAsync(^{
      NSUInteger generation = ++s_remoteRequestGeneration;
      id value = [[NSUserDefaults standardUserDefaults] objectForKey:@"DYYYRemoteConfigURL"];
      if (!value || ([value isKindOfClass:[NSString class]] && [value length] == 0)) value = kDefaultRemoteConfigURL;
      NSURL *url = DYYYABConfigHTTPSURL(value);
      if (!url) {
          DYYYABConfigShowResult(notify, @"配置地址无效");
          return;
      }
      NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        DYYYQueueAsync(^{
          if (generation != s_remoteRequestGeneration) return;
          if (error || !DYYYABConfigAcceptsResponse(response) || !data || !DYYYABConfigCanAppendBytes(0, data.length)) {
              DYYYABConfigShowResult(notify, @"配置更新失败");
              return;
          }
          NSError *commitError = nil;
          NSDictionary *config = nil;
          DYYYABConfigMode mode = DYYYABConfigModeUnspecified;
          BOOL updated = NO;
          if (!DYYYABConfigPersistJSON(data, DYYYABConfigFilePath(), &config, &mode, &updated, &commitError)) {
              NSLog(@"[DYYY] ABTest远程配置校验或保存失败: %@", commitError.localizedDescription);
              DYYYABConfigShowResult(notify, @"配置校验或保存失败");
              return;
          }
          // 磁盘成功后一次发布配置，不清空旧状态，不排入二次异步加载。
          s_localABTestData = config;
          s_fileMode = mode;
          s_localConfigLoaded = YES;
          [self applyFixedABTestData];
          BOOL remoteMode = [self isRemoteMode];
          if (remoteMode) {
              [[NSUserDefaults standardUserDefaults] setBool:YES forKey:DYYY_REMOTE_CONFIG_FLAG_KEY];
          }
          // 观察者会同步读取本队列，通知必须在队列退出后从主线程发送。
          dispatch_async(dispatch_get_main_queue(), ^{
            __block BOOL current = NO;
            DYYYQueueSync(^{ current = (generation == s_remoteRequestGeneration); });
            if (!current) return;
            if (remoteMode && [self isRemoteMode]) {
                [[NSNotificationCenter defaultCenter] postNotificationName:DYYY_REMOTE_CONFIG_CHANGED_NOTIFICATION object:nil];
            }
            if (notify) [DYYYUtils showToast:updated ? @"配置已更新" : @"已是最新配置"];
          });
        });
      }];
      [task resume];
    });
}

@end

%hook AWEABTestManager

/** Hook 设置 ABTest 数据：禁止下发模式下拦截，正在应用本地配置时放行。 */
- (void)setAbTestData:(id)data {
    __block BOOL shouldBlock = NO;
    DYYYQueueSync(^{
      // 在队列上安全地检查禁止下发标志 和 正在应用本地数据的标志
      // 如果禁止下发开启 并且 不是正在应用本地数据，则阻止
      if (s_abTestBlockEnabled && !s_isApplyingFixedData) {
          shouldBlock = YES;
      }
    });

    if (shouldBlock) {
        NSLog(@"[DYYY] 阻止ABTest数据更新 (启用了禁止下发配置且非本地应用)");
        return;
    }

    id finalData = data;
    NSNumber *contentHeight = DYYYResolveTabBarHeightFromSettings();
    if (contentHeight) {
        if (!data || [data isKindOfClass:[NSDictionary class]]) {
            finalData = DYYYInjectTabBarHeightConfig(data ?: @{}, contentHeight);
        }
    }

    %orig(finalData);
}

/** Hook 增量更新 ABTest 数据：禁止下发模式下拦截。 */
- (void)incrementalUpdateData:(id)data unchangedKeyList:(id)keyList {
    __block BOOL shouldBlock = NO;
    DYYYQueueSync(^{
      shouldBlock = s_abTestBlockEnabled;
    });

    if (shouldBlock) {
        NSLog(@"[DYYY] 阻止增量更新ABTest数据 (启用了禁止下发配置)");
        return;
    }
    %orig;
}

/** Hook 网络拉取配置（带重试）：禁止下发模式下拦截并立即返回空结果。 */
- (void)fetchConfigurationWithRetry:(BOOL)retry completion:(id)completion {
    __block BOOL shouldBlock = NO;
    DYYYQueueSync(^{
      shouldBlock = s_abTestBlockEnabled;
    });

    if (shouldBlock) {
        NSLog(@"[DYYY] 阻止从网络获取ABTest配置 (启用了禁止下发配置)");
        if (completion && [completion isKindOfClass:%c(NSBlock)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
              ((void (^)(id))completion)(nil);
            });
        }
        return;
    }
    %orig;
}

/** Hook 网络拉取配置：禁止下发模式下拦截。 */
- (void)fetchConfiguration:(id)arg1 {
    __block BOOL shouldBlock = NO;
    DYYYQueueSync(^{
      shouldBlock = s_abTestBlockEnabled;
    });

    if (shouldBlock) {
        NSLog(@"[DYYY] 阻止从网络获取ABTest配置 (启用了禁止下发配置)");
        return;
    }
    %orig;
}

/** Hook 重写 ABTest 数据：禁止下发模式下拦截。 */
- (void)overrideABTestData:(id)data needCleanCache:(BOOL)cleanCache {
    __block BOOL shouldBlock = NO;
    DYYYQueueSync(^{
      shouldBlock = s_abTestBlockEnabled;
    });

    if (shouldBlock) {
        NSLog(@"[DYYY] 阻止重写ABTest数据 (启用了禁止下发配置)");
        return;
    }
    %orig;
}

/** Hook 保存 ABTest 数据：禁止下发模式下拦截。 */
- (void)_saveABTestData:(id)data {
    __block BOOL shouldBlock = NO;
    DYYYQueueSync(^{
      shouldBlock = s_abTestBlockEnabled;
    });

    if (shouldBlock) {
        NSLog(@"[DYYY] 阻止保存ABTest数据 (启用了禁止下发配置)");
        return;
    }
    %orig;
}

%end

%ctor {

    // 预初始化队列以避免早期访问为 NULL
    DYYYABTestQueue();

    %init;

    // 在队列上异步读取初始状态并加载/应用配置
    DYYYQueueAsync(^{
      s_abTestBlockEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYABTestBlockEnabled"];

      NSString *currentMode = nil;
      if ([DYYYABTestHook isRemoteMode]) {
          currentMode = [DYYYABTestHook isPatchMode] ? @"远程模式(覆写)" : @"远程模式(替换)";
      } else {
          currentMode = [DYYYABTestHook isPatchMode] ? @"覆写模式" : @"替换模式";
      }

      NSLog(@"[DYYY] ABTest Hook已启动: 禁止下发=%@, 当前模式=%@", s_abTestBlockEnabled ? @"开启" : @"关闭", currentMode);

      [DYYYABTestHook loadLocalABTestConfig];
      [DYYYABTestHook applyFixedABTestData];
      DYYYApplyTabBarHeightToCurrentABTestDataIfNeeded();
      if ([DYYYABTestHook isRemoteMode]) {
          [DYYYABTestHook checkForRemoteConfigUpdate:NO];
      }

    });
}
