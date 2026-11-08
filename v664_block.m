// ===== v664：打开落点探针 + 起始索引校正（日志同上 Documents/dyyy_ui.log） =====
static char kDYYYOpenIdxKey;
static char kDYYYOpenDeadlineKey;
static char kDYYYOpenLoggedKey;
static char kDYYYOpenAppliedKey;

static void DYYYProbePagerLine(NSString *line) {
    if (line.length == 0) return;
    static NSMutableSet *seen; static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    @synchronized (seen) {
        if (seen.count > 60 || [seen containsObject:line]) return;
        [seen addObject:line];
    }
    @autoreleasepool {
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/dyyy_ui.log"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        }
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) return;
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (NSException *e) {}
        [fh closeFile];
    }
}

static long long DYYYVCLLValue(UIViewController *vc, NSString *key) {
    @try {
        id v = [vc valueForKey:key];
        if ([v respondsToSelector:@selector(longLongValue)]) return [v longLongValue];
    } @catch (NSException *e) {}
    return -1;
}

static id DYYYVCViewModelAt(UIViewController *vc, UITableView *table, long long idx) {
    SEL nsel = NSSelectorFromString(@"dataSourceModelForIndexPath:");
    if (!vc || !table || ![vc respondsToSelector:nsel]) return nil;
    NSInteger count = 0;
    @try { count = [table numberOfRowsInSection:0]; } @catch (NSException *e) { return nil; }
    if (idx < 0 || idx >= count) return nil;
    @try {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:(NSInteger)idx inSection:0];
        return ((id (*)(id, SEL, id))[vc methodForSelector:nsel])(vc, nsel, ip);
    } @catch (NSException *e) { return nil; }
}

// 打印某条目的 awemeId + 文案前 18 字，用户可直接对照点开的是哪一条
static NSString *DYYYAwemeBriefAt(UIViewController *vc, UITableView *table, long long idx) {
    if (!table) return @"-";
    if (idx < 0) return @"neg";
    NSInteger count = 0;
    @try { count = [table numberOfRowsInSection:0]; } @catch (NSException *e) { return @"?"; }
    if (idx >= count) return @"oob";
    id model = DYYYVCViewModelAt(vc, table, idx);
    if (!model) return @"nil";
    NSString *aid = @"?";
    NSString *desc = @"";
    @try {
        id v = [model valueForKey:@"awemeId"];
        if ([v isKindOfClass:[NSString class]]) aid = v;
    } @catch (NSException *e) {}
    @try {
        id d = [model valueForKey:@"desc"];
        if ([d isKindOfClass:[NSString class]]) desc = d;
    } @catch (NSException *e) {}
    if (desc.length > 18) desc = [desc substringToIndex:18];
    desc = [desc stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    return [NSString stringWithFormat:@"%@|%@", aid, desc];
}

// v664：原生在表格还是 792 时就算好了初始偏移，之后行高被我们改成 852，
// 偏移没有换算 → 打开后落点前移若干条。这里按 initialIndex × 行高纠正一次。
static void DYYYReconcileOpenIndex(UIViewController *vc, NSString *phase) {
    NSNumber *idxNum = objc_getAssociatedObject(vc, &kDYYYOpenIdxKey);
    NSNumber *dlNum = objc_getAssociatedObject(vc, &kDYYYOpenDeadlineKey);
    if (!idxNum || !dlNum) return;
    SEL tsel = NSSelectorFromString(@"tableView");
    if (![vc respondsToSelector:tsel]) return;
    id tv = ((id (*)(id, SEL))[vc methodForSelector:tsel])(vc, tsel);
    if (![tv isKindOfClass:[UITableView class]]) return;
    UITableView *t = (UITableView *)tv;
    if (t.window == nil) return;
    if (t.tracking || t.dragging || t.decelerating) {
        objc_setAssociatedObject(vc, &kDYYYOpenIdxKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DYYYProbePagerLine([NSString stringWithFormat:@"[OPENX] %@ 用户已滚动，放弃校正", phase]);
        return;
    }
    if (CACurrentMediaTime() > dlNum.doubleValue) {
        objc_setAssociatedObject(vc, &kDYYYOpenIdxKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DYYYProbePagerLine([NSString stringWithFormat:@"[OPENX] %@ 超时放弃", phase]);
        return;
    }
    CGFloat h = t.rowHeight;
    if (h < 400.0) return;
    if (t.bounds.size.height + 1.0 < h) return;   // 还没撑满全屏
    long long idx = idxNum.longLongValue;
    NSInteger count = [t numberOfRowsInSection:0];
    if (idx <= 0 || idx >= count) {
        objc_setAssociatedObject(vc, &kDYYYOpenIdxKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    CGFloat off = t.contentOffset.y;
    CGFloat offsetIdx = off / h;
    if (fabs(offsetIdx - (CGFloat)idx) <= 0.5) return;   // 已经对上了（或只差半条以内）
    NSNumber *applied = objc_getAssociatedObject(vc, &kDYYYOpenAppliedKey);
    if (applied.integerValue >= 4) return;
    objc_setAssociatedObject(vc, &kDYYYOpenAppliedKey, @(applied.integerValue + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat targetY = (CGFloat)idx * h;
    DYYYProbePagerLine([NSString stringWithFormat:@"[OPENFIX] %@ init=%lld off=%.1f(%.2f条) -> %.1f h=%.0f idOff=%@ idTarget=%@",
        phase, idx, off, offsetIdx, targetY, h,
        DYYYAwemeBriefAt(vc, t, (long long)llround(offsetIdx)),
        DYYYAwemeBriefAt(vc, t, idx)]);
    [t setContentOffset:CGPointMake(0, targetY) animated:NO];
}
