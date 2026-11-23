// 确定性调度缝：只替换此 TU 的 async/after，不改 runtime，真实 block 原样执行。
// 外层 harness 捕捉故意抛出的 getter 异常，避免 libdispatch 未捕获异常终止 CI。
static NSMutableArray<dispatch_block_t> *DYYYTestImmediateBlocks;
static NSMutableArray<dispatch_block_t> *DYYYTestDelayedBlocks;
static void DYYYTestDispatchAsync(dispatch_queue_t queue, dispatch_block_t block) {
    (void)queue; [DYYYTestImmediateBlocks addObject:[block copy]];
}
static void DYYYTestDispatchAfter(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    (void)when; (void)queue; [DYYYTestDelayedBlocks addObject:[block copy]];
}
static NSException *DYYYTestDrainOne(BOOL delayed) {
    NSMutableArray<dispatch_block_t> *queue = delayed ? DYYYTestDelayedBlocks : DYYYTestImmediateBlocks;
    if (!queue.count) return nil;
    dispatch_block_t block = queue.firstObject;
    [queue removeObjectAtIndex:0];
    @try { block(); } @catch (NSException *exception) { return exception; }
    return nil;
}
