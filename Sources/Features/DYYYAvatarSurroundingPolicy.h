#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 头像周边拆分后的持久化键；旧键仅作为未迁移配置的兼容回退。
static NSString * const DYYYHideAvatarStoryRingKey = @"DYYYHideAvatarStoryRing";
static NSString * const DYYYHideAvatarDecorationKey = @"DYYYHideAvatarDecoration";
static NSString * const DYYYHideAvatarSurroundingKey = @"DYYYHideAvatarSurrounding";

// 新键只要在偏好中存在就具有优先级，包括显式保存的 false；不写入任何默认值。
static inline BOOL DYYYAvatarSurroundingSettingEnabled(NSUserDefaults *defaults, NSString *key) {
    if (!defaults || key.length == 0) {
        return NO;
    }

    id value = [defaults objectForKey:key];
    if (value != nil) {
        return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
    }
    return [defaults boolForKey:DYYYHideAvatarSurroundingKey];
}

NS_ASSUME_NONNULL_END
