#import <Foundation/Foundation.h>
#include <stdio.h>
#import "DYYYAvatarInteractionPolicy.h"

static int DYYYAvatarInteractionCheck(BOOL passed, NSString *meaning) {
    printf("%s avatar-interaction: %s\n", passed ? "PASS" : "FAIL", meaning.UTF8String);
    return passed ? 0 : 1;
}

// 与运行时共用纯策略；组合覆盖证明每个动作只受自己的设置影响。
int DYYYRunAvatarInteractionPolicyTests(void) {
    @autoreleasepool {
        int failures = 0;
        const DYYYAvatarActionKind kinds[] = {DYYYAvatarActionFollow, DYYYAvatarActionSendMessage,
                                            DYYYAvatarActionEnterStore, DYYYAvatarActionAdLink};
        for (NSUInteger bits = 0; bits < 32; bits++) {
            DYYYAvatarActionSettings settings = {(bits & 1) != 0, (bits & 2) != 0,
                                                 (bits & 4) != 0, (bits & 8) != 0, (bits & 16) != 0};
            const DYYYAvatarActionMode expected[] = {
                (bits & 2) ? DYYYAvatarActionModeDelete : ((bits & 1) ? DYYYAvatarActionModeRemoveVisual : DYYYAvatarActionModeNative),
                (bits & 4) ? DYYYAvatarActionModeDelete : DYYYAvatarActionModeNative,
                (bits & 8) ? DYYYAvatarActionModeDelete : DYYYAvatarActionModeNative,
                (bits & 16) ? DYYYAvatarActionModeDelete : DYYYAvatarActionModeNative,
            };
            DYYYAvatarActionKind expectedKinds = DYYYAvatarActionNone;
            for (NSUInteger i = 0; i < 4; i++) {
                if (expected[i] != DYYYAvatarActionModeNative) expectedKinds |= kinds[i];
                failures += DYYYAvatarInteractionCheck(DYYYAvatarActionModeForSettings(settings, kinds[i]) == expected[i],
                    [NSString stringWithFormat:@"组合%lu动作%lu显隐模式独立", (unsigned long)bits, (unsigned long)kinds[i]]);
                failures += DYYYAvatarInteractionCheck(DYYYAvatarActionBlocksClick(settings, kinds[i]) == (expected[i] == DYYYAvatarActionModeDelete),
                    [NSString stringWithFormat:@"组合%lu动作%lu点击权限独立", (unsigned long)bits, (unsigned long)kinds[i]]);
            }
            failures += DYYYAvatarInteractionCheck(DYYYAvatarActionActiveKinds(settings) == expectedKinds,
                [NSString stringWithFormat:@"组合%lu不借其他入口生成作用域", (unsigned long)bits]);
        }
        DYYYAvatarActionSettings allEnabled = {YES, YES, YES, YES, YES};
        failures += DYYYAvatarInteractionCheck(DYYYAvatarActionModeForSettings(allEnabled, DYYYAvatarActionNone) == DYYYAvatarActionModeNative &&
                                               !DYYYAvatarActionBlocksClick(allEnabled, DYYYAvatarActionNone), @"未知入口不扩展成全头像禁点");
        failures += DYYYAvatarInteractionCheck(DYYYAvatarActionModeForSettings(allEnabled, DYYYAvatarActionFollow | DYYYAvatarActionSendMessage) == DYYYAvatarActionModeNative,
                                               @"复合入口不能误当单一关注按钮");

        NSString *suite = [@"DYYYAvatarInteractionTests-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        if (!defaults) return failures + DYYYAvatarInteractionCheck(NO, @"无法创建隔离测试偏好");
        [defaults removePersistentDomainForName:suite];
        DYYYAvatarActionSettings value = DYYYAvatarActionSettingsFromDefaults(defaults);
        failures += DYYYAvatarInteractionCheck(DYYYAvatarActionActiveKinds(value) == DYYYAvatarActionNone, @"没有配置时原生行为透传");
        for (NSString *key in @[DYYYAvatarFollowRemoveVisualKey, DYYYAvatarFollowDeleteKey,
                               DYYYHideAvatarSendMessageKey, DYYYHideAvatarEnterStoreKey, DYYYHideAvatarAdLinkKey]) {
            failures += DYYYAvatarInteractionCheck([defaults objectForKey:key] == nil, [@"读取不写入默认值：" stringByAppendingString:key]);
        }
        [defaults setBool:YES forKey:DYYYAvatarFollowRemoveVisualKey];
        value = DYYYAvatarActionSettingsFromDefaults(defaults);
        failures += DYYYAvatarInteractionCheck(DYYYAvatarActionModeForSettings(value, DYYYAvatarActionFollow) == DYYYAvatarActionModeRemoveVisual &&
                                               !DYYYAvatarActionBlocksClick(value, DYYYAvatarActionFollow), @"旧隐藏加号键映射移除关注、保留点击，不翻转旧配置");
        failures += DYYYAvatarInteractionCheck(DYYYAvatarActionActiveKinds(value) == DYYYAvatarActionFollow, @"移除关注不隐藏消息、店铺和广告链接");
        [defaults setBool:NO forKey:DYYYAvatarFollowRemoveVisualKey];
        [defaults setBool:YES forKey:DYYYAvatarFollowDeleteKey];
        value = DYYYAvatarActionSettingsFromDefaults(defaults);
        failures += DYYYAvatarInteractionCheck(DYYYAvatarActionModeForSettings(value, DYYYAvatarActionFollow) == DYYYAvatarActionModeDelete &&
                                               DYYYAvatarActionBlocksClick(value, DYYYAvatarActionFollow), @"旧移除加号键映射删除关注、不可点击，不翻转旧配置");
        failures += DYYYAvatarInteractionCheck(DYYYAvatarActionActiveKinds(value) == DYYYAvatarActionFollow, @"删除关注不隐藏消息、店铺和广告链接");
        [defaults setBool:NO forKey:DYYYAvatarFollowDeleteKey];
        [defaults setBool:YES forKey:DYYYHideAvatarSendMessageKey];
        value = DYYYAvatarActionSettingsFromDefaults(defaults);
        failures += DYYYAvatarInteractionCheck(DYYYAvatarActionActiveKinds(value) == DYYYAvatarActionSendMessage &&
                                               !DYYYAvatarActionBlocksClick(value, DYYYAvatarActionFollow), @"仅隐藏消息时关注恢复原生可点击");
        [defaults setBool:NO forKey:DYYYHideAvatarSendMessageKey];
        [defaults setBool:YES forKey:DYYYHideAvatarEnterStoreKey];
        value = DYYYAvatarActionSettingsFromDefaults(defaults);
        failures += DYYYAvatarInteractionCheck(DYYYAvatarActionActiveKinds(value) == DYYYAvatarActionEnterStore, @"单开店铺不改变其他入口");
        [defaults setBool:NO forKey:DYYYHideAvatarEnterStoreKey];
        [defaults setBool:YES forKey:DYYYHideAvatarAdLinkKey];
        value = DYYYAvatarActionSettingsFromDefaults(defaults);
        failures += DYYYAvatarInteractionCheck(DYYYAvatarActionActiveKinds(value) == DYYYAvatarActionAdLink, @"单开广告链接不改变其他入口");
        [defaults removePersistentDomainForName:suite];
        return failures;
    }
}
