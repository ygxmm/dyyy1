#import <Foundation/Foundation.h>
#include <stdio.h>
#import "DYYYAvatarSurroundingPolicy.h"
#import "DYYYSettingsBackupValidation.h"

static int DYYYAvatarPolicyCheck(BOOL passed, const char *meaning) {
    printf("%s avatar-policy: %s\n", passed ? "PASS" : "FAIL", meaning);
    return passed ? 0 : 1;
}

// Foundation-only 回归：覆盖拆分键回退优先级，以及旧备份的最小迁移语义。
int DYYYRunAvatarSurroundingPolicyTests(void) {
    @autoreleasepool {
        int failures = 0;
        NSString *suiteName = [@"DYYYAvatarPolicyTests-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        if (!defaults) return DYYYAvatarPolicyCheck(NO, "无法创建隔离偏好 suite");

        [defaults removePersistentDomainForName:suiteName];
        failures += DYYYAvatarPolicyCheck(!DYYYAvatarSurroundingSettingEnabled(defaults, DYYYHideAvatarStoryRingKey) &&
                                              !DYYYAvatarSurroundingSettingEnabled(defaults, DYYYHideAvatarDecorationKey),
                                          "新键缺省且无旧键时两项均关闭");
        failures += DYYYAvatarPolicyCheck([defaults objectForKey:DYYYHideAvatarStoryRingKey] == nil &&
                                              [defaults objectForKey:DYYYHideAvatarDecorationKey] == nil &&
                                              [defaults objectForKey:DYYYHideAvatarSurroundingKey] == nil,
                                          "读取策略不写入默认值");

        [defaults setBool:YES forKey:DYYYHideAvatarSurroundingKey];
        failures += DYYYAvatarPolicyCheck(DYYYAvatarSurroundingSettingEnabled(defaults, DYYYHideAvatarStoryRingKey) &&
                                              DYYYAvatarSurroundingSettingEnabled(defaults, DYYYHideAvatarDecorationKey),
                                          "旧键 true 回退同时启用两项");
        [defaults setBool:NO forKey:DYYYHideAvatarSurroundingKey];
        failures += DYYYAvatarPolicyCheck(!DYYYAvatarSurroundingSettingEnabled(defaults, DYYYHideAvatarStoryRingKey) &&
                                              !DYYYAvatarSurroundingSettingEnabled(defaults, DYYYHideAvatarDecorationKey),
                                          "旧键 false 回退同时关闭两项");

        [defaults setBool:YES forKey:DYYYHideAvatarSurroundingKey];
        [defaults setBool:NO forKey:DYYYHideAvatarStoryRingKey];
        failures += DYYYAvatarPolicyCheck(!DYYYAvatarSurroundingSettingEnabled(defaults, DYYYHideAvatarStoryRingKey) &&
                                              DYYYAvatarSurroundingSettingEnabled(defaults, DYYYHideAvatarDecorationKey),
                                          "日常彩环显式 false 覆盖旧 true 且挂件仍独立");
        [defaults setBool:NO forKey:DYYYHideAvatarDecorationKey];
        failures += DYYYAvatarPolicyCheck(!DYYYAvatarSurroundingSettingEnabled(defaults, DYYYHideAvatarStoryRingKey) &&
                                              !DYYYAvatarSurroundingSettingEnabled(defaults, DYYYHideAvatarDecorationKey),
                                          "挂件显式 false 与日常彩环互不串联");
        [defaults setBool:YES forKey:DYYYHideAvatarStoryRingKey];
        failures += DYYYAvatarPolicyCheck(DYYYAvatarSurroundingSettingEnabled(defaults, DYYYHideAvatarStoryRingKey) &&
                                              !DYYYAvatarSurroundingSettingEnabled(defaults, DYYYHideAvatarDecorationKey),
                                          "日常彩环显式 true 也不重新启用挂件");

        NSError *error = nil;
        NSSet *removed = nil;
        NSDictionary *oldBackup = @{DYYYHideAvatarSurroundingKey: @YES};
        NSDictionary *mapped = DYYYNormalizeLegacySettingsBackup(oldBackup, @{}, &removed, &error);
        failures += DYYYAvatarPolicyCheck(mapped && !error && [mapped[DYYYHideAvatarStoryRingKey] boolValue] &&
                                              [mapped[DYYYHideAvatarDecorationKey] boolValue] &&
                                              !mapped[DYYYHideAvatarSurroundingKey] && [removed containsObject:DYYYHideAvatarSurroundingKey],
                                          "旧备份 true 精确映射两项并清理旧键");

        error = nil;
        removed = nil;
        NSDictionary *explicitPayload = @{DYYYHideAvatarSurroundingKey: @YES, DYYYHideAvatarStoryRingKey: @NO};
        mapped = DYYYNormalizeLegacySettingsBackup(explicitPayload, @{}, &removed, &error);
        failures += DYYYAvatarPolicyCheck(mapped && !error && [mapped[DYYYHideAvatarStoryRingKey] isEqual:@NO] &&
                                              [mapped[DYYYHideAvatarDecorationKey] isEqual:@YES],
                                          "旧键与新键同时存在时显式新值优先");

        error = nil;
        removed = nil;
        NSDictionary *localSplit = @{DYYYHideAvatarStoryRingKey: @NO};
        mapped = DYYYNormalizeLegacySettingsBackup(oldBackup, localSplit, &removed, &error);
        failures += DYYYAvatarPolicyCheck(mapped && !error && !mapped[DYYYHideAvatarStoryRingKey] &&
                                              [mapped[DYYYHideAvatarDecorationKey] isEqual:@YES],
                                          "旧备份不会覆盖本机已有显式新值");

        error = nil;
        removed = nil;
        NSDictionary *singleNewPayload = @{DYYYHideAvatarStoryRingKey: @NO};
        mapped = DYYYNormalizeLegacySettingsBackup(singleNewPayload,
                                                    @{DYYYHideAvatarSurroundingKey: @YES}, &removed, &error);
        failures += DYYYAvatarPolicyCheck(mapped && !error && [mapped[DYYYHideAvatarStoryRingKey] isEqual:@NO] &&
                                              !mapped[DYYYHideAvatarDecorationKey] && removed.count == 0,
                                          "仅导入单个新键时不借设备旧 true 推导另一项且保留旧回退");

        // 实际提交回归：单新键显式 false 覆盖本项，但未导入的另一项仍由本机旧 true 回退。
        [defaults removePersistentDomainForName:suiteName];
        [defaults setBool:YES forKey:DYYYHideAvatarSurroundingKey];
        [defaults synchronize];
        NSError *commitError = nil;
        BOOL committed = DYYYCommitSettingsBackup(singleNewPayload, @{}, [NSSet set], defaults, suiteName,
                                                   [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES], &commitError);
        failures += DYYYAvatarPolicyCheck(committed && !commitError &&
                                              !DYYYAvatarSurroundingSettingEnabled(defaults, DYYYHideAvatarStoryRingKey) &&
                                              DYYYAvatarSurroundingSettingEnabled(defaults, DYYYHideAvatarDecorationKey) &&
                                              [defaults boolForKey:DYYYHideAvatarSurroundingKey],
                                          "实际提交保留旧回退并只覆盖导入的新项");

        [defaults removePersistentDomainForName:suiteName];
        return failures;
    }
}
