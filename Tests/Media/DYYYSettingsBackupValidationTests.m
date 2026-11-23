#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>
#import <unistd.h>
#import <sys/stat.h>
#include <stdio.h>
#import "DYYYSettingsBackupValidation.h"
#import "DYYYConstants.h"
#import "DYYYAvatarInteractionPolicy.h"
#import "DYYYAvatarSurroundingPolicy.h"

static int DYYYBackupCheck(BOOL passed, const char *meaning) {
    printf("%s backup: %s\n", passed ? "PASS" : "FAIL", meaning);
    return passed ? 0 : 1;
}

static NSData *DYYYBackupJSON(id object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
}

static BOOL DYYYBackupReject(id object) {
    NSError *error = nil;
    DYYYValidatedSettingsBackup *result = DYYYValidateSettingsBackupData(DYYYBackupJSON(object), &error);
    return result == nil && error != nil;
}

// 头像入口只扩充布尔白名单；旧关注键仍原样保存，不迁移到新隐藏键。
static int DYYYRunAvatarActionBackupValueTests(void) {
    int failures = 0;
    NSError *error = nil;
    NSSet *removed = nil;
    NSArray<NSString *> *newKeys = @[DYYYHideAvatarSendMessageKey, DYYYHideAvatarEnterStoreKey, DYYYHideAvatarAdLinkKey];
    NSDictionary *local = @{DYYYAvatarFollowDeleteKey: @YES, DYYYAvatarFollowRemoveVisualKey: @YES,
        DYYYHideAvatarSendMessageKey: @YES, DYYYHideAvatarEnterStoreKey: @YES, DYYYHideAvatarAdLinkKey: @YES};
    for (NSString *key in newKeys) {
        for (NSNumber *value in @[@YES, @NO]) {
            NSDictionary *payload = @{key: value};
            NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
            DYYYValidatedSettingsBackup *valid = DYYYValidateSettingsBackupData(json, &error);
            failures += DYYYBackupCheck(valid && !error && [valid.settings isEqual:payload], "三个独立头像入口均可导出并导入显式 true/false");
            NSDictionary *normalized = DYYYNormalizeLegacySettingsBackup(valid.settings, local, &removed, &error);
            failures += DYYYBackupCheck(normalized && !error && [normalized isEqual:payload] && removed.count == 0,
                "新入口显式 false 不被本机 true 覆盖，单键导入不生成其他头像键");
        }
        for (id invalid in @[@2, @(-1), @1.5, @"true", @"false", @"1", @[], @{}, NSNull.null]) {
            failures += DYYYBackupCheck(DYYYBackupReject(@{key: invalid}), "独立头像入口拒绝非布尔备份值，不能部分接收");
        }
    }
    for (NSUInteger flags = 0; flags < 4; flags++) {
        NSDictionary *payload = @{DYYYAvatarFollowRemoveVisualKey: ((flags & 1) ? @YES : @NO), DYYYAvatarFollowDeleteKey: ((flags & 2) ? @YES : @NO)};
        DYYYValidatedSettingsBackup *valid = DYYYValidateSettingsBackupData(DYYYBackupJSON(payload), &error);
        NSDictionary *normalized = DYYYNormalizeLegacySettingsBackup(valid.settings, local, &removed, &error);
        failures += DYYYBackupCheck(valid && !error && [valid.settings isEqual:payload] && [normalized isEqual:payload] && removed.count == 0,
            "两个旧关注键的四种 true/false 组合原值原键保留，不翻转、不删除、不派生新隐藏键");
    }
    for (NSString *key in @[DYYYAvatarFollowDeleteKey, DYYYAvatarFollowRemoveVisualKey]) {
        for (NSNumber *value in @[@YES, @NO]) {
            NSDictionary *payload = @{key: value};
            NSDictionary *normalized = DYYYNormalizeLegacySettingsBackup(payload, local, &removed, &error);
            failures += DYYYBackupCheck(normalized && !error && [normalized isEqual:payload] && removed.count == 0,
                "旧关注单键导入不写另一模式，也不迁移成消息、店铺、广告、彩环或挂件键");
        }
    }
    NSDictionary *legacyTypes = @{DYYYAvatarFollowRemoveVisualKey: @"true", DYYYAvatarFollowDeleteKey: @0};
    DYYYValidatedSettingsBackup *legacyValid = DYYYValidateSettingsBackupData(DYYYBackupJSON(legacyTypes), &error);
    NSDictionary *legacyNormalized = DYYYNormalizeLegacySettingsBackup(legacyValid.settings, local, &removed, &error);
    failures += DYYYBackupCheck(legacyValid && !error && [legacyNormalized isEqual:legacyTypes] && removed.count == 0,
        "旧关注键原有字符串和数字值兼容，不被新布尔白名单收紧");
    NSDictionary *empty = DYYYNormalizeLegacySettingsBackup(@{}, local, &removed, &error);
    failures += DYYYBackupCheck(empty && !error && empty.count == 0 && removed.count == 0, "空备份不从本机关注或新入口键制造默认值");
    NSDictionary *surrounding = DYYYNormalizeLegacySettingsBackup(@{DYYYHideAvatarSurroundingKey: @YES}, @{}, &removed, &error);
    failures += DYYYBackupCheck(surrounding && !error && !surrounding[DYYYAvatarFollowDeleteKey] && !surrounding[DYYYAvatarFollowRemoveVisualKey] &&
        !surrounding[DYYYHideAvatarSendMessageKey] && !surrounding[DYYYHideAvatarEnterStoreKey] && !surrounding[DYYYHideAvatarAdLinkKey],
        "原彩环挂件迁移不扩散到关注或三个独立头像入口");
    return failures;
}

// 动态生成有效 PNG，避免测试依赖 UIKit 或外部图片资源。
static NSData *DYYYBackupTestPNG(size_t width, size_t height) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return nil;
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.png"), 1, NULL);
    if (!destination || !image) { if (destination) CFRelease(destination); if (image) CGImageRelease(image); return nil; }
    CGImageDestinationAddImage(destination, image, NULL);
    BOOL written = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    CGImageRelease(image);
    return written ? data : nil;
}

// 由主测试 runner 调用，不定义 main，不写入真实偏好或用户图片。
int DYYYRunSettingsBackupValidationTests(void) {
    @autoreleasepool {
        int failures = DYYYRunAvatarActionBackupValueTests();
        NSError *error = nil;
        NSData *png = DYYYBackupTestPNG(1, 1);
        if (!png) return DYYYBackupCheck(NO, "测试 PNG 生成失败");
        NSString *base64 = [png base64EncodedStringWithOptions:0];
        NSMutableDictionary *icons = [NSMutableDictionary dictionary];
        for (NSString *name in DYYYSettingsBackupIconFileNames()) icons[name] = base64;
        // 旧格式为平铺配置，保留布尔、数字、字符串、数组、字典和旧连播键。
        NSDictionary *legacy = @{@"DYYYEnableAutoPlay": @YES, @"DYYYisEnableAutoPlay": @"true", @"DYYYSpeed": @1.25,
            @"DYYYKeywords": @[@"中文", @"测试"], @"DYYYOptions": @{@"enabled": @NO, @"empty": @[]}, @"DYYYIconsBase64": icons};
        DYYYValidatedSettingsBackup *valid = DYYYValidateSettingsBackupData(DYYYBackupJSON(legacy), &error);
        failures += DYYYBackupCheck(valid && !error && valid.icons.count == 8 && [valid.icons[@"qingping.gif"] isEqual:png], "旧备份八个固定文件名及 PNG 原始数据");
        failures += DYYYBackupCheck([valid.settings[@"DYYYisEnableAutoPlay"] isEqual:@"true"] && !valid.settings[@"DYYYIconsBase64"], "保留旧连播键供现有 Normalize 使用，图标从配置分离");
        failures += DYYYBackupCheck(DYYYValidateSettingsBackupData(DYYYBackupJSON(@{}), nil) != nil, "兼容空旧备份");
        failures += DYYYBackupCheck(DYYYBackupReject(@{@"DYYYValid": @YES, @"hostPreference": @NO}), "拒绝混入宿主配置，不能部分接收");
        failures += DYYYBackupCheck(DYYYBackupReject(@{@"DYYY": @YES}) && DYYYBackupReject(@{@"xDYYYFlag": @YES}), "严格校验顶层 DYYY 命名空间");
        failures += DYYYBackupCheck(DYYYBackupReject(@{@"DYYYNull": NSNull.null}), "拒绝配置 null");
        failures += DYYYBackupCheck(DYYYBackupReject(@{@"DYYYArray": @[@1, NSNull.null]}) && DYYYBackupReject(@{@"DYYYMap": @{@"child": NSNull.null}}), "递归拒绝容器内 null");
        failures += DYYYBackupCheck(DYYYBackupReject(@[]) && DYYYBackupReject(@[@{}]), "根容器只能是字典");
        for (id bad in @[@[], @"text", NSNull.null]) failures += DYYYBackupCheck(DYYYBackupReject(@{@"DYYYIconsBase64": bad}), "图标集合类型错误必须整体拒绝");
        for (NSString *name in @[@"../share.png", @"/tmp/share.png", @"nested/share.png", @"..\\share.png", @"other.png", @"SHARE.png"]) {
            failures += DYYYBackupCheck(DYYYBackupReject(@{@"DYYYIconsBase64": @{name: base64}}), "拒绝穿越、绝对路径、子目录和白名单外名称");
        }
        for (id bad in @[@"not-base64!", @"", @"YWJj", @42, NSNull.null, [base64 stringByAppendingString:@"\n"]]) {
            failures += DYYYBackupCheck(DYYYBackupReject(@{@"DYYYIconsBase64": @{@"share.png": bad}}), "拒绝畸形 Base64、非图片和错误值类型");
        }
        NSData *truncated = [png subdataWithRange:NSMakeRange(0, png.length / 2)];
        failures += DYYYBackupCheck(DYYYBackupReject(@{@"DYYYIconsBase64": @{@"share.png": [truncated base64EncodedStringWithOptions:0]}}), "拒绝截断图片");
        NSData *wide = DYYYBackupTestPNG(4097, 1);
        failures += DYYYBackupCheck(wide && DYYYBackupReject(@{@"DYYYIconsBase64": @{@"share.png": [wide base64EncodedStringWithOptions:0]}}), "拒绝超大图片尺寸");
        NSString *gif = @"R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7";
        failures += DYYYBackupCheck(DYYYValidateSettingsBackupData(DYYYBackupJSON(@{@"DYYYIconsBase64": @{@"like_before.png": gif}}), nil) != nil, "旧选择器允许 GIF 存在 PNG 文件名下");
        id deep = @1;
        for (NSUInteger i = 0; i < 34; i++) deep = @[deep];
        failures += DYYYBackupCheck(DYYYBackupReject(@{@"DYYYDeep": deep}), "拒绝过深容器");
        NSMutableArray *many = [NSMutableArray array];
        for (NSUInteger i = 0; i < 20001; i++) [many addObject:@0];
        failures += DYYYBackupCheck(DYYYBackupReject(@{@"DYYYMany": many}), "拒绝过多节点");
        NSString *longText = [@"x" stringByPaddingToLength:1024 * 1024 + 1 withString:@"x" startingAtIndex:0];
        failures += DYYYBackupCheck(DYYYBackupReject(@{@"DYYYText": longText}), "拒绝超长普通配置字符串");
        @autoreleasepool {
            NSData *oversized = [NSMutableData dataWithLength:DYYYSettingsBackupMaximumBytes + 1];
            failures += DYYYBackupCheck(DYYYValidateSettingsBackupData(oversized, &error) == nil && error != nil, "解析前拒绝超过文件字节上限的输入");
            NSString *encoded = [@"A" stringByPaddingToLength:4 * ((DYYYSettingsBackupMaximumIconBytes + 2) / 3) + 4 withString:@"A" startingAtIndex:0];
            failures += DYYYBackupCheck(DYYYBackupReject(@{@"DYYYIconsBase64": @{@"share.png": encoded}}), "解码前拒绝超大图标编码");
        }
        for (NSString *key in @[@"DYYYEnableAutoPlay", @"DYYYisEnableAutoPlay", @"DYYYHDRModeMigratedV1", @"DYYYScaleAndSizeSettingsMigratedV1", @"DYYYHDRMode", @"DYYYNicknameScale"]) {
            failures += DYYYBackupCheck(DYYYBackupReject(@{key: @[]}) && DYYYBackupReject(@{key: @{}}), "关键标量配置不得接受容器类型");
        }
        failures += DYYYBackupCheck(DYYYValidateSettingsBackupData(DYYYBackupJSON(@{DYYY_DISABLE_FEED_NOW_PLAYING_INFO_KEY:@YES}), &error) != nil && !error,
            "新版播放卡片屏蔽布尔键可从备份导入");
        for (id invalidNowPlayingValue in @[@2, @(-1), @1.5, @"true", @[], @{}]) {
            failures += DYYYBackupCheck(DYYYBackupReject(@{DYYY_DISABLE_FEED_NOW_PLAYING_INFO_KEY: invalidNowPlayingValue}),
                "播放卡片开关拒绝非布尔备份值");
        }
        for (NSString *number in @[@"NaN", @"Infinity", @"-Infinity", @"1e9999"]) {
            NSData *badNumber = [[NSString stringWithFormat:@"{\"DYYYNumber\":%@}", number] dataUsingEncoding:NSUTF8StringEncoding];
            failures += DYYYBackupCheck(DYYYValidateSettingsBackupData(badNumber, &error) == nil && error != nil, "拒绝非有限和溢出数字");
        }
        failures += DYYYBackupCheck(DYYYValidateSettingsBackupData([NSData data], &error) == nil && error != nil, "拒绝空文件");
        failures += DYYYBackupCheck(DYYYValidateSettingsBackupData([@"{broken" dataUsingEncoding:NSUTF8StringEncoding], &error) == nil && error != nil, "拒绝破损 JSON");
        failures += DYYYBackupCheck(DYYYReadSettingsBackupData([NSURL URLWithString:@"https://invalid.example/backup"], &error) == nil && error != nil, "读取器不接受远程 URL");
        // 两个跨键回归：本机另一偏移不参与反转，本机 HDRMode 不覆盖旧备份意图。
        NSDictionary *local = @{@"DYYYNicknameVerticalOffset": @"9", @"DYYYDescriptionVerticalOffset": @"13", @"DYYYHDRMode": @"全局过滤HDR作品", @"DYYYDescriptionScale": @"2", @"DYYYIPLabelScale": @"3"};
        NSDictionary *old = @{@"DYYYNicknameVerticalOffset": @"5", @"DYYYFilterFeedHDR": @NO};
        NSSet *removed = nil;
        NSDictionary *converted = DYYYNormalizeLegacySettingsBackup(old, local, &removed, &error);
        failures += DYYYBackupCheck(converted && !error && [converted[@"DYYYNicknameVerticalOffset"] isEqual:@"-5"] && !converted[@"DYYYDescriptionVerticalOffset"], "仅转换本次导入偏移，不反转本机未导入的另一偏移");
        failures += DYYYBackupCheck([converted[@"DYYYHDRMode"] isEqual:@"关闭（交给抖音）"] && [removed containsObject:@"DYYYFilterFeedHDR"] && !converted[@"DYYYFilterFeedHDR"], "旧 HDR 关闭不被本机已保存过滤模式吞掉，旧键进入删除集合");
        failures += DYYYBackupCheck([converted[@"DYYYHDRModeMigratedV1"] boolValue] && [converted[@"DYYYHDRModeLabelV2"] boolValue] && [converted[@"DYYYScaleAndSizeSettingsMigratedV1"] boolValue] && [old[@"DYYYNicknameVerticalOffset"] isEqual:@"5"], "转换输出带完成标记且不修改输入");
        NSDictionary *completed = @{@"DYYYNicknameVerticalOffset": @"5", @"DYYYScaleAndSizeSettingsMigratedV1": @YES, @"DYYYScaleAndSizeSettingsMigratedV2": @YES, @"DYYYHDRMode": @"全局过滤HDR作品", @"DYYYHDRModeMigratedV1": @YES, @"DYYYHDRModeLabelV2": @YES};
        failures += DYYYBackupCheck([DYYYNormalizeLegacySettingsBackup(completed, local, &removed, &error) isEqual:completed] && removed.count == 0, "备份已有完成标记时保留值与标记，不重复迁移");
        NSDictionary *scaleWithLocal = DYYYNormalizeLegacySettingsBackup(@{@"DYYYNicknameScale": @1.25}, local, nil, &error);
        NSDictionary *scaleWithoutLocal = DYYYNormalizeLegacySettingsBackup(@{@"DYYYNicknameScale": @1.25}, @{}, nil, &error);
        failures += DYYYBackupCheck(!scaleWithLocal[@"DYYYDescriptionScale"] && !scaleWithLocal[@"DYYYIPLabelScale"] && [scaleWithoutLocal[@"DYYYDescriptionScale"] isEqual:@"1.25"] && [scaleWithoutLocal[@"DYYYIPLabelScale"] isEqual:@"1.25"], "旧昵称比例仅补缺，不覆盖未导入的现有说明与IP比例");
        NSDictionary *orphanMarkers = DYYYNormalizeLegacySettingsBackup(@{@"DYYYScaleAndSizeSettingsMigratedV1": @NO, @"DYYYHDRModeMigratedV1": @NO}, local, nil, &error);
        failures += DYYYBackupCheck(orphanMarkers.count == 0, "没有对应旧键的未完成标记不重置本机迁移状态");
        NSString *largeLiteral = [@"1" stringByPaddingToLength:1024 withString:@"0" startingAtIndex:0];
        NSData *largeNumber = [[NSString stringWithFormat:@"{\"DYYYNumber\":%@}", largeLiteral] dataUsingEncoding:NSUTF8StringEncoding];
        failures += DYYYBackupCheck(DYYYValidateSettingsBackupData(largeNumber, &error) == nil && error != nil, "Foundation 解析前拒绝巨型数字字面量");
        return failures;
    }
}

// 隔离 suite 的同步失败注入，不访问宿主标准偏好。
@interface DYYYBackupFailingDefaults : NSUserDefaults
@property(nonatomic) BOOL failNextSynchronize;
@property(nonatomic) BOOL throwNextSynchronize;
@property(nonatomic, copy) void (^beforeFailure)(void);
@end
@implementation DYYYBackupFailingDefaults
- (BOOL)synchronize {
    if (self.throwNextSynchronize) {
        self.throwNextSynchronize = NO;
        @throw [NSException exceptionWithName:@"DYYYBackupTestFailure" reason:@"同步异常注入" userInfo:nil];
    }
    if (self.failNextSynchronize) {
        self.failNextSynchronize = NO;
        if (self.beforeFailure) self.beforeFailure();
        return NO;
    }
    return [super synchronize];
}
@end

// 独立入口：主 runner 必须显式调用，所有写入限制在临时目录和随机 suite。
int DYYYRunSettingsBackupTransactionTests(void) {
    @autoreleasepool {
        int failures = 0;
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *identifier = [@"DYYYBackupTests-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:identifier];
        NSString *outside = [root stringByAppendingPathComponent:@"outside"];
        NSString *folder = [root stringByAppendingPathComponent:@"DYYY"];
        NSString *target = [folder stringByAppendingPathComponent:@"share.png"];
        NSString *unrelated = [folder stringByAppendingPathComponent:@"user-note.txt"];
        DYYYBackupFailingDefaults *defaults = [[DYYYBackupFailingDefaults alloc] initWithSuiteName:identifier];
        NSError *error = nil;
        NSData *png = DYYYBackupTestPNG(1, 1), *oldPNG = DYYYBackupTestPNG(2, 1);
        if (!png || !oldPNG || ![fm createDirectoryAtPath:outside withIntermediateDirectories:YES attributes:nil error:&error])
            return DYYYBackupCheck(NO, "事务测试资源初始化");
        @try {
            [defaults setObject:@"host-original" forKey:@"hostPreference"];
            [defaults setObject:@"old" forKey:@"DYYYTest"];
            [defaults setBool:YES forKey:@"DYYYHDRModeMigratedV1"];
            [defaults synchronize];
            NSDictionary *icons = @{@"share.png": png};
            NSURL *documents = [NSURL fileURLWithPath:root isDirectory:YES];
            // 真实偏好提交与导出回归仅使用本测试的随机 suite，不触碰标准偏好或用户文件。
            NSArray<NSString *> *avatarKeys = @[DYYYHideAvatarSendMessageKey, DYYYHideAvatarEnterStoreKey, DYYYHideAvatarAdLinkKey];
            DYYYAvatarActionSettings initialAvatar = DYYYAvatarActionSettingsFromDefaults(defaults);
            failures += DYYYBackupCheck(!initialAvatar.hideSendMessage && !initialAvatar.hideEnterStore && !initialAvatar.hideAdLink &&
                ![defaults objectForKey:DYYYHideAvatarSendMessageKey] && ![defaults objectForKey:DYYYHideAvatarEnterStoreKey] && ![defaults objectForKey:DYYYHideAvatarAdLinkKey],
                "三个新入口缺省关闭，读取不写默认值");
            NSDictionary *unchangedAvatar = @{@"DYYYHideAvatarButton": @YES, DYYYHideAvatarStoryRingKey: @NO,
                DYYYHideAvatarDecorationKey: @YES, @"DYYYHideAvatarLive": @NO};
            for (NSString *key in unchangedAvatar) [defaults setObject:unchangedAvatar[key] forKey:key];
            for (NSUInteger flags = 0; flags < 4; flags++) {
                NSDictionary *oldFollow = @{DYYYAvatarFollowRemoveVisualKey: ((flags & 1) ? @YES : @NO), DYYYAvatarFollowDeleteKey: ((flags & 2) ? @YES : @NO)};
                DYYYValidatedSettingsBackup *followBackup = DYYYValidateSettingsBackupData(DYYYBackupJSON(oldFollow), &error);
                BOOL committed = DYYYCommitSettingsBackup(followBackup.settings, @{}, [NSSet set], defaults, identifier, documents, &error);
                DYYYAvatarActionMode expected = (flags & 2) ? DYYYAvatarActionModeDelete : ((flags & 1) ? DYYYAvatarActionModeRemoveVisual : DYYYAvatarActionModeNative);
                failures += DYYYBackupCheck(committed && !error &&
                    [[defaults objectForKey:DYYYAvatarFollowRemoveVisualKey] isEqual:oldFollow[DYYYAvatarFollowRemoveVisualKey]] &&
                    [[defaults objectForKey:DYYYAvatarFollowDeleteKey] isEqual:oldFollow[DYYYAvatarFollowDeleteKey]] &&
                    DYYYAvatarActionModeForSettings(DYYYAvatarActionSettingsFromDefaults(defaults), DYYYAvatarActionFollow) == expected,
                    "旧关注备份实际提交保留值；删除不可点击，移除仍可点，两键同时真时删除优先");
                failures += DYYYBackupCheck(![defaults objectForKey:DYYYHideAvatarSendMessageKey] &&
                    ![defaults objectForKey:DYYYHideAvatarEnterStoreKey] && ![defaults objectForKey:DYYYHideAvatarAdLinkKey],
                    "旧关注实际恢复不创建三个新入口默认值");
            }
            NSDictionary *allAvatarTrue = @{DYYYHideAvatarSendMessageKey: @YES, DYYYHideAvatarEnterStoreKey: @YES, DYYYHideAvatarAdLinkKey: @YES};
            for (NSNumber *value in @[@YES, @NO]) {
                NSDictionary *payload = @{DYYYHideAvatarSendMessageKey: value, DYYYHideAvatarEnterStoreKey: value, DYYYHideAvatarAdLinkKey: value};
                DYYYValidatedSettingsBackup *avatarBackup = DYYYValidateSettingsBackupData(DYYYBackupJSON(payload), &error);
                BOOL committed = DYYYCommitSettingsBackup(avatarBackup.settings, @{}, [NSSet set], defaults, identifier, documents, &error);
                NSMutableDictionary *settingsExport = [NSMutableDictionary dictionary];
                NSDictionary *persisted = [defaults persistentDomainForName:identifier];
                // 沿用界面导出的 DYYY 前缀集合及 JSON 结构，但数据来源限定隔离域。
                for (NSString *key in persisted) if ([key hasPrefix:@"DYYY"] && ![key isEqualToString:@"DYYYIconsBase64"]) settingsExport[key] = persisted[key];
                DYYYValidatedSettingsBackup *roundTrip = DYYYValidateSettingsBackupData(DYYYBackupJSON(settingsExport), &error);
                BOOL preserved = committed && roundTrip && !error && !roundTrip.settings[@"hostPreference"] &&
                    [roundTrip.settings[DYYYAvatarFollowDeleteKey] isEqual:@YES] && [roundTrip.settings[DYYYAvatarFollowRemoveVisualKey] isEqual:@YES];
                for (NSString *key in avatarKeys) preserved = preserved && [[defaults objectForKey:key] isEqual:value] && [roundTrip.settings[key] isEqual:value];
                failures += DYYYBackupCheck(preserved, "三个新入口 true/false 实际提交后均能导出再导入，旧关注值与宿主偏好不变");
            }
            for (NSString *key in avatarKeys) {
                BOOL primed = DYYYCommitSettingsBackup(allAvatarTrue, @{}, [NSSet set], defaults, identifier, documents, &error);
                DYYYValidatedSettingsBackup *single = DYYYValidateSettingsBackupData(DYYYBackupJSON(@{key: @NO}), &error);
                BOOL committed = DYYYCommitSettingsBackup(single.settings, @{}, [NSSet set], defaults, identifier, documents, &error);
                BOOL independent = primed && committed && !error;
                for (NSString *other in avatarKeys) independent = independent && [[defaults objectForKey:other] isEqual:([other isEqualToString:key] ? @NO : @YES)];
                failures += DYYYBackupCheck(independent && [defaults boolForKey:DYYYAvatarFollowDeleteKey] && [defaults boolForKey:DYYYAvatarFollowRemoveVisualKey],
                    "仅导入某入口 false，不改另两个入口或旧关注键");
                NSDictionary *before = [[defaults persistentDomainForName:identifier] copy];
                failures += DYYYBackupCheck(!DYYYCommitSettingsBackup(@{key: @"true", @"DYYYTest": @"must-not-write"}, @{}, [NSSet set], defaults, identifier, documents, &error) &&
                    error != nil && [[defaults persistentDomainForName:identifier] isEqual:before], "新入口无效值在事务二次校验中整体拒绝，不部分写入");
                defaults.failNextSynchronize = YES;
                failures += DYYYBackupCheck(!DYYYCommitSettingsBackup(@{key: @YES}, @{}, [NSSet set], defaults, identifier, documents, &error) &&
                    error != nil && [[defaults persistentDomainForName:identifier] isEqual:before], "新入口恢复同步失败精确回滚，显式 false 及其他配置不丢失");
            }
            BOOL avatarUnchanged = YES;
            for (NSString *key in unchangedAvatar) avatarUnchanged = avatarUnchanged && [[defaults objectForKey:key] isEqual:unchangedAvatar[key]];
            failures += DYYYBackupCheck(avatarUnchanged && [[defaults objectForKey:@"hostPreference"] isEqual:@"host-original"],
                "头像本体、彩环、挂件、直播及宿主偏好不受独立入口恢复影响");
            NSString *inputPath = [root stringByAppendingPathComponent:@"input.json"];
            NSData *inputData = DYYYBackupJSON(@{@"DYYYTest": @YES});
            [inputData writeToFile:inputPath atomically:YES];
            failures += DYYYBackupCheck([DYYYReadSettingsBackupData([NSURL fileURLWithPath:inputPath], &error) isEqual:inputData] && !error, "有界读取器保留普通文件原始字节");
            NSString *pipePath = [root stringByAppendingPathComponent:@"input-pipe"];
            failures += DYYYBackupCheck(mkfifo(pipePath.fileSystemRepresentation, 0600) == 0 && DYYYReadSettingsBackupData([NSURL fileURLWithPath:pipePath], &error) == nil && error != nil, "拒绝命名管道且不会等待读端数据");
            unlink(pipePath.fileSystemRepresentation);
            failures += DYYYBackupCheck(DYYYReadSettingsBackupData(documents, &error) == nil && error != nil, "拒绝把目录当作备份文件读取");
            // 目录符号链接不能将写入引向 DYYY 之外；导出同样不得跟随链接。
            symlink(outside.fileSystemRepresentation, folder.fileSystemRepresentation);
            failures += DYYYBackupCheck(!DYYYCommitSettingsBackup(@{@"DYYYTest": @"new"}, icons, [NSSet set], defaults, identifier, documents, &error) && error != nil, "拒绝 DYYY 目录符号链接");
            failures += DYYYBackupCheck(DYYYReadSettingsBackupIcons(documents, &error) == nil && error != nil, "导出也拒绝目录符号链接");
            failures += DYYYBackupCheck([fm contentsOfDirectoryAtPath:outside error:nil].count == 0 && [[defaults objectForKey:@"DYYYTest"] isEqual:@"old"], "链接边界失败没有任何偏好或目录外写入");
            unlink(folder.fileSystemRepresentation);
            [fm createDirectoryAtPath:folder withIntermediateDirectories:NO attributes:nil error:nil];
            [@"keep" writeToFile:unrelated atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [oldPNG writeToFile:[outside stringByAppendingPathComponent:@"original.png"] atomically:YES];
            symlink([outside stringByAppendingPathComponent:@"original.png"].fileSystemRepresentation, target.fileSystemRepresentation);
            failures += DYYYBackupCheck(!DYYYCommitSettingsBackup(@{@"DYYYTest": @"new"}, icons, [NSSet set], defaults, identifier, documents, &error), "拒绝单个白名单文件符号链接");
            failures += DYYYBackupCheck(DYYYReadSettingsBackupIcons(documents, &error) == nil, "导出拒绝白名单文件符号链接");
            unlink(target.fileSystemRepresentation);
            [oldPNG writeToFile:target atomically:YES];
            defaults.failNextSynchronize = YES;
            failures += DYYYBackupCheck(!DYYYCommitSettingsBackup(@{@"DYYYTest": @"new"}, icons, [NSSet setWithObject:@"DYYYHDRModeMigratedV1"], defaults, identifier, documents, &error), "偏好同步失败必须拒绝成功");
            failures += DYYYBackupCheck([[NSData dataWithContentsOfFile:target] isEqual:oldPNG] && [[defaults objectForKey:@"DYYYTest"] isEqual:@"old"] && [defaults boolForKey:@"DYYYHDRModeMigratedV1"], "失败回滚图标、配置与精确清理的迁移标记");
            failures += DYYYBackupCheck([[NSString stringWithContentsOfFile:unrelated encoding:NSUTF8StringEncoding error:nil] isEqual:@"keep"] && [[defaults objectForKey:@"hostPreference"] isEqual:@"host-original"], "不触碰无关用户文件与宿主偏好");
            failures += DYYYBackupCheck(DYYYCommitSettingsBackup(@{@"DYYYTest": @"new"}, icons, [NSSet setWithObject:@"DYYYHDRModeMigratedV1"], defaults, identifier, documents, &error) && !error, "完整事务成功");
            failures += DYYYBackupCheck([[NSData dataWithContentsOfFile:target] isEqual:png] && ![defaults objectForKey:@"DYYYHDRModeMigratedV1"], "成功保存原始图片并精确移除迁移标记");
            NSDictionary *exported = DYYYReadSettingsBackupIcons(documents, &error);
            failures += DYYYBackupCheck([exported[@"share.png"] isEqual:png] && exported.count == 1, "导出忽略非白名单文件且原样保留 PNG");
            // 派生配置、旧键删除、完成标记必须一起回滚；本机另一偏移保持不变。
            [defaults setObject:@"9" forKey:@"DYYYNicknameVerticalOffset"];
            [defaults setObject:@"13" forKey:@"DYYYDescriptionVerticalOffset"];
            [defaults setObject:@"全局过滤HDR作品" forKey:@"DYYYHDRMode"];
            [defaults setBool:YES forKey:@"DYYYScaleAndSizeSettingsMigratedV1"];
            [defaults setBool:YES forKey:@"DYYYHDRModeLabelV2"];
            [defaults setBool:YES forKey:@"DYYYFilterFeedHDR"];
            [defaults synchronize];
            NSDictionary *oldSettings = @{@"DYYYNicknameVerticalOffset": @"5", @"DYYYFilterFeedHDR": @NO};
            defaults.throwNextSynchronize = YES;
            failures += DYYYBackupCheck(!DYYYCommitSettingsBackup(oldSettings, icons, [NSSet set], defaults, identifier, documents, &error), "异常中断必须回滚精确归一化产生的全部更改");
            failures += DYYYBackupCheck([[defaults objectForKey:@"DYYYNicknameVerticalOffset"] isEqual:@"9"] && [[defaults objectForKey:@"DYYYDescriptionVerticalOffset"] isEqual:@"13"] && [[defaults objectForKey:@"DYYYHDRMode"] isEqual:@"全局过滤HDR作品"] && [defaults boolForKey:@"DYYYFilterFeedHDR"] && ![defaults objectForKey:@"DYYYHDRModeMigratedV1"], "异常回滚转换值、旧键及新完成标记，不改未导入的偏移");
            failures += DYYYBackupCheck(DYYYCommitSettingsBackup(oldSettings, icons, [NSSet set], defaults, identifier, documents, &error) && [[defaults objectForKey:@"DYYYNicknameVerticalOffset"] isEqual:@"-5"] && [[defaults objectForKey:@"DYYYDescriptionVerticalOffset"] isEqual:@"13"] && [[defaults objectForKey:@"DYYYHDRMode"] isEqual:@"关闭（交给抖音）"] && ![defaults objectForKey:@"DYYYFilterFeedHDR"] && [defaults boolForKey:@"DYYYHDRModeMigratedV1"], "归一化成功仅作用于本次导入旧键并清理旧 HDR 键");
            // 在同步失败时模拟另一个功能原子替换图标，回滚不能删掉新用户文件。
            NSData *concurrent = [@"other-feature-data" dataUsingEncoding:NSUTF8StringEncoding];
            defaults.beforeFailure = ^{ [concurrent writeToFile:target options:NSDataWritingAtomic error:nil]; };
            defaults.failNextSynchronize = YES;
            failures += DYYYBackupCheck(!DYYYCommitSettingsBackup(@{@"DYYYTest": @"again"}, @{@"share.png": oldPNG}, [NSSet set], defaults, identifier, documents, &error), "并发替换导致回滚冲突必须报失败");
            defaults.beforeFailure = nil;
            failures += DYYYBackupCheck([[NSData dataWithContentsOfFile:target] isEqual:concurrent] && [[defaults objectForKey:@"DYYYTest"] isEqual:@"new"], "回滚冲突不删并发新文件且偏好回退");
            BOOL keptRecovery = NO;
            for (NSString *name in [fm contentsOfDirectoryAtPath:folder error:nil]) if ([name hasPrefix:@".DYYYRestore-"]) keptRecovery = YES;
            failures += DYYYBackupCheck(keptRecovery, "回滚冲突保留旧图标暂存副本");
            failures += DYYYBackupCheck(!DYYYCommitSettingsBackup(@{@"hostPreference": @"bad"}, @{}, [NSSet set], defaults, identifier, documents, &error) && [[defaults objectForKey:@"hostPreference"] isEqual:@"host-original"], "事务入口二次拒绝非插件键");
        } @finally {
            defaults.beforeFailure = nil;
            [defaults removePersistentDomainForName:identifier];
            [defaults synchronize];
            [fm removeItemAtPath:root error:nil];
        }
        return failures;
    }
}
