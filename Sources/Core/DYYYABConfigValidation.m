#import "DYYYABConfigValidation.h"
#import "DYYYConstants.h"

const NSUInteger DYYYABConfigMaximumRemoteBytes = 8 * 1024 * 1024;
const NSUInteger DYYYABConfigMaximumLocalBytes = 40 * 1024 * 1024;

static BOOL DYYYABConfigFail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"com.dyyy.abconfig" code:1
                                      userInfo:@{NSLocalizedDescriptionKey : message}];
    return NO;
}

DYYYABConfigMode DYYYABConfigModeForPreference(id preference) {
    if (![preference isKindOfClass:[NSString class]]) return DYYYABConfigModeUnspecified;
    NSString *mode = [[preference stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if ([@[@"patch", @"dyyy_mode_patch", @"覆写", @"覆写模式", @"覆写模式：保留原设置，覆盖同名项"] containsObject:mode])
        return DYYYABConfigModePatch;
    if ([@[@"replace", @"dyyy_mode_replace", @"替换", @"替换模式", @"替换模式：忽略原配置，使用新数据"] containsObject:mode])
        return DYYYABConfigModeReplace;
    if ([@[@"remote", @"dyyy_mode_remote", @"远程", @"远程模式", DYYY_REMOTE_MODE_STRING] containsObject:mode])
        return DYYYABConfigModeRemote;
    return DYYYABConfigModeUnspecified;
}

BOOL DYYYABConfigUsesPatchMode(DYYYABConfigMode preferenceMode, DYYYABConfigMode fileMode) {
    if (preferenceMode == DYYYABConfigModeReplace) return NO;
    if (preferenceMode == DYYYABConfigModePatch) return YES;
    return fileMode != DYYYABConfigModeReplace;
}

NSDictionary *DYYYABConfigParseJSON(NSData *jsonData, DYYYABConfigMode *fileMode, NSError **error) {
    if (error) *error = nil;
    if (![jsonData isKindOfClass:[NSData class]] || jsonData.length == 0) {
        DYYYABConfigFail(error, @"配置内容为空或类型错误");
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:error];
    if (![object isKindOfClass:[NSDictionary class]]) {
        DYYYABConfigFail(error, @"配置顶层必须是字典");
        return nil;
    }
    NSDictionary *root = object;
    DYYYABConfigMode mode = DYYYABConfigModeUnspecified;
    if (root[@"mode"] != nil) {
        mode = DYYYABConfigModeForPreference(root[@"mode"]);
        if (mode != DYYYABConfigModePatch && mode != DYYYABConfigModeReplace) {
            DYYYABConfigFail(error, @"文件模式必须为覆写或替换");
            return nil;
        }
    }
    id data = root[@"data"];
    if (data != nil && ![data isKindOfClass:[NSDictionary class]]) {
        DYYYABConfigFail(error, @"配置的 data 必须是字典");
        return nil;
    }
    if (data == nil) {
        NSMutableDictionary *legacy = [root mutableCopy];
        [legacy removeObjectForKey:@"mode"];
        data = [legacy copy];
    }
    if ([data count] == 0) {
        DYYYABConfigFail(error, @"配置数据不能为空");
        return nil;
    }
    if (fileMode) *fileMode = mode;
    return [data copy];
}

NSURL *DYYYABConfigHTTPSURL(id value) {
    if (![value isKindOfClass:[NSString class]] || [value length] == 0) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:value];
    if (![components.scheme.lowercaseString isEqualToString:@"https"] || components.host.length == 0 ||
        components.user != nil || components.password != nil) return nil;
    return components.URL;
}

BOOL DYYYABConfigAcceptsResponse(NSURLResponse *response) {
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) return NO;
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    return http.statusCode >= 200 && http.statusCode < 300 &&
        DYYYABConfigHTTPSURL(http.URL.absoluteString) != nil &&
        (http.expectedContentLength < 0 || (unsigned long long)http.expectedContentLength <= DYYYABConfigMaximumRemoteBytes);
}

BOOL DYYYABConfigCanAppendBytes(NSUInteger received, NSUInteger incoming) {
    return received <= DYYYABConfigMaximumRemoteBytes && incoming <= DYYYABConfigMaximumRemoteBytes - received;
}

BOOL DYYYABConfigPersistJSON(NSData *jsonData, NSString *path, NSDictionary **config,
                             DYYYABConfigMode *fileMode, BOOL *updated, NSError **error) {
    DYYYABConfigMode parsedMode = DYYYABConfigModeUnspecified;
    NSDictionary *parsed = DYYYABConfigParseJSON(jsonData, &parsedMode, error);
    if (!parsed) return NO;
    if (![path isKindOfClass:[NSString class]] || !path.isAbsolutePath) {
        return DYYYABConfigFail(error, @"配置保存路径无效");
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    if (![manager createDirectoryAtPath:path.stringByDeletingLastPathComponent
           withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSData *existing = DYYYABConfigReadLocalFileURL([NSURL fileURLWithPath:path], NULL);
    BOOL changed = ![existing isEqualToData:jsonData];
    if (changed && ![jsonData writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    // 只有磁盘提交成功后才发布输出，调用方据此一次更新内存和加载状态。
    if (config) *config = parsed;
    if (fileMode) *fileMode = parsedMode;
    if (updated) *updated = changed;
    return YES;
}

NSData *DYYYABConfigReadLocalFileURL(NSURL *url, NSError **error) {
    if (error) *error = nil;
    if (![url isKindOfClass:[NSURL class]] || !url.isFileURL || url.path.length == 0) {
        DYYYABConfigFail(error, @"配置来源必须是本地文件");
        return nil;
    }
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSInputStream *stream = nil;
    @try {
        stream = [NSInputStream inputStreamWithURL:url];
        if (!stream) {
            DYYYABConfigFail(error, @"无法创建配置文件读取流");
            return nil;
        }
        [stream open];
        NSMutableData *result = [NSMutableData data];
        uint8_t chunk[16 * 1024];
        for (;;) {
            // 到达边界后只多探测一个字节，绝不把超量内容追加到内存结果。
            NSUInteger limit = MIN(sizeof(chunk), DYYYABConfigMaximumLocalBytes - result.length + 1);
            NSInteger count = [stream read:chunk maxLength:limit];
            if (count < 0) {
                if (error) *error = stream.streamError;
                if (!error || !*error) DYYYABConfigFail(error, @"读取配置文件失败");
                return nil;
            }
            if (count == 0) return [result copy];
            if ((NSUInteger)count > DYYYABConfigMaximumLocalBytes - result.length) {
                DYYYABConfigFail(error, @"本地配置超过四十兆限制");
                return nil;
            }
            [result appendBytes:chunk length:(NSUInteger)count];
        }
    } @finally {
        [stream close];
        if (scoped) [url stopAccessingSecurityScopedResource];
    }
}

static BOOL DYYYABConfigIsMissingFileError(NSError *error) {
    return [error.domain isEqualToString:NSCocoaErrorDomain] &&
        (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError);
}

BOOL DYYYABConfigDeleteFile(NSString *path, NSError **error) {
    if (error) *error = nil;
    if (![path isKindOfClass:[NSString class]] || !path.isAbsolutePath) {
        return DYYYABConfigFail(error, @"配置删除路径无效");
    }
    NSFileManager *manager = [NSFileManager defaultManager];
    NSError *fileError = nil;
    NSDictionary *attributes = [manager attributesOfItemAtPath:path error:&fileError];
    if (!attributes) {
        if (DYYYABConfigIsMissingFileError(fileError)) return YES;
        if (error) *error = fileError;
        if (!fileError) DYYYABConfigFail(error, @"无法确认配置文件状态");
        return NO;
    }
    NSString *type = attributes[NSFileType];
    if (![type isEqualToString:NSFileTypeRegular] && ![type isEqualToString:NSFileTypeSymbolicLink]) {
        return DYYYABConfigFail(error, @"配置删除目标不是文件");
    }
    if ([manager removeItemAtPath:path error:&fileError] || DYYYABConfigIsMissingFileError(fileError)) return YES;
    if (error) *error = fileError;
    if (!fileError) DYYYABConfigFail(error, @"删除配置文件失败");
    return NO;
}
