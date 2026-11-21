#pragma once
#import <Foundation/Foundation.h>

// 同一串行队列管理取消与终态；请求取消并不等于完成清理。
typedef NS_ENUM(NSUInteger, DYYYDownloadPhase) {
    DYYYDownloadPhaseActive = 0,
    DYYYDownloadPhaseCancelling,
    DYYYDownloadPhaseFinished,
    DYYYDownloadPhaseCancelled
};

static inline BOOL DYYYDownloadIsActive(DYYYDownloadPhase phase) {
    return phase == DYYYDownloadPhaseActive;
}

static inline BOOL DYYYDownloadWasCancelled(DYYYDownloadPhase phase) {
    return phase == DYYYDownloadPhaseCancelling || phase == DYYYDownloadPhaseCancelled;
}

static inline BOOL DYYYDownloadRequestCancellation(DYYYDownloadPhase *phase) {
    if (!DYYYDownloadIsActive(*phase)) return NO;
    *phase = DYYYDownloadPhaseCancelling;
    return YES;
}

static inline BOOL DYYYDownloadFinish(DYYYDownloadPhase *phase) {
    if (*phase == DYYYDownloadPhaseActive) {
        *phase = DYYYDownloadPhaseFinished;
        return YES;
    }
    if (*phase == DYYYDownloadPhaseCancelling) {
        *phase = DYYYDownloadPhaseCancelled;
        return YES;
    }
    return NO;
}

// 同名资源仍是不同任务的文件；只取扩展名，从不使用远端文件名作为路径。
static inline NSURL *DYYYDownloadTemporaryURL(NSURL *directory, NSURL *sourceURL, NSString *fallbackExtension) {
    NSString *extension = sourceURL.pathExtension;
    if (!extension.length || [extension rangeOfString:@"/"].location != NSNotFound) extension = fallbackExtension;
    NSString *name = NSUUID.UUID.UUIDString;
    if (extension.length) name = [name stringByAppendingPathExtension:extension];
    return [directory URLByAppendingPathComponent:name isDirectory:NO];
}

// 可被保存、合成回调持有的任务状态；所有阶段共用同一个锁和终态。
static inline NSMutableDictionary *DYYYDownloadCreateState(void) {
    return [@{@"phase": @(DYYYDownloadPhaseActive)} mutableCopy];
}
static inline BOOL DYYYDownloadStateIsActive(NSMutableDictionary *state) {
    if (!state) return YES;
    @synchronized (state) { return DYYYDownloadIsActive([state[@"phase"] unsignedIntegerValue]); }
}
static inline BOOL DYYYDownloadCancelState(NSMutableDictionary *state) {
    if (!state) return NO;
    @synchronized (state) {
        DYYYDownloadPhase phase = [state[@"phase"] unsignedIntegerValue];
        BOOL changed = DYYYDownloadRequestCancellation(&phase);
        state[@"phase"] = @(phase);
        return changed;
    }
}
static inline BOOL DYYYDownloadFinishState(NSMutableDictionary *state) {
    if (!state) return NO;
    @synchronized (state) {
        DYYYDownloadPhase phase = [state[@"phase"] unsignedIntegerValue];
        BOOL changed = DYYYDownloadFinish(&phase);
        state[@"phase"] = @(phase);
        return changed;
    }
}
// 网络完成回调和保存终态分开消费，避免成功下载后的取消重复通知调用者。
static inline BOOL DYYYDownloadTakeCallback(NSMutableDictionary *state) {
    @synchronized (state) {
        if (!state || [state[@"callbackTaken"] boolValue]) return NO;
        state[@"callbackTaken"] = @YES;
        return YES;
    }
}

// 统一调用真实任务的取消接口；在外层状态全部标记后执行，避免同步回调看到半取消批次。
static inline void DYYYDownloadCancelTasks(NSArray<NSURLSessionTask *> *tasks) {
    for (NSURLSessionTask *task in tasks) [task cancel];
}

// 最后的保存动作与取消共用同一把锁；先拿到锁并创建请求的一方定义事务提交边界。
static inline BOOL DYYYDownloadPerformIfActive(NSMutableDictionary *state, void (^action)(void)) {
    if (!action) return NO;
    if (!state) { action(); return YES; }
    @synchronized (state) {
        if (!DYYYDownloadIsActive([state[@"phase"] unsignedIntegerValue])) return NO;
        action();
        return YES;
    }
}

// 单任务只选择自己的网络子任务；取消全部时由管理器逐个调用同一入口。
static inline NSArray<NSString *> *DYYYDownloadTaskIDsForOwner(NSString *ownerID, NSDictionary<NSString *, NSString *> *ownerMap) {
    return ownerID.length ? [ownerMap allKeysForObject:ownerID] : @[];
}
