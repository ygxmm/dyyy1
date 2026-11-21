#import <Foundation/Foundation.h>
#include <stdio.h>
#import "DYYYDownloadLifecycle.h"

static int DYYYLifecycleCheck(BOOL passed, const char *meaning) {
    printf("%s download lifecycle: %s\n", passed ? "PASS" : "FAIL", meaning);
    return passed ? 0 : 1;
}

// 只模拟任务的取消接口，不联网，也不访问相册或 UIKit。
@interface DYYYLifecycleTestTask : NSObject
@property(nonatomic) NSUInteger cancelCount;
@end
@implementation DYYYLifecycleTestTask
- (void)cancel { self.cancelCount++; }
@end

// 由主 runner 调用；这些用例验证状态与取消原语，不冒充 PhotoKit 端到端测试。
int DYYYRunDownloadLifecycleTests(void) {
    @autoreleasepool {
        int failures = 0;
        DYYYDownloadPhase phase = DYYYDownloadPhaseActive;
        failures += DYYYLifecycleCheck(DYYYDownloadIsActive(phase) && !DYYYDownloadWasCancelled(phase), "初态仅为活动态");
        failures += DYYYLifecycleCheck(DYYYDownloadRequestCancellation(&phase), "首次取消必须生效");
        failures += DYYYLifecycleCheck(phase == DYYYDownloadPhaseCancelling && !DYYYDownloadIsActive(phase), "取消请求立刻关闭阶段交接闸门");
        failures += DYYYLifecycleCheck(DYYYDownloadWasCancelled(phase) && !DYYYDownloadRequestCancellation(&phase), "重复取消不重入");
        failures += DYYYLifecycleCheck(DYYYDownloadFinish(&phase) && phase == DYYYDownloadPhaseCancelled, "等待清理后才进入取消终态");
        failures += DYYYLifecycleCheck(!DYYYDownloadFinish(&phase) && !DYYYDownloadRequestCancellation(&phase), "取消终态不能再次完成或重启");

        phase = DYYYDownloadPhaseActive;
        failures += DYYYLifecycleCheck(DYYYDownloadFinish(&phase) && phase == DYYYDownloadPhaseFinished, "正常完成进入成功终态");
        failures += DYYYLifecycleCheck(!DYYYDownloadRequestCancellation(&phase) && !DYYYDownloadFinish(&phase), "完成赢得竞争后取消不能改写已交付结果");

        NSMutableDictionary *state = DYYYDownloadCreateState();
        NSMutableDictionary *handoff = state;
        failures += DYYYLifecycleCheck(DYYYDownloadTakeCallback(state) && !DYYYDownloadTakeCallback(state), "下载回调只消费一次");
        failures += DYYYLifecycleCheck(DYYYDownloadStateIsActive(state), "下载完成通知不等于保存终态");
        failures += DYYYLifecycleCheck(DYYYDownloadCancelState(state), "下载完成到保存前仍允许取消");
        failures += DYYYLifecycleCheck(!DYYYDownloadStateIsActive(handoff), "保存回调持有同一状态，不能在取消后恢复保存");
        failures += DYYYLifecycleCheck(DYYYDownloadFinishState(state) && !DYYYDownloadFinishState(state), "异步清理和迟到回调只允许一次终态");
        failures += DYYYLifecycleCheck(!DYYYDownloadTakeCallback(state), "错误或取消迟到不能重复交付下载回调");

        NSMutableDictionary *imagePhase = DYYYDownloadCreateState();
        NSUInteger liveStageStarts = 0;
        failures += DYYYLifecycleCheck(DYYYDownloadCancelState(imagePhase), "图片阶段取消生效");
        if (DYYYDownloadStateIsActive(imagePhase)) liveStageStarts++;
        failures += DYYYLifecycleCheck(liveStageStarts == 0, "图片到视频或实况阶段的交接必须被取消阻止");
        failures += DYYYLifecycleCheck(DYYYDownloadFinishState(imagePhase), "未启动后续阶段仍能完成取消清理");

        NSMutableDictionary *taskA = DYYYDownloadCreateState();
        NSMutableDictionary *taskB = DYYYDownloadCreateState();
        DYYYLifecycleTestTask *networkA = [DYYYLifecycleTestTask new];
        DYYYLifecycleTestTask *networkAudioA = [DYYYLifecycleTestTask new];
        DYYYLifecycleTestTask *networkB = [DYYYLifecycleTestTask new];
        NSDictionary *owners = @{@"imageA": @"taskA", @"audioA": @"taskA", @"imageB": @"taskB"};
        NSDictionary *networks = @{@"imageA": networkA, @"audioA": networkAudioA, @"imageB": networkB};
        NSArray<NSString *> *ownedIDs = DYYYDownloadTaskIDsForOwner(@"taskA", owners);
        failures += DYYYLifecycleCheck(ownedIDs.count == 2 && ![ownedIDs containsObject:@"imageB"], "任务归属选择不能混入别人的图片或音轨");
        NSMutableArray *ownedTasks = [NSMutableArray array];
        for (NSString *taskID in ownedIDs) [ownedTasks addObject:networks[taskID]];
        DYYYDownloadCancelState(taskA);
        DYYYDownloadCancelTasks((NSArray<NSURLSessionTask *> *)(id)ownedTasks);
        failures += DYYYLifecycleCheck(networkA.cancelCount == 1 && networkAudioA.cancelCount == 1, "父任务及所属音轨均收到 cancel 调用");
        failures += DYYYLifecycleCheck(networkB.cancelCount == 0 && DYYYDownloadStateIsActive(taskB), "单任务取消不能波及另一并发任务");
        failures += DYYYLifecycleCheck(!DYYYDownloadStateIsActive(taskA), "调用取消接口之前已经关闭父任务闸门");

        NSMutableDictionary *beforeCommit = DYYYDownloadCreateState();
        __block NSUInteger assetRequests = 0;
        DYYYDownloadCancelState(beforeCommit);
        BOOL committed = DYYYDownloadPerformIfActive(beforeCommit, ^{ assetRequests++; });
        failures += DYYYLifecycleCheck(!committed && assetRequests == 0, "取消赢得原子闸门时不得创建相册请求");
        NSMutableDictionary *afterCommit = DYYYDownloadCreateState();
        committed = DYYYDownloadPerformIfActive(afterCommit, ^{ assetRequests++; });
        DYYYDownloadCancelState(afterCommit);
        failures += DYYYLifecycleCheck(committed && assetRequests == 1 && !DYYYDownloadStateIsActive(afterCommit), "已经创建的事务不可撤销，但取消仍阻止后续请求");
        failures += DYYYLifecycleCheck(!DYYYDownloadPerformIfActive(afterCommit, ^{ assetRequests++; }) && assetRequests == 1, "提交后取消不允许再创建第二个请求");
        failures += DYYYLifecycleCheck(DYYYDownloadPerformIfActive(nil, ^{ assetRequests++; }) && assetRequests == 2, "独立保存不需要伪造下载状态");

        // 多个完成、失败和取消竞争时，终态与回调各只有一个赢家。
        for (NSUInteger round = 0; round < 32; round++) {
            NSMutableDictionary *racing = DYYYDownloadCreateState();
            NSObject *counterLock = [NSObject new];
            __block NSUInteger completions = 0;
            __block NSUInteger callbacks = 0;
            __block NSUInteger cancellations = 0;
            NSOperationQueue *operations = [NSOperationQueue new];
            operations.maxConcurrentOperationCount = 8;
            for (NSUInteger index = 0; index < 48; index++) {
                [operations addOperationWithBlock:^{
                    BOOL cancelled = index % 3 == 0 && DYYYDownloadCancelState(racing);
                    BOOL finished = index % 3 != 0 && DYYYDownloadFinishState(racing);
                    BOOL callback = DYYYDownloadTakeCallback(racing);
                    @synchronized (counterLock) {
                        cancellations += cancelled;
                        completions += finished;
                        callbacks += callback;
                    }
                }];
            }
            [operations waitUntilAllOperationsAreFinished];
            DYYYDownloadPhase terminal = [racing[@"phase"] unsignedIntegerValue];
            failures += DYYYLifecycleCheck(completions == 1 && callbacks == 1 && cancellations <= 1, "并发竞争下 completion 和终态恰好一次");
            failures += DYYYLifecycleCheck(terminal == DYYYDownloadPhaseFinished || terminal == DYYYDownloadPhaseCancelled, "并发结束必须离开活动和取消中状态");
            failures += DYYYLifecycleCheck(!DYYYDownloadStateIsActive(racing) && !DYYYDownloadCancelState(racing), "并发终态不能被重新取消或启动下一阶段");
        }

        NSURL *directory = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
        NSURL *source = [NSURL URLWithString:@"https://example.invalid/one/common.mp4?token=.m4a"];
        NSURL *first = DYYYDownloadTemporaryURL(directory, source, @"jpg");
        NSURL *second = DYYYDownloadTemporaryURL(directory, [NSURL URLWithString:@"https://other.invalid/two/common.mp4"], @"jpg");
        failures += DYYYLifecycleCheck(![first.path isEqualToString:second.path], "同 basename 的两个来源不能共用临时文件");
        failures += DYYYLifecycleCheck([first.pathExtension isEqualToString:@"mp4"] && [second.pathExtension isEqualToString:@"mp4"], "保留路径格式扩展而不把查询串当扩展");
        failures += DYYYLifecycleCheck([[[first URLByDeletingLastPathComponent].path stringByStandardizingPath] isEqualToString:[directory.path stringByStandardizingPath]], "目标文件只能落在传入的临时目录");
        failures += DYYYLifecycleCheck([[NSUUID alloc] initWithUUIDString:first.lastPathComponent.stringByDeletingPathExtension] != nil, "文件名主体来自 UUID 而非远端 basename");
        NSURL *fallback = DYYYDownloadTemporaryURL(directory, [NSURL URLWithString:@"https://example.invalid/download?id=4"], @"heic");
        failures += DYYYLifecycleCheck([fallback.pathExtension isEqualToString:@"heic"], "无扩展名时保留媒体类型的兜底扩展");
        NSURL *upper = DYYYDownloadTemporaryURL(directory, [NSURL URLWithString:@"https://example.invalid/a.JPEG"], @"jpg");
        failures += DYYYLifecycleCheck([upper.pathExtension isEqualToString:@"JPEG"], "不擅自改变已有格式扩展");
        NSURL *missing = DYYYDownloadTemporaryURL(directory, nil, @"m4a");
        failures += DYYYLifecycleCheck([missing.pathExtension isEqualToString:@"m4a"], "无源 URL 时仍生成独占文件名和兜底扩展");
        failures += DYYYLifecycleCheck(DYYYDownloadStateIsActive(nil) && !DYYYDownloadCancelState(nil) && !DYYYDownloadFinishState(nil) && !DYYYDownloadTakeCallback(nil), "无下载上下文的独立保存保持兼容且不产生虚假终态");
        return failures;
    }
}
