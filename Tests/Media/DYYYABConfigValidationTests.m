#import "../../Sources/Core/DYYYABConfigValidation.h"
#include <stdio.h>

static int DYYYVerifyAB(BOOL pass, const char *meaning) {
    printf("%s AB配置: %s\n", pass ? "PASS" : "FAIL", meaning);
    return !pass;
}

static NSData *DYYYABJSON(NSString *text) {
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

// 本地文件用例不访问应用配置目录，只使用统一入口创建的临时目录。
static int DYYYRunABLocalFileCases(NSString *folder);

// 只依赖 Foundation；由统一测试入口声明并调用，不定义独立主函数。
int DYYYRunABConfigValidationTests(void) {
    int failed = 0;
    NSArray *replaceNames = @[@"replace", @"REPLACE", @"DYYY_MODE_REPLACE", @"dyyy_mode_replace",
        @" 替换模式：忽略原配置，使用新数据\n", @"替换模式", @"替换"];
    for (NSString *name in replaceNames) {
        failed += DYYYVerifyAB(DYYYABConfigModeForPreference(name) == DYYYABConfigModeReplace,
            "中文、英文、历史大写和小写替换模式一致");
    }
    for (NSString *name in @[@"PATCH", @"DYYY_MODE_PATCH", @"覆写模式：保留原设置，覆盖同名项", @"覆写模式", @"覆写"]) {
        failed += DYYYVerifyAB(DYYYABConfigModeForPreference(name) == DYYYABConfigModePatch,
            "覆写模式兼容中文及历史格式");
    }
    for (NSString *name in @[@"REMOTE", @"DYYY_MODE_REMOTE", @"远程模式：启动时自动检查更新"]) {
        failed += DYYYVerifyAB(DYYYABConfigModeForPreference(name) == DYYYABConfigModeRemote,
            "远程设置保留原语义");
    }
    for (id invalid in @[@"", @"???", @1, @[], @{}, [NSNull null]]) {
        failed += DYYYVerifyAB(DYYYABConfigModeForPreference(invalid) == DYYYABConfigModeUnspecified,
            "无效设置不触发错误类型消息");
    }
    failed += DYYYVerifyAB(DYYYABConfigModeForPreference(nil) == DYYYABConfigModeUnspecified,
        "未设置模式允许采用文件模式");
    DYYYABConfigMode choices[] = { DYYYABConfigModeUnspecified, DYYYABConfigModePatch,
        DYYYABConfigModeReplace, DYYYABConfigModeRemote };
    for (NSUInteger i = 0; i < 4; ++i) {
        for (NSUInteger j = 0; j < 3; ++j) {
            BOOL expected = choices[i] == DYYYABConfigModePatch ||
                (choices[i] != DYYYABConfigModeReplace && choices[j] != DYYYABConfigModeReplace);
            failed += DYYYVerifyAB(DYYYABConfigUsesPatchMode(choices[i], choices[j]) == expected,
                "本地显式模式优先，远程和未设置模式采用文件模式，缺省覆写");
        }
    }
    NSArray *valid = @[
        @"{\"mode\":\"DYYY_MODE_REPLACE\",\"data\":{\"keep\":1,\"nested\":{\"a\":true}}}",
        @"{\"mode\":\"replace\",\"keep\":1}",
        @"{\"mode\":\"覆写模式：保留原设置，覆盖同名项\",\"data\":{\"keep\":1}}",
        @"{\"keep\":1}", @"{\"data\":{\"keep\":1}}"
    ];
    DYYYABConfigMode expectedModes[] = { DYYYABConfigModeReplace, DYYYABConfigModeReplace,
        DYYYABConfigModePatch, DYYYABConfigModeUnspecified, DYYYABConfigModeUnspecified };
    for (NSUInteger i = 0; i < valid.count; ++i) {
        NSError *error = nil;
        DYYYABConfigMode mode = DYYYABConfigModeRemote;
        NSDictionary *config = DYYYABConfigParseJSON(DYYYABJSON(valid[i]), &mode, &error);
        failed += DYYYVerifyAB(config && [config[@"keep"] isEqual:@1] && !config[@"mode"] &&
            mode == expectedModes[i] && !error, "封装和历史平铺字典提取正确且不改变 AB 值");
    }
    NSArray *invalidJSON = @[@"", @"{", @"[]", @"null", @"42", @"\"bad\"", @"{}",
        @"{\"mode\":\"replace\"}", @"{\"data\":{}}", @"{\"data\":null}",
        @"{\"data\":[]}", @"{\"data\":1}", @"{\"data\":\"bad\"}",
        @"{\"mode\":null,\"keep\":1}", @"{\"mode\":1,\"keep\":1}",
        @"{\"mode\":\"\",\"keep\":1}", @"{\"mode\":\"unknown\",\"keep\":1}",
        @"{\"mode\":\"remote\",\"data\":{\"keep\":1}}"];
    for (NSString *text in invalidJSON) {
        NSError *error = nil;
        DYYYABConfigMode mode = DYYYABConfigModeReplace;
        failed += DYYYVerifyAB(!DYYYABConfigParseJSON(DYYYABJSON(text), &mode, &error) &&
            error && mode == DYYYABConfigModeReplace, "非法、空、非字典或无效模式失败且不发布文件模式");
    }
    failed += DYYYVerifyAB(!DYYYABConfigParseJSON((id)[NSNull null], NULL, NULL) &&
        !DYYYABConfigParseJSON(nil, NULL, NULL), "错误数据类型和空指针安全失败");
    for (id value in @[@"http://example.com/config", @"https:///", @"file:///tmp/a", @1,
        [NSNull null], @"https://user:pass@example.com/a"]) {
        failed += DYYYVerifyAB(!DYYYABConfigHTTPSURL(value), "拒绝非 HTTPS、无主机和错误类型地址");
    }
    NSURL *url = DYYYABConfigHTTPSURL(@"HTTPS://example.com/ab.json?key=a%2Bb");
    failed += DYYYVerifyAB(url != nil, "合法 HTTPS 和编码查询保持可用");
    for (NSNumber *status in @[@200, @204, @206, @299, @301, @304, @400, @404, @500]) {
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:status.integerValue
            HTTPVersion:@"HTTP/1.1" headerFields:nil];
        failed += DYYYVerifyAB(DYYYABConfigAcceptsResponse(response) ==
            (status.integerValue >= 200 && status.integerValue < 300), "仅 HTTP 成功状态可进入 JSON 校验");
    }
    NSHTTPURLResponse *large = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Content-Length": [@(DYYYABConfigMaximumRemoteBytes + 1) stringValue]}];
    NSHTTPURLResponse *downgraded = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"http://example.com/a"]
        statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    failed += DYYYVerifyAB(!DYYYABConfigAcceptsResponse(large) && !DYYYABConfigAcceptsResponse(downgraded) &&
        !DYYYABConfigAcceptsResponse([NSURLResponse new]) && !DYYYABConfigAcceptsResponse(nil) &&
        !DYYYABConfigHTTPSURL(nil), "拒绝超大声明、最终 HTTP 降级、空响应和非 HTTP 响应");
    failed += DYYYVerifyAB(DYYYABConfigCanAppendBytes(0, DYYYABConfigMaximumRemoteBytes) &&
        !DYYYABConfigCanAppendBytes(0, DYYYABConfigMaximumRemoteBytes + 1) &&
        !DYYYABConfigCanAppendBytes(NSUIntegerMax, 1) &&
        !DYYYABConfigCanAppendBytes(DYYYABConfigMaximumRemoteBytes, 1), "实际大小边界和整数溢出保护");

    NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    NSString *path = [folder stringByAppendingPathComponent:@"nested/ab.json"];
    NSData *oldBytes = DYYYABJSON(@"{\"mode\":\"patch\",\"keep\":1}");
    NSData *newBytes = DYYYABJSON(valid[0]);
    NSDictionary *published = nil;
    DYYYABConfigMode mode = DYYYABConfigModeUnspecified;
    BOOL updated = NO;
    NSError *error = nil;
    failed += DYYYVerifyAB(DYYYABConfigPersistJSON(oldBytes, path, &published, &mode, &updated, &error) &&
        updated && mode == DYYYABConfigModePatch && [published[@"keep"] isEqual:@1], "首次保存创建目录并发布完整状态");
    updated = YES;
    failed += DYYYVerifyAB(DYYYABConfigPersistJSON(oldBytes, path, &published, &mode, &updated, &error) &&
        !updated && !error, "相同有效字节为最新配置而非伪更新");
    NSDictionary *previous = published;
    updated = YES;
    failed += DYYYVerifyAB(!DYYYABConfigPersistJSON(DYYYABJSON(@"{\"data\":[]}"), path, &published, &mode, &updated, &error) &&
        published == previous && mode == DYYYABConfigModePatch && updated &&
        [[NSData dataWithContentsOfFile:path] isEqualToData:oldBytes], "验证失败保留旧文件和所有状态输出");
    // 用普通文件阻挡父目录，避免依赖宿主进程的权限或是否以管理员身份运行。
    NSString *blocked = [path stringByAppendingPathComponent:@"cannot-write.json"];
    failed += DYYYVerifyAB(!DYYYABConfigPersistJSON(newBytes, blocked, &published, &mode, &updated, &error) &&
        published == previous && mode == DYYYABConfigModePatch && updated &&
        [[NSData dataWithContentsOfFile:path] isEqualToData:oldBytes], "创建目录失败不改变旧有效配置或状态输出");
    NSString *directoryTarget = [folder stringByAppendingPathComponent:@"directory"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directoryTarget withIntermediateDirectories:YES attributes:nil error:NULL];
    failed += DYYYVerifyAB(!DYYYABConfigPersistJSON(newBytes, directoryTarget, &published, &mode, &updated, &error) &&
        published == previous && mode == DYYYABConfigModePatch && updated, "原子写入目标为目录时不发布内存或成功状态");
    updated = NO;
    failed += DYYYVerifyAB(DYYYABConfigPersistJSON(newBytes, path, &published, &mode, &updated, &error) &&
        updated && mode == DYYYABConfigModeReplace && [[NSData dataWithContentsOfFile:path] isEqualToData:newBytes],
        "有效更新原子替换磁盘后才发布新模式与数据");
    failed += DYYYRunABLocalFileCases(folder);
    [[NSFileManager defaultManager] removeItemAtPath:folder error:NULL];
    return failed;
}

static int DYYYRunABLocalFileCases(NSString *folder) {
    int failed = 0;
    NSError *error = nil;
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *source = [folder stringByAppendingPathComponent:@"local-source.json"];
    NSString *destination = [folder stringByAppendingPathComponent:@"local-import.json"];
    NSData *oldBytes = DYYYABJSON(@"{\"mode\":\"patch\",\"keep\":1}");
    NSData *newBytes = DYYYABJSON(@"{\"mode\":\"DYYY_MODE_REPLACE\",\"data\":{\"keep\":2}}");
    NSDictionary *published = nil;
    DYYYABConfigMode mode = DYYYABConfigModeUnspecified;
    BOOL updated = NO;
    failed += DYYYVerifyAB(DYYYABConfigPersistJSON(oldBytes, destination, &published, &mode, &updated, &error),
        "本地导入用例建立旧有效配置");
    for (id invalid in @[[NSNull null], @1, @"not-url", [NSURL URLWithString:@"https://example.com/ab.json"]]) {
        error = nil;
        failed += DYYYVerifyAB(!DYYYABConfigReadLocalFileURL(invalid, &error) && error,
            "本地读取拒绝非文件地址和错误类型");
    }
    failed += DYYYVerifyAB(!DYYYABConfigReadLocalFileURL(nil, &error) && error,
        "本地空文件地址安全失败");
    failed += DYYYVerifyAB(!DYYYABConfigReadLocalFileURL([NSURL fileURLWithPath:source], &error) && error,
        "本地文件缺失返回错误而非伪成功");
    [DYYYABJSON(@"{\"data\":[]}") writeToFile:source atomically:YES];
    NSData *invalidData = DYYYABConfigReadLocalFileURL([NSURL fileURLWithPath:source], &error);
    NSDictionary *previous = published;
    failed += DYYYVerifyAB(invalidData && !DYYYABConfigPersistJSON(invalidData, destination, &published, &mode, &updated, &error) &&
        published == previous && mode == DYYYABConfigModePatch && [[NSData dataWithContentsOfFile:destination] isEqualToData:oldBytes],
        "本地非法导入共同校验失败且保留旧文件及发布输出");
    [newBytes writeToFile:source atomically:YES];
    NSData *read = DYYYABConfigReadLocalFileURL([NSURL fileURLWithPath:source], &error);
    failed += DYYYVerifyAB([read isEqualToData:newBytes] && !error &&
        DYYYABConfigPersistJSON(read, destination, &published, &mode, &updated, &error) &&
        mode == DYYYABConfigModeReplace && [published[@"keep"] isEqual:@2],
        "本地有效导入复用共同解析和原子保存规则");

    @autoreleasepool {
        // 合法 JSON 后的空白扩展超过八兆，证明本地历史配置不受远程上限误伤。
        NSUInteger paddingLength = DYYYABConfigMaximumRemoteBytes + 1;
        NSMutableData *largeJSON = [newBytes mutableCopy];
        NSData *padding = [[@"" stringByPaddingToLength:paddingLength withString:@" " startingAtIndex:0]
            dataUsingEncoding:NSUTF8StringEncoding];
        [largeJSON appendData:padding];
        BOOL sourceWritten = [largeJSON writeToFile:source atomically:YES];
        NSData *largeRead = DYYYABConfigReadLocalFileURL([NSURL fileURLWithPath:source], &error);
        failed += DYYYVerifyAB(sourceWritten && largeRead.length == largeJSON.length && !error &&
            DYYYABConfigPersistJSON(largeRead, destination, &published, &mode, &updated, &error),
            "超过八兆但低于四十兆的合法本地配置可读可原子提交");
    }
    @autoreleasepool {
        // 稀疏文件只用于读取边界，不作为 JSON 解析输入，避免测试构造大字符串。
        NSString *boundaryPath = [folder stringByAppendingPathComponent:@"local-boundary.bin"];
        [manager createFileAtPath:boundaryPath contents:[NSData data] attributes:nil];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:boundaryPath];
        [handle truncateFileAtOffset:DYYYABConfigMaximumLocalBytes];
        [handle closeFile];
        NSData *boundary = DYYYABConfigReadLocalFileURL([NSURL fileURLWithPath:boundaryPath], &error);
        failed += DYYYVerifyAB(boundary.length == DYYYABConfigMaximumLocalBytes && !error,
            "本地四十兆精确边界允许读取");
        handle = [NSFileHandle fileHandleForWritingAtPath:boundaryPath];
        [handle truncateFileAtOffset:DYYYABConfigMaximumLocalBytes + 1];
        [handle closeFile];
        failed += DYYYVerifyAB(!DYYYABConfigReadLocalFileURL([NSURL fileURLWithPath:boundaryPath], &error) && error,
            "本地超过四十兆一个字节即失败，不提交超量内容");
    }
    NSString *emptyPath = [folder stringByAppendingPathComponent:@"local-empty.json"];
    [manager createFileAtPath:emptyPath contents:[NSData data] attributes:nil];
    read = DYYYABConfigReadLocalFileURL([NSURL fileURLWithPath:emptyPath], &error);
    failed += DYYYVerifyAB(read && read.length == 0 && !DYYYABConfigParseJSON(read, NULL, &error),
        "空文件可读但不能通过共同配置校验");

    NSString *directory = [folder stringByAppendingPathComponent:@"delete-directory"];
    [manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *child = [directory stringByAppendingPathComponent:@"keep.json"];
    [oldBytes writeToFile:child atomically:YES];
    failed += DYYYVerifyAB(!DYYYABConfigDeleteFile(directory, &error) && error &&
        [[NSData dataWithContentsOfFile:child] isEqualToData:oldBytes],
        "删除目标为目录必须失败，不能递归删除无关内容");
    for (id invalid in @[[NSNull null], @1, @"", @"relative/path"]) {
        failed += DYYYVerifyAB(!DYYYABConfigDeleteFile(invalid, &error) && error,
            "无效删除路径不能被视为文件不存在");
    }
    failed += DYYYVerifyAB(DYYYABConfigDeleteFile(destination, &error) && !error &&
        ![manager fileExistsAtPath:destination], "有效文件删除成功后才允许调用方清除状态");
    failed += DYYYVerifyAB(DYYYABConfigDeleteFile(destination, &error) && !error,
        "明确已不存在的文件删除为幂等成功");
    NSString *link = [folder stringByAppendingPathComponent:@"config-link.json"];
    BOOL linked = [manager createSymbolicLinkAtPath:link withDestinationPath:child error:&error];
    failed += DYYYVerifyAB(linked && DYYYABConfigDeleteFile(link, &error) &&
        [[NSData dataWithContentsOfFile:child] isEqualToData:oldBytes],
        "删除符号链接只移除链接，保留目标文件");
    return failed;
}
