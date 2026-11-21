#import <Foundation/Foundation.h>
#include <stdio.h>
#import "DYYYNowPlayingPolicy.h"

static int DYYYNowPlayingCheck(BOOL passed, const char *name) {
    printf("%s now-playing policy: %s\n", passed ? "PASS" : "FAIL", name);
    return passed ? 0 : 1;
}
static void DYYYRecordPolicyValue(NSMutableDictionary *values, NSMutableArray *order, NSString *channel, id value) {
    values[channel] = value ?: NSNull.null;
    [order addObject:channel];
}
int DYYYRunNowPlayingPolicyTests(void) {
    int failures = 0;
    DYYYNowPlayingPolicy *policy = [DYYYNowPlayingPolicy new];
    NSMutableDictionary *output = [NSMutableDictionary dictionary];
    NSMutableArray *order = [NSMutableArray array];
    NSObject *center = [NSObject new], *session = [NSObject new], *controller = [NSObject new];
    NSArray *configurations = @[
        @[@"metadata", NSNull.null], @[@"content-item", NSNull.null], @[@"state", @0],
        @[@"session-base", NSNull.null], @[@"session-info", NSNull.null],
        @[@"session-auto", @NO], @[@"session-eligible", @NO], @[@"controller-auto", @NO]
    ];
    for (NSArray *entry in configurations) {
        NSString *channel = entry[0]; id hidden = entry[1] == NSNull.null ? nil : entry[1];
        failures += DYYYNowPlayingCheck([policy configureChannel:channel hiddenValue:hidden sink:^(id owner, id value) {
            DYYYRecordPolicyValue(output, order, channel, value);
        }], "动态发布通道的注册与nil隐藏值");
    }
    [policy seedValue:@{@"title":@"old"} owner:center channel:@"metadata"];
    [policy seedValue:@1 owner:center channel:@"content-item"];
    [policy seedValue:@4 owner:center channel:@"state"];
    [policy seedValue:@{@"title":@"base"} owner:session channel:@"session-base"];
    [policy seedValue:@{@"title":@"manual"} owner:session channel:@"session-info"];
    [policy seedValue:@YES owner:session channel:@"session-auto"];
    [policy seedValue:@YES owner:session channel:@"session-eligible"];
    [policy seedValue:@YES owner:controller channel:@"controller-auto"];
    failures += DYYYNowPlayingCheck([order containsObject:@"metadata"] == NO,
        "开关关闭时仅快照既有值，不对系统重复发布");

    failures += DYYYNowPlayingCheck([policy setSuppressed:YES] && policy.suppressed, "切换到统一屏蔽状态");
    failures += DYYYNowPlayingCheck(output[@"metadata"] == NSNull.null && output[@"content-item"] == NSNull.null &&
        output[@"state"] && [output[@"state"] isEqual:@0] && output[@"session-base"] == NSNull.null &&
        output[@"session-info"] == NSNull.null && [output[@"session-auto"] isEqual:@NO] &&
        [output[@"session-eligible"] isEqual:@NO] && [output[@"controller-auto"] isEqual:@NO],
        "旧中心、iOS新内容item、session、AVKit自动发布统一隐藏");
    NSUInteger autoIndex = [order indexOfObject:@"session-auto"], infoIndex = [order indexOfObject:@"metadata"];
    failures += DYYYNowPlayingCheck(autoIndex < infoIndex, "先关自动发布资格再清空媒体内容");

    [policy writeValue:@{@"title":@"latest"} owner:center channel:@"metadata"];
    [policy writeValue:@2 owner:center channel:@"content-item"];
    [policy writeValue:@2 owner:center channel:@"state"];
    [policy writeValue:@{@"title":@"latest-base"} owner:session channel:@"session-base"];
    [policy writeValue:@NO owner:session channel:@"session-auto"];
    failures += DYYYNowPlayingCheck(output[@"metadata"] == NSNull.null && output[@"content-item"] == NSNull.null &&
        [output[@"state"] isEqual:@0] && output[@"session-base"] == NSNull.null && [output[@"session-auto"] isEqual:@NO],
        "屏蔽期间继续记录最新原生请求但只向系统输出隐藏值");

    [order removeAllObjects];
    failures += DYYYNowPlayingCheck([policy setSuppressed:NO] && !policy.suppressed, "关闭后恢复同一套运行时策略");
    NSUInteger metadataIndex = [order indexOfObject:@"metadata"];
    NSUInteger sessionInfoIndex = [order indexOfObject:@"session-base"];
    NSUInteger stateIndex = [order indexOfObject:@"state"];
    NSUInteger publishIndex = [order indexOfObject:@"session-auto"];
    failures += DYYYNowPlayingCheck([output[@"metadata"][@"title"] isEqual:@"latest"] &&
        [output[@"content-item"] isEqual:@2] && [output[@"session-base"][@"title"] isEqual:@"latest-base"] &&
        [output[@"session-info"][@"title"] isEqual:@"manual"] && [output[@"state"] isEqual:@2],
        "关闭时恢复各owner最新原生信息而非开关前陈旧快照");
    failures += DYYYNowPlayingCheck([output[@"session-auto"] isEqual:@NO] &&
        [output[@"session-eligible"] isEqual:@YES] && [output[@"controller-auto"] isEqual:@YES] &&
        metadataIndex < sessionInfoIndex && sessionInfoIndex < stateIndex && stateIndex < publishIndex,
        "恢复媒体数据后再恢复session原生发布偏好");

    [policy setSuppressed:YES];
    [policy writeValue:nil owner:center channel:@"metadata"];
    failures += DYYYNowPlayingCheck(output[@"metadata"] == NSNull.null, "原生显式写nil不会沿用较旧标题");
    [policy setSuppressed:NO];
    failures += DYYYNowPlayingCheck(output[@"metadata"] == NSNull.null, "解除屏蔽时准确保留最新显式nil");
    [policy forgetOwner:center];
    failures += DYYYNowPlayingCheck(![policy hasRequestForChannel:@"metadata" owner:center], "center失效时清除内存恢复快照");
    failures += DYYYNowPlayingCheck(![policy setSuppressed:NO], "重复应用相同状态不重复系统写入");

    DYYYNowPlayingPolicy *reentrant = [DYYYNowPlayingPolicy new];
    NSObject *reentrantOwner = [NSObject new]; __block NSUInteger calls = 0;
    [reentrant configureChannel:@"metadata" hiddenValue:nil sink:^(id owner, id value) {
        calls++;
        [reentrant writeValue:value owner:owner channel:@"metadata"];
    }];
    [reentrant setSuppressed:YES];
    [reentrant writeValue:@{@"title":@"x"} owner:reentrantOwner channel:@"metadata"];
    failures += DYYYNowPlayingCheck(calls == 1, "底层系统setter回调重入不会递归发布");

    DYYYNowPlayingPolicy *cascade = [DYYYNowPlayingPolicy new];
    NSMutableDictionary *cascadeOutput = [NSMutableDictionary dictionary];
    NSObject *cascadeOwner = [NSObject new];
    [cascade configureChannel:@"metadata" hiddenValue:nil sink:^(id owner, id value) {
        [cascade writeValue:@9 owner:owner channel:@"state"];
    }];
    [cascade configureChannel:@"state" hiddenValue:@0 sink:^(id owner, id value) {
        cascadeOutput[@"state"] = value;
    }];
    [cascade seedValue:@{@"title":@"native"} owner:cascadeOwner channel:@"metadata"];
    [cascade seedValue:@4 owner:cascadeOwner channel:@"state"];
    [cascade setSuppressed:YES];
    [cascade setSuppressed:NO];
    failures += DYYYNowPlayingCheck([cascadeOutput[@"state"] isEqual:@4],
        "另一setter内由系统引发的同步副作用不会覆盖快照");

    DYYYNowPlayingPolicy *passThrough = [DYYYNowPlayingPolicy new];
    NSMutableDictionary *passthrough = [NSMutableDictionary dictionary];
    [passThrough configureChannel:@"metadata" hiddenValue:nil sink:^(id owner, id value) { passthrough[@"value"] = value ?: NSNull.null; }];
    [passThrough writeValue:@{@"title":@"control"} owner:controller channel:@"metadata"];
    failures += DYYYNowPlayingCheck([passthrough[@"value"][@"title"] isEqual:@"control"] && !passThrough.suppressed,
        "开关默认关闭时媒体信息正常透传");
    printf("Now Playing policy tests: %s\n", failures ? "FAIL" : "PASS");
    return failures;
}
