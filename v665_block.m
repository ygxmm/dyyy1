// ===== v665：打开落点校正 =====
// 实测：原生在表格还按 792 排版时就算好了初始偏移（idx × 792），
// 而行高被我们统一成 852 → 落点 = idx × 792 / 852，条目越多偏得越远。
// 这里记下原生下发的起始索引，等表格真正撑到 852 后按 idx × 行高补位。
static char kDYYYOpenIdxKey;
static char kDYYYOpenDeadlineKey;
static char kDYYYOpenAppliedKey;

static long long DYYYVCLLValue(UIViewController *vc, NSString *key) {
    @try {
        id v = [vc valueForKey:key];
        if ([v respondsToSelector:@selector(longLongValue)]) return [v longLongValue];
    } @catch (NSException *e) {}
    return -1;
}

static void DYYYReconcileOpenIndex(UIViewController *vc) {
    NSNumber *idxNum = objc_getAssociatedObject(vc, &kDYYYOpenIdxKey);
    NSNumber *dlNum = objc_getAssociatedObject(vc, &kDYYYOpenDeadlineKey);
    if (!idxNum || !dlNum) return;
    SEL tsel = NSSelectorFromString(@"tableView");
    if (![vc respondsToSelector:tsel]) return;
    id tv = ((id (*)(id, SEL))[vc methodForSelector:tsel])(vc, tsel);
    if (![tv isKindOfClass:[UITableView class]]) return;
    UITableView *t = (UITableView *)tv;
    if (t.window == nil) return;

    // 手指按下/拖动 = 用户接管，放弃；decelerating 可能只是原生自己的初始滚动，等它停下
    if (t.tracking || t.dragging) {
        objc_setAssociatedObject(vc, &kDYYYOpenIdxKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (t.decelerating) return;
    if (CACurrentMediaTime() > dlNum.doubleValue) {
        objc_setAssociatedObject(vc, &kDYYYOpenIdxKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    CGFloat h = t.rowHeight;
    if (h < 400.0) return;
    if (t.bounds.size.height + 1.0 < h) return;   // 还没撑满全屏

    long long idx = idxNum.longLongValue;
    NSInteger count = [t numberOfRowsInSection:0];
    if (idx <= 0) {
        objc_setAssociatedObject(vc, &kDYYYOpenIdxKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (count <= 0) return;                        // 数据还没到，先别放弃
    if (idx >= count) {
        objc_setAssociatedObject(vc, &kDYYYOpenIdxKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    CGFloat off = t.contentOffset.y;
    if (fabs(off / h - (CGFloat)idx) <= 0.5) return;   // 已经对上（或只差半条以内）

    NSNumber *applied = objc_getAssociatedObject(vc, &kDYYYOpenAppliedKey);
    if (applied.integerValue >= 4) return;
    objc_setAssociatedObject(vc, &kDYYYOpenAppliedKey, @(applied.integerValue + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [t setContentOffset:CGPointMake(0, (CGFloat)idx * h) animated:NO];
}

// ==================== v457: 作品详情页高度统一 852 ====================
%group DYYYDetailHeightHook

%hook AWEAwemeDetailTableViewController


- (void)viewWillLayoutSubviews {
    %orig;
    // v660: 首次布局前归零 bottom 约束 → 表格尽快撑到 852。
    DYYYEarlyZeroDetailTableConstraint(self);

    // v665: 记下原生下发的起始索引（此时表格可能还没撑满，等下一轮再补位）。
    if (objc_getAssociatedObject(self, &kDYYYOpenIdxKey) == nil) {
        long long init = DYYYVCLLValue(self, @"initialIndex");
        if (init > 0) {
            objc_setAssociatedObject(self, &kDYYYOpenIdxKey, @(init), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, &kDYYYOpenDeadlineKey, @(CACurrentMediaTime() + 2.5), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    DYYYReconcileOpenIndex(self);
}

// 有的入口是通过这个方法下发起始索引的，一并记录。
- (void)pi_setupWithInitialIndex:(long long)index {
    %orig;
    if (index > 0 && objc_getAssociatedObject(self, &kDYYYOpenIdxKey) == nil) {
        objc_setAssociatedObject(self, &kDYYYOpenIdxKey, @(index), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kDYYYOpenDeadlineKey, @(CACurrentMediaTime() + 2.5), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    DYYYReconcileOpenIndex(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // 原生可能在出现动画结束后才写完初始偏移 → 稍后再补一次。
    __weak UIViewController *weakVC = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *vc = weakVC;
        if (vc) DYYYReconcileOpenIndex(vc);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *vc = weakVC;
        if (vc) DYYYReconcileOpenIndex(vc);
    });
}

- (double)tableView:(id)a0 heightForRowAtIndexPath:(id)a1 {
    if (DYYYGetBoolCached(@"DYYYEnableFullScreen") && [a0 isKindOfClass:[UITableView class]]) {
        return DYYYDetailPageHeight((UITableView *)a0);
    }
    return %orig;
}

- (double)cellHeight {
    if (DYYYGetBoolCached(@"DYYYEnableFullScreen")) {
        return DYYYDetailPageHeight([self tableView]);
    }
    return %orig;
}

- (double)fixedCellHeight {
    if (DYYYGetBoolCached(@"DYYYEnableFullScreen")) {
        return DYYYDetailPageHeight([self tableView]);
    }
    return %orig;
}

- (double)cellHeightAtIndex:(long long)index {
    if (DYYYGetBoolCached(@"DYYYEnableFullScreen")) {
        return DYYYDetailPageHeight([self tableView]);
    }
    return %orig;
}

- (double)baseTableViewBottomInset {
    double inset = %orig;
    return [DYYYFullscreenCoordinator bottomInsetForDetail:inset controller:self];
}

%end

%end



%hook AWEAwemePlayVideoViewController

%end


%ctor {
    %init(DYYYDetailHeightHook);
}
