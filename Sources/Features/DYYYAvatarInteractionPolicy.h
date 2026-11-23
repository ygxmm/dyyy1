#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 保留旧持久化键的行为，不按中文名称翻转已有配置。
static NSString * const DYYYAvatarFollowRemoveVisualKey = @"DYYYHideLOTAnimationView";   // 原“隐藏头像加号”：仅去视觉，原区域可点
static NSString * const DYYYAvatarFollowDeleteKey = @"DYYYHideFollowPromptView";         // 原“移除头像加号”：去视觉且不可点
static NSString * const DYYYHideAvatarSendMessageKey = @"DYYYHideAvatarSendMessage";
static NSString * const DYYYHideAvatarEnterStoreKey = @"DYYYHideAvatarEnterStore";
static NSString * const DYYYHideAvatarAdLinkKey = @"DYYYHideAvatarAdLink";

typedef NS_OPTIONS(NSUInteger, DYYYAvatarActionKind) {
    DYYYAvatarActionNone = 0,
    DYYYAvatarActionFollow = 1 << 0,
    DYYYAvatarActionSendMessage = 1 << 1,
    DYYYAvatarActionEnterStore = 1 << 2,
    DYYYAvatarActionAdLink = 1 << 3,
};

typedef NS_ENUM(NSUInteger, DYYYAvatarActionMode) {
    DYYYAvatarActionModeNative = 0,
    DYYYAvatarActionModeRemoveVisual = 1,
    DYYYAvatarActionModeDelete = 2,
};

typedef struct {
    BOOL removeFollowVisual;
    BOOL deleteFollow;
    BOOL hideSendMessage;
    BOOL hideEnterStore;
    BOOL hideAdLink;
} DYYYAvatarActionSettings;

// 同时读到两个旧关注键时删除优先，防止形成看不见但仍可点的意外区域。
static inline DYYYAvatarActionMode DYYYAvatarActionModeForSettings(DYYYAvatarActionSettings settings, DYYYAvatarActionKind kind) {
    switch (kind) {
        case DYYYAvatarActionFollow:
            return settings.deleteFollow ? DYYYAvatarActionModeDelete :
                   (settings.removeFollowVisual ? DYYYAvatarActionModeRemoveVisual : DYYYAvatarActionModeNative);
        case DYYYAvatarActionSendMessage:
            return settings.hideSendMessage ? DYYYAvatarActionModeDelete : DYYYAvatarActionModeNative;
        case DYYYAvatarActionEnterStore:
            return settings.hideEnterStore ? DYYYAvatarActionModeDelete : DYYYAvatarActionModeNative;
        case DYYYAvatarActionAdLink:
            return settings.hideAdLink ? DYYYAvatarActionModeDelete : DYYYAvatarActionModeNative;
        default:
            return DYYYAvatarActionModeNative;
    }
}

static inline DYYYAvatarActionKind DYYYAvatarActionActiveKinds(DYYYAvatarActionSettings settings) {
    DYYYAvatarActionKind kinds = DYYYAvatarActionNone;
    if (settings.removeFollowVisual || settings.deleteFollow) kinds |= DYYYAvatarActionFollow;
    if (settings.hideSendMessage) kinds |= DYYYAvatarActionSendMessage;
    if (settings.hideEnterStore) kinds |= DYYYAvatarActionEnterStore;
    if (settings.hideAdLink) kinds |= DYYYAvatarActionAdLink;
    return kinds;
}

static inline BOOL DYYYAvatarActionBlocksClick(DYYYAvatarActionSettings settings, DYYYAvatarActionKind kind) {
    return DYYYAvatarActionModeForSettings(settings, kind) == DYYYAvatarActionModeDelete;
}

static inline DYYYAvatarActionSettings DYYYAvatarActionSettingsFromDefaults(NSUserDefaults *defaults) {
    return (DYYYAvatarActionSettings){
        [defaults boolForKey:DYYYAvatarFollowRemoveVisualKey],
        [defaults boolForKey:DYYYAvatarFollowDeleteKey],
        [defaults boolForKey:DYYYHideAvatarSendMessageKey],
        [defaults boolForKey:DYYYHideAvatarEnterStoreKey],
        [defaults boolForKey:DYYYHideAvatarAdLinkKey],
    };
}

NS_ASSUME_NONNULL_END
