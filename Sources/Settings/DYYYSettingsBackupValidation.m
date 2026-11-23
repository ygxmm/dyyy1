#import "DYYYSettingsBackupValidation.h"
#import "DYYYAvatarSurroundingPolicy.h"
#import "DYYYAvatarInteractionPolicy.h"
#import "DYYYConstants.h"
#import <ImageIO/ImageIO.h>
#import <math.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import <errno.h>
#import <stdio.h>

NSUInteger const DYYYSettingsBackupMaximumBytes = 40 * 1024 * 1024;
NSUInteger const DYYYSettingsBackupMaximumIconBytes = 8 * 1024 * 1024;
NSString *const DYYYSettingsBackupValidationErrorDomain = @"DYYYSettingsBackupValidation";

@interface DYYYValidatedSettingsBackup ()
@property(nonatomic, copy, readwrite) NSDictionary<NSString *, id> *settings;
@property(nonatomic, copy, readwrite) NSDictionary<NSString *, NSData *> *icons;
@end
@implementation DYYYValidatedSettingsBackup
@end

static BOOL DYYYBackupFail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:DYYYSettingsBackupValidationErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

NSArray<NSString *> *DYYYSettingsBackupIconFileNames(void) {
    return @[@"like_before.png", @"like_after.png", @"comment.png", @"unfavorite.png", @"favorite.png", @"share.png", @"tab_plus.png", @"qingping.gif"];
}

NSData *DYYYReadSettingsBackupData(NSURL *url, NSError **error) {
    if (error) *error = nil;
    if (!url.isFileURL) { DYYYBackupFail(error, @"请选择本地备份文件"); return nil; }
    int fd = -1;
    @try {
        // 非阻塞打开后确认普通文件，避免特殊文件或并发替换为管道造成无界等待。
        fd = open(url.fileSystemRepresentation, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        struct stat info;
        if (fd < 0 || fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) {
            DYYYBackupFail(error, @"备份必须是可读取的普通文件"); return nil;
        }
        if (info.st_size < 0 || info.st_size > (off_t)DYYYSettingsBackupMaximumBytes) {
            DYYYBackupFail(error, @"备份文件超过 40 MiB 限制"); return nil;
        }
        NSMutableData *data = [NSMutableData data];
        uint8_t bytes[16384];
        ssize_t count;
        while ((count = read(fd, bytes, sizeof(bytes))) != 0) {
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) { DYYYBackupFail(error, @"无法完整读取备份文件"); return nil; }
            if (data.length + (NSUInteger)count > DYYYSettingsBackupMaximumBytes) {
                DYYYBackupFail(error, @"备份文件超过 40 MiB 限制"); return nil;
            }
            [data appendBytes:bytes length:(NSUInteger)count];
        }
        return data;
    } @catch (__unused NSException *exception) {
        DYYYBackupFail(error, @"读取备份时发生异常"); return nil;
    } @finally { if (fd >= 0) close(fd); }
}

// 不将 null 静默丢弃；所有容器都必须递归满足 JSON 和 plist 的共同子集。
static BOOL DYYYBackupValidateValue(id value, NSUInteger depth, NSUInteger *nodes, NSError **error) {
    if (depth > 32 || ++*nodes > 20000) return DYYYBackupFail(error, @"备份容器层级或项目过多");
    if ([value isKindOfClass:NSString.class]) {
        if (![value canBeConvertedToEncoding:NSUTF8StringEncoding]) return DYYYBackupFail(error, @"备份包含无效 Unicode 字符串");
        return [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 1024 * 1024 || DYYYBackupFail(error, @"备份字符串过长");
    }
    if ([value isKindOfClass:NSNumber.class]) return isfinite([value doubleValue]) || DYYYBackupFail(error, @"备份包含无效数字");
    if ([value isKindOfClass:NSArray.class]) {
        for (id child in value) if (!DYYYBackupValidateValue(child, depth + 1, nodes, error)) return NO;
        return YES;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        for (id key in value) {
            if (![key isKindOfClass:NSString.class] || [key length] > 256 || ![key canBeConvertedToEncoding:NSUTF8StringEncoding]) return DYYYBackupFail(error, @"备份字典键无效或过长");
            if (!DYYYBackupValidateValue(value[key], depth + 1, nodes, error)) return NO;
        }
        return YES;
    }
    return DYYYBackupFail(error, @"备份包含 null 或不可保存的值");
}

static BOOL DYYYBackupValidateIcon(NSData *data, NSUInteger *pixelBudget, NSError **error) {
    if (data.length == 0 || data.length > DYYYSettingsBackupMaximumIconBytes) return DYYYBackupFail(error, @"图标为空或超过 8 MiB 限制");
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache: @NO});
    if (!source) return DYYYBackupFail(error, @"图标不是有效图片");
    NSString *type = (__bridge NSString *)CGImageSourceGetType(source);
    // 旧选择器会把 PNG 或 GIF 原样保存到固定文件名，不能只依赖扩展名判断。
    BOOL valid = ([type isEqualToString:@"public.png"] || [type isEqualToString:@"com.compuserve.gif"]);
    size_t count = CGImageSourceGetCount(source);
    valid = valid && count > 0 && count <= 256 && CGImageSourceGetStatus(source) == kCGImageStatusComplete;
    for (size_t index = 0; valid && index < count; index++) {
        @autoreleasepool {
        NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, index, NULL));
        double width = [properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue];
        double height = [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue];
        double pixels = width * height;
        valid = isfinite(pixels) && width >= 1 && height >= 1 && width <= 4096 && height <= 4096 && pixels <= 16 * 1024 * 1024;
        if (!valid || pixels > 64 * 1024 * 1024 - *pixelBudget) { valid = NO; break; }
        *pixelBudget += (NSUInteger)pixels;
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, index, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache: @YES, (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES});
        valid = image != NULL && CGImageSourceGetStatusAtIndex(source, index) == kCGImageStatusComplete;
        if (image) CGImageRelease(image);
        CGImageSourceRemoveCacheAtIndex(source, index);
        }
    }
    CFRelease(source);
    return valid || DYYYBackupFail(error, @"图标格式损坏、尺寸过大或动画帧数超限");
}

// 在 Foundation 分配容器前先限制结构规模；不替代 JSON 语法解析。
static BOOL DYYYBackupPreflightJSON(NSData *data, NSError **error) {
    const uint8_t *bytes = data.bytes;
    NSUInteger depth = 0, tokens = 0, primitiveLength = 0;
    BOOL quoted = NO, escaped = NO, primitive = NO;
    for (NSUInteger i = 0; i < data.length; i++) {
        uint8_t c = bytes[i];
        if (!c) return DYYYBackupFail(error, @"备份必须使用 UTF-8 JSON 编码");
        if (quoted) {
            if (escaped) escaped = NO;
            else if (c == '\\') escaped = YES;
            else if (c == '"') quoted = NO;
            continue;
        }
        if (c == '"') { quoted = YES; primitive = NO; tokens++; }
        else if (c == '{' || c == '[') { depth++; tokens++; primitive = NO; }
        else if (c == '}' || c == ']') { if (!depth) return DYYYBackupFail(error, @"备份结构错误"); depth--; primitive = NO; }
        else if (c == ',' || c == ':' || c == ' ' || c == '\n' || c == '\r' || c == '\t') primitive = NO;
        else {
            if (!primitive) { tokens++; primitive = YES; primitiveLength = 0; }
            if (++primitiveLength > 128) return DYYYBackupFail(error, @"备份数字或字面量过长");
        }
        if (depth > 35 || tokens > 50000) return DYYYBackupFail(error, @"备份容器层级或项目过多");
    }
    return YES;
}

static BOOL DYYYBackupValidKey(id key) {
    return [key isKindOfClass:NSString.class] && [key hasPrefix:@"DYYY"] && [key length] > 4 && [key length] <= 256 &&
        [key canBeConvertedToEncoding:NSUTF8StringEncoding] &&
        [key rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound;
}

static BOOL DYYYBackupValidateKnownValue(NSString *key, id value, NSError **error) {
    if ([key isEqualToString:DYYY_DISABLE_FEED_NOW_PLAYING_INFO_KEY]) {
        if ([value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) &&
            ([value doubleValue] == 0.0 || [value doubleValue] == 1.0)) return YES;
        return DYYYBackupFail(error, @"抖音播放卡片开关必须为布尔值");
    }
    // 新独立入口键采用布尔白名单；不改变旧关注键的值类型和归一化语义。
    NSArray *avatarActionFlags = @[DYYYHideAvatarSendMessageKey, DYYYHideAvatarEnterStoreKey, DYYYHideAvatarAdLinkKey];
    if ([avatarActionFlags containsObject:key]) {
        if ([value isKindOfClass:NSNumber.class] && isfinite([value doubleValue]) &&
            ([value doubleValue] == 0.0 || [value doubleValue] == 1.0)) return YES;
        return DYYYBackupFail(error, @"头像入口开关必须为布尔值");
    }
    NSArray *flags = @[
        @"DYYYEnableAutoPlay", @"DYYYisEnableAutoPlay",
        @"DYYYHDRModeMigratedV1", @"DYYYHDRModeLabelV2",
        @"DYYYScaleAndSizeSettingsMigratedV1", @"DYYYScaleAndSizeSettingsMigratedV2",
        @"DYYYDisableAllHDR", @"DYYYFilterFeedHDR",
        // 头像拆分键与旧总开关都必须按布尔值校验，旧键只用于备份兼容迁移。
        DYYY_DISABLE_FEED_NOW_PLAYING_INFO_KEY,
        DYYYHideAvatarStoryRingKey, DYYYHideAvatarDecorationKey, DYYYHideAvatarSurroundingKey
    ];
    if ([flags containsObject:key]) {
        if ([value isKindOfClass:NSNumber.class]) return isfinite([value doubleValue]) || DYYYBackupFail(error, @"开关值不是有限数字");
        if ([value isKindOfClass:NSString.class]) {
            NSString *text = [[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
            if ([@[@"true", @"false", @"yes", @"no", @"1", @"0"] containsObject:text]) return YES;
        }
        return DYYYBackupFail(error, @"连播或迁移开关类型无效，未导入任何项目");
    }
    if ([key isEqualToString:@"DYYYHDRMode"] && ![value isKindOfClass:NSString.class]) return DYYYBackupFail(error, @"HDR 模式必须为字符串");
    if ([@[@"DYYYNicknameScale", @"DYYYDescriptionScale", @"DYYYIPLabelScale", @"DYYYNicknameVerticalOffset", @"DYYYDescriptionVerticalOffset"] containsObject:key] &&
        ![value isKindOfClass:NSString.class] && ![value isKindOfClass:NSNumber.class]) return DYYYBackupFail(error, @"尺寸或偏移配置类型无效");
    return YES;
}

DYYYValidatedSettingsBackup *DYYYValidateSettingsBackupData(NSData *data, NSError **error) {
    if (error) *error = nil;
    if (![data isKindOfClass:NSData.class] || !data.length || data.length > DYYYSettingsBackupMaximumBytes) {
        DYYYBackupFail(error, @"备份文件为空或超过 40 MiB 限制"); return nil;
    }
    @try {
    if (!DYYYBackupPreflightJSON(data, error)) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![root isKindOfClass:NSDictionary.class] || [root count] > 4096) {
        DYYYBackupFail(error, @"备份必须是项目数有限的 JSON 字典"); return nil;
    }
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    NSMutableDictionary *icons = [NSMutableDictionary dictionary];
    NSUInteger nodes = 0, totalIconBytes = 0, pixelBudget = 0;
    for (NSString *key in root) {
        if (!DYYYBackupValidKey(key)) {
            DYYYBackupFail(error, @"备份包含不属于 DYYY 的配置键"); return nil;
        }
        id value = root[key];
        if ([key isEqualToString:@"DYYYIconsBase64"]) {
            if (![value isKindOfClass:NSDictionary.class] || [value count] > 8) { DYYYBackupFail(error, @"图标集合格式错误"); return nil; }
            for (NSString *name in value) {
                @autoreleasepool {
                if (![DYYYSettingsBackupIconFileNames() containsObject:name]) { DYYYBackupFail(error, @"备份包含不允许的图标文件名"); return nil; }
                id encoded = value[name];
                if (![encoded isKindOfClass:NSString.class] || [encoded length] > 4 * ((DYYYSettingsBackupMaximumIconBytes + 2) / 3)) { DYYYBackupFail(error, @"图标编码无效或过大"); return nil; }
                NSData *image = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
                if (!image || ![[image base64EncodedStringWithOptions:0] isEqualToString:encoded]) { DYYYBackupFail(error, @"图标 Base64 编码无效"); return nil; }
                totalIconBytes += image.length;
                if (totalIconBytes > 24 * 1024 * 1024) { DYYYBackupFail(error, @"图标总大小超过 24 MiB 限制"); return nil; }
                if (!DYYYBackupValidateIcon(image, &pixelBudget, error)) return nil;
                icons[name] = image;
                }
            }
        } else {
            if (!DYYYBackupValidateKnownValue(key, value, error) || !DYYYBackupValidateValue(value, 0, &nodes, error)) return nil;
            settings[key] = value;
        }
    }
    if (![NSPropertyListSerialization propertyList:settings isValidForFormat:NSPropertyListBinaryFormat_v1_0]) { DYYYBackupFail(error, @"配置不能安全保存为 plist"); return nil; }
    DYYYValidatedSettingsBackup *backup = [DYYYValidatedSettingsBackup new];
    backup.settings = settings;
    backup.icons = icons;
    return backup;
    } @catch (__unused NSException *exception) {
        DYYYBackupFail(error, @"备份解析或验证异常，未写入任何配置"); return nil;
    }
}

// 文件操作始终锚定目录描述符，不跟随 DYYY 目录或目标文件符号链接。
static BOOL DYYYBackupSameFile(int first, const char *a, int second, const char *b) {
    struct stat x, y;
    return fstatat(first, a, &x, AT_SYMLINK_NOFOLLOW) == 0 &&
        fstatat(second, b, &y, AT_SYMLINK_NOFOLLOW) == 0 &&
        S_ISREG(x.st_mode) && S_ISREG(y.st_mode) && x.st_dev == y.st_dev && x.st_ino == y.st_ino;
}

BOOL DYYYCommitSettingsBackup(NSDictionary<NSString *, id> *settings, NSDictionary<NSString *, NSData *> *icons,
    NSSet<NSString *> *keysToRemove, NSUserDefaults *defaults, NSString *domain, NSURL *documentsURL, NSError **error) {
    if (error) *error = nil;
    int documentsFD = -1, folderFD = -1, stageFD = -1;
    BOOL createdFolder = NO, preferencesTouched = NO, success = NO, rollbackOK = YES;
    NSString *stageName = [@".DYYYRestore-" stringByAppendingString:NSUUID.UUID.UUIDString];
    const char *stageFileName = stageName.fileSystemRepresentation;
    // 固定八槽状态用 C 值记录，成功移动后不再依赖可抛异常的容器扩容。
    NSArray<NSString *> *names = DYYYSettingsBackupIconFileNames();
    const char *fileNames[] = {"like_before.png", "like_after.png", "comment.png", "unfavorite.png", "favorite.png", "share.png", "tab_plus.png", "qingping.gif"};
    const char *oldNames[] = {"old-like_before.png", "old-like_after.png", "old-comment.png", "old-unfavorite.png", "old-favorite.png", "old-share.png", "old-tab_plus.png", "old-qingping.gif"};
    const char *rollbackNames[] = {"rollback-like_before.png", "rollback-like_after.png", "rollback-comment.png", "rollback-unfavorite.png", "rollback-favorite.png", "rollback-share.png", "rollback-tab_plus.png", "rollback-qingping.gif"};
    BOOL existing[8] = {NO}, movedOld[8] = {NO}, installed[8] = {NO};
    struct stat original[8];
    NSMutableSet<NSString *> *keys = nil, *removals = nil;
    NSDictionary *persisted = nil;
    @try {
        do {
            if (!domain.length || !defaults || !documentsURL.isFileURL || ![settings isKindOfClass:NSDictionary.class] || ![icons isKindOfClass:NSDictionary.class] || icons.count > 8 || settings.count > 4096) break;
            keys = [NSMutableSet setWithArray:settings.allKeys];
            removals = keysToRemove ? [keysToRemove mutableCopy] : [NSMutableSet set];
            [keys unionSet:removals];
            NSUInteger nodes = 0;
            BOOL valid = YES;
            for (NSString *key in keys) if (!DYYYBackupValidKey(key) || [key isEqualToString:@"DYYYIconsBase64"]) { valid = NO; break; }
            for (NSString *key in settings) if (!DYYYBackupValidateKnownValue(key, settings[key], error) || !DYYYBackupValidateValue(settings[key], 0, &nodes, error)) { valid = NO; break; }
            for (NSString *name in icons) if (![names containsObject:name]) { valid = NO; break; }
            if (!valid) break;
            persisted = [[defaults persistentDomainForName:domain] copy] ?: @{};
            NSSet *legacyRemovals = nil;
            settings = DYYYNormalizeLegacySettingsBackup(settings, persisted, &legacyRemovals, error);
            if (!settings || ![NSPropertyListSerialization propertyList:settings isValidForFormat:NSPropertyListBinaryFormat_v1_0]) break;
            [removals unionSet:legacyRemovals];
            [keys unionSet:removals];
            [keys addObjectsFromArray:settings.allKeys];
            if (icons.count) {
                // Documents 是系统给定边界；先规范其父路径，再禁止 DYYY 子目录链接。
                NSString *documents = documentsURL.path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
                documentsFD = open(documents.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                if (documentsFD < 0) break;
                folderFD = openat(documentsFD, "DYYY", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                if (folderFD < 0 && errno == ENOENT) {
                    if (mkdirat(documentsFD, "DYYY", 0700) != 0) break;
                    createdFolder = YES;
                    folderFD = openat(documentsFD, "DYYY", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                }
                if (folderFD < 0 || mkdirat(folderFD, stageFileName, 0700) != 0) break;
                stageFD = openat(folderFD, stageFileName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                if (stageFD < 0) break;
                // 全部新图片先写入同一文件系统中的专属暂存目录，尚不移动用户图标。
                for (NSUInteger index = 0; index < 8; index++) {
                    NSData *data = icons[names[index]];
                    if (!data) continue;
                    if (![data isKindOfClass:NSData.class] || !data.length || data.length > DYYYSettingsBackupMaximumIconBytes) { valid = NO; break; }
                    if (fstatat(folderFD, fileNames[index], &original[index], AT_SYMLINK_NOFOLLOW) == 0) {
                        if (!S_ISREG(original[index].st_mode)) { valid = NO; break; }
                        existing[index] = YES;
                    } else if (errno != ENOENT) { valid = NO; break; }
                    int fd = openat(stageFD, fileNames[index], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
                    if (fd < 0) { valid = NO; break; }
                    NSUInteger offset = 0;
                    while (offset < data.length) {
                        ssize_t count = write(fd, (const uint8_t *)data.bytes + offset, data.length - offset);
                        if (count < 0 && errno == EINTR) continue;
                        if (count <= 0) { valid = NO; break; }
                        offset += (NSUInteger)count;
                    }
                    if (fsync(fd) != 0) valid = NO;
                    if (close(fd) != 0) valid = NO;
                    if (!valid) break;
                }
                if (!valid) break;
                for (NSUInteger index = 0; index < 8; index++) {
                    if (!icons[names[index]]) continue;
                    if (existing[index]) {
                        struct stat current;
                        if (fstatat(folderFD, fileNames[index], &current, AT_SYMLINK_NOFOLLOW) != 0 || !S_ISREG(current.st_mode) ||
                            current.st_dev != original[index].st_dev || current.st_ino != original[index].st_ino ||
                            renameat(folderFD, fileNames[index], stageFD, oldNames[index]) != 0) { valid = NO; break; }
                        movedOld[index] = YES;
                    }
                    // linkat 仅创建不存在的目标；并发出现的新文件不能被覆盖。
                    if (linkat(stageFD, fileNames[index], folderFD, fileNames[index], 0) != 0) { valid = NO; break; }
                    installed[index] = YES;
                }
                if (!valid) break;
            }
            preferencesTouched = YES;
            for (NSString *key in removals) [defaults removeObjectForKey:key];
            for (NSString *key in settings) [defaults setObject:settings[key] forKey:key];
            if (![defaults synchronize]) break;
            success = YES;
        } while (NO);
    } @catch (__unused NSException *exception) { success = NO; }
    if (!success) {
        if (preferencesTouched) {
            @try {
                for (NSString *key in keys) {
                    if (persisted[key]) [defaults setObject:persisted[key] forKey:key];
                    else [defaults removeObjectForKey:key];
                }
                if (![defaults synchronize]) rollbackOK = NO;
            } @catch (__unused NSException *exception) { rollbackOK = NO; }
        }
        for (NSInteger index = 7; index >= 0; index--) {
            if (!installed[index]) continue;
            // 先移入私有隔离槽，再复核实际捕获的 inode；不能在检查后直接 unlink 用户路径。
            if (DYYYBackupSameFile(stageFD, fileNames[index], folderFD, fileNames[index])) {
                if (renameat(folderFD, fileNames[index], stageFD, rollbackNames[index]) != 0) {
                    if (errno != ENOENT) rollbackOK = NO;
                } else if (DYYYBackupSameFile(stageFD, fileNames[index], stageFD, rollbackNames[index])) {
                    if (unlinkat(stageFD, rollbackNames[index], 0) != 0) rollbackOK = NO;
                } else {
                    // 检查与移动之间被并发替换：放回捕获的用户文件，绝不删除它。
                    rollbackOK = NO;
                    if (linkat(stageFD, rollbackNames[index], folderFD, fileNames[index], 0) == 0)
                        unlinkat(stageFD, rollbackNames[index], 0);
                }
            } else {
                struct stat current;
                if (fstatat(folderFD, fileNames[index], &current, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT) rollbackOK = NO;
            }
        }
        for (NSInteger index = 7; index >= 0; index--) {
            if (!movedOld[index]) continue;
            if (linkat(stageFD, oldNames[index], folderFD, fileNames[index], 0) != 0 &&
                !DYYYBackupSameFile(stageFD, oldNames[index], folderFD, fileNames[index])) rollbackOK = NO;
        }
    }
    // 不递归清理；回滚不完整时保留旧文件及暂存锚点供人工恢复。
    if (stageFD >= 0 && (success || rollbackOK)) {
        for (NSUInteger index = 0; index < 8; index++) {
            unlinkat(stageFD, fileNames[index], 0);
            unlinkat(stageFD, oldNames[index], 0);
        }
        unlinkat(folderFD, stageFileName, AT_REMOVEDIR);
    }
    if (stageFD >= 0) close(stageFD);
    if (!success && createdFolder && rollbackOK && folderFD >= 0) {
        struct stat held, current;
        if (fstat(folderFD, &held) == 0 && fstatat(documentsFD, "DYYY", &current, AT_SYMLINK_NOFOLLOW) == 0 &&
            held.st_dev == current.st_dev && held.st_ino == current.st_ino) unlinkat(documentsFD, "DYYY", AT_REMOVEDIR);
    }
    if (folderFD >= 0) close(folderFD);
    if (documentsFD >= 0) close(documentsFD);
    if (!success) {
        NSString *message = rollbackOK ? @"恢复失败，已回退本次更改" : (stageFD >= 0 ?
            [NSString stringWithFormat:@"恢复失败且回退不完整，未删除并发用户文件；恢复暂存保留于 DYYY/%@", stageName] :
            @"恢复失败且偏好回退不完整，请检查插件设置");
        DYYYBackupFail(error, message);
    }
    return success;
}

NSDictionary<NSString *, NSData *> *DYYYReadSettingsBackupIcons(NSURL *documentsURL, NSError **error) {
    if (error) *error = nil;
    int documentsFD = -1, folderFD = -1, fileFD = -1;
    NSMutableDictionary *icons = [NSMutableDictionary dictionary];
    BOOL valid = NO;
    @try {
        do {
            if (!documentsURL.isFileURL) break;
            NSString *documents = documentsURL.path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
            documentsFD = open(documents.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (documentsFD < 0) break;
            folderFD = openat(documentsFD, "DYYY", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (folderFD < 0) { valid = errno == ENOENT; break; }
            valid = YES;
            NSUInteger total = 0, pixels = 0;
            for (NSString *name in DYYYSettingsBackupIconFileNames()) {
                struct stat info;
                if (fstatat(folderFD, name.fileSystemRepresentation, &info, AT_SYMLINK_NOFOLLOW) != 0) {
                    if (errno == ENOENT) continue;
                    valid = NO; break;
                }
                if (!S_ISREG(info.st_mode)) { valid = NO; break; }
                fileFD = openat(folderFD, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
                if (fileFD < 0 || fstat(fileFD, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size < 1 || info.st_size > (off_t)DYYYSettingsBackupMaximumIconBytes) { valid = NO; break; }
                NSMutableData *data = [NSMutableData data];
                uint8_t buffer[16384];
                ssize_t count;
                while ((count = read(fileFD, buffer, sizeof(buffer))) != 0) {
                    if (count < 0 && errno == EINTR) continue;
                    if (count < 0 || data.length + (NSUInteger)count > DYYYSettingsBackupMaximumIconBytes) { valid = NO; break; }
                    [data appendBytes:buffer length:(NSUInteger)count];
                }
                close(fileFD); fileFD = -1;
                total += data.length;
                if (!valid || total > 24 * 1024 * 1024 || !DYYYBackupValidateIcon(data, &pixels, error)) { valid = NO; break; }
                icons[name] = data;
            }
        } while (NO);
    } @catch (__unused NSException *exception) { valid = NO; }
    if (fileFD >= 0) close(fileFD);
    if (folderFD >= 0) close(folderFD);
    if (documentsFD >= 0) close(documentsFD);
    if (!valid) { DYYYBackupFail(error, @"图标目录或图片无效、为符号链接或超出限制，未导出备份"); return nil; }
    return [icons copy];
}

static NSString *DYYYBackupLegacyString(id value) {
    if ([value isKindOfClass:NSString.class]) return value;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return nil;
}

NSDictionary<NSString *, id> *DYYYNormalizeLegacySettingsBackup(NSDictionary<NSString *, id> *settings,
    NSDictionary<NSString *, id> *existingSettings, NSSet<NSString *> **keysToRemove, NSError **error) {
    if (error) *error = nil;
    if (keysToRemove) *keysToRemove = nil;
    @try {
        if (![settings isKindOfClass:NSDictionary.class] || ![existingSettings isKindOfClass:NSDictionary.class]) {
            DYYYBackupFail(error, @"旧配置归一化输入类型错误"); return nil;
        }
        for (NSString *key in settings) if (!DYYYBackupValidateKnownValue(key, settings[key], error)) return nil;
        NSMutableDictionary *normalized = [settings mutableCopy];
        NSMutableSet *removed = [NSMutableSet set];
        BOOL oldHDR = settings[@"DYYYDisableAllHDR"] || settings[@"DYYYFilterFeedHDR"];
        BOOL oldLabel = [settings[@"DYYYHDRMode"] isEqualToString:@"关闭"] || [settings[@"DYYYHDRMode"] isEqualToString:@"全局屏蔽HDR效果"];
        BOOL oldSize = settings[@"DYYYNicknameScale"] || settings[@"DYYYNicknameVerticalOffset"] || settings[@"DYYYDescriptionVerticalOffset"];
        BOOL migratedHDR = oldHDR && ![settings[@"DYYYHDRModeMigratedV1"] boolValue];
        // 孤立的未完成标记不应重置本机迁移状态，避免启动时迁移未导入的键。
        NSDictionary *relevant = @{@"DYYYHDRModeMigratedV1": @(oldHDR), @"DYYYHDRModeLabelV2": @(migratedHDR || oldLabel),
            @"DYYYScaleAndSizeSettingsMigratedV1": @(oldSize), @"DYYYScaleAndSizeSettingsMigratedV2": @(settings[@"DYYYNicknameScale"] != nil)};
        for (NSString *marker in relevant) {
            if (settings[marker] && ![settings[marker] boolValue] && ![relevant[marker] boolValue]) [normalized removeObjectForKey:marker];
        }
        if (migratedHDR) {
            NSString *mode = settings[@"DYYYHDRMode"];
            // 与现有一次迁移相同，但绝不读取本机 HDRMode 吞掉本次旧备份的意图。
            if (![mode isEqualToString:@"关闭（交给抖音）"] && ![mode isEqualToString:@"全局过滤HDR作品"])
                normalized[@"DYYYHDRMode"] = [settings[@"DYYYFilterFeedHDR"] boolValue] ? @"全局过滤HDR作品" : @"关闭（交给抖音）";
            [normalized removeObjectForKey:@"DYYYDisableAllHDR"];
            [normalized removeObjectForKey:@"DYYYFilterFeedHDR"];
            [removed addObjectsFromArray:@[@"DYYYDisableAllHDR", @"DYYYFilterFeedHDR"]];
            normalized[@"DYYYHDRModeMigratedV1"] = @YES;
        }
        NSString *mode = normalized[@"DYYYHDRMode"];
        if ((migratedHDR || oldLabel) &&
            ![settings[@"DYYYHDRModeLabelV2"] boolValue]) {
            if ([mode isEqualToString:@"关闭"] || [mode isEqualToString:@"全局屏蔽HDR效果"]) normalized[@"DYYYHDRMode"] = @"关闭（交给抖音）";
            normalized[@"DYYYHDRModeLabelV2"] = @YES;
        }
        NSString *scale = DYYYBackupLegacyString(settings[@"DYYYNicknameScale"]);
        if (oldSize && ![settings[@"DYYYScaleAndSizeSettingsMigratedV1"] boolValue]) {
            if (scale.length && !settings[@"DYYYDescriptionScale"] && !existingSettings[@"DYYYDescriptionScale"])
                normalized[@"DYYYDescriptionScale"] = scale;
            // 只反转备份携带的偏移，未导入的本机另一项偏移不能再次反转。
            for (NSString *key in @[@"DYYYNicknameVerticalOffset", @"DYYYDescriptionVerticalOffset"]) {
                NSString *text = DYYYBackupLegacyString(settings[key]);
                if (!text.length) continue;
                float offset = text.floatValue;
                if (!isfinite(offset)) { DYYYBackupFail(error, @"旧偏移数值溢出或非有限"); return nil; }
                normalized[key] = offset == 0.0f ? text : [NSString stringWithFormat:@"%g", -(double)offset];
            }
            normalized[@"DYYYScaleAndSizeSettingsMigratedV1"] = @YES;
        }
        if (settings[@"DYYYNicknameScale"] && ![settings[@"DYYYScaleAndSizeSettingsMigratedV2"] boolValue]) {
            if (scale.length && !settings[@"DYYYIPLabelScale"] && !existingSettings[@"DYYYIPLabelScale"])
                normalized[@"DYYYIPLabelScale"] = scale;
            normalized[@"DYYYScaleAndSizeSettingsMigratedV2"] = @YES;
        }

        // 旧备份只按自身携带的旧总开关映射；绝不从本机旧键推导新值。
        // 备份显式的新值优先；若本机已有新值，也保留它，让旧备份不会覆盖用户的拆分选择。
        id legacyAvatarValue = settings[DYYYHideAvatarSurroundingKey];
        BOOL payloadHasStoryRing = settings[DYYYHideAvatarStoryRingKey] != nil;
        BOOL payloadHasDecoration = settings[DYYYHideAvatarDecorationKey] != nil;
        if (legacyAvatarValue != nil) {
            BOOL legacyEnabled = [legacyAvatarValue boolValue];
            if (!payloadHasStoryRing && existingSettings[DYYYHideAvatarStoryRingKey] == nil)
                normalized[DYYYHideAvatarStoryRingKey] = @(legacyEnabled);
            if (!payloadHasDecoration && existingSettings[DYYYHideAvatarDecorationKey] == nil)
                normalized[DYYYHideAvatarDecorationKey] = @(legacyEnabled);
        }
        // 只有备份自身携带旧总开关时才迁移并移除旧键；单独导入新键必须保留本机旧回退，
        // 这样未导入的另一项仍可继承本机旧 true，而本项显式 false 已由上面的新键优先规则覆盖旧值。
        if (legacyAvatarValue != nil) {
            [normalized removeObjectForKey:DYYYHideAvatarSurroundingKey];
            [removed addObject:DYYYHideAvatarSurroundingKey];
        }

        if (keysToRemove) *keysToRemove = [removed copy];
        return [normalized copy];
    } @catch (__unused NSException *exception) {
        DYYYBackupFail(error, @"旧配置归一化异常，未提交备份"); return nil;
    }
}
