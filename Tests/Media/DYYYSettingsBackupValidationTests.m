#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>
#import <unistd.h>
#import <sys/stat.h>
#include <stdio.h>
#import "DYYYSettingsBackupValidation.h"

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
        int failures = 0;
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
