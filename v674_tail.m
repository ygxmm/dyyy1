// ==================== 详情页几何（v674 重构） ====================
// 只保留三条规则，删掉之前层层叠加的补丁：
//   1) 底栏 60pt 的 bottom 约束归零 —— 每轮布局都重做（原生会在底栏更新时改回去）；
//   2) 表高落后于满屏时补高 —— 约束零化没覆盖到的兜底；
//   3) 打开后按 initialIndex × 行高归位偏移 —— 原生是在表还是 792 时算的偏移，
//      且详情列表分页加载（rows 21→33→69→93），目标索引没加载出来时要等，不能放弃。
// 行高不再硬改：实测 cell 高度始终跟随表格 bounds（delegate 是 BSTTableViewDelegateOptProxy）。

static char kDYYYOpenIdxKey;
static char kDYYYOpenDeadlineKey;
static char kDYYYOpenAppliedKey;
static char kDYYYOpenBusyKey;

static long long DYYYVCLLValue(UIViewController *vc, NSString *key) {
    @try {
        id v = [vc valueForKey:key];
        if ([v respondsToSelector:@selector(longLongValue)]) return [v longLongValue];
    } @catch (NSException *e) {}
    return -1;
}

static UITableView *DYYYDetailTable(UIViewController *vc) {
    if (!vc) return nil;
    SEL tsel = NSSelectorFromString(@"tableView");
    if (![vc respondsToSelector:tsel]) return nil;
    id tv = ((id (*)(id, SEL))[vc methodForSelector:tsel])(vc, tsel);
    return [tv isKindOfClass:[UITableView class]] ? (UITableView *)tv : nil;
}

// 规则 1：底栏 60pt 约束归零。原生会在底栏更新/评论等时机把常量改回 -60，
// 所以每次布局都重做，不再用一次性标记。
static void DYYYDetailZeroBottomConstraint(UIViewController *vc) {
    if (![NSThread isMainThread] || !DYYYGetBoolCached(@"DYYYEnableFullScreen")) return;
    UITableView *table = DYYYDetailTable(vc);
    if (!table) return;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    if (table.bounds.size.height >= screenH - 1.0) return;
    NSMutableArray *pools = [NSMutableArray arrayWithObject:table.constraints];
    if (table.superview) [pools addObject:table.superview.constraints];
    if (table.superview.superview) [pools addObject:table.superview.superview.constraints];
    for (NSArray *pool in pools) {
        for (NSLayoutConstraint *c in pool) {
            if (c.firstItem != table && c.secondItem != table) continue;
            if (c.firstAttribute != NSLayoutAttributeBottom &&
                c.secondAttribute != NSLayoutAttributeBottom) continue;
            if (fabs(c.constant) > 1.0) c.constant = 0;
        }
    }
}

// 规则 2：表高落后时补高。只在满屏父视图、非手势、无变换时动手。
static void DYYYDetailSyncTableHeight(UIViewController *vc) {
    if (![NSThread isMainThread] || !DYYYGetBoolCached(@"DYYYEnableFullScreen")) return;
    UITableView *table = DYYYDetailTable(vc);
    if (!table || !table.window || !CGAffineTransformIsIdentity(table.transform)) return;
    if (table.tracking || table.dragging || table.decelerating) return;
    CGFloat target = 0;
    UIView *sv = table.superview;
    if (sv && sv.bounds.size.height > 0) target = sv.bounds.size.height;
    else if (vc.viewIfLoaded) target = vc.viewIfLoaded.bounds.size.height;
    if (target < 500.0) return;
    if (fabs(target - [UIScreen mainScreen].bounds.size.height) > 1.0) return;
    CGFloat height = table.frame.size.height;
    if (height >= target - 0.5) return;
    if (height < target * 0.5) return;

    // 表从 792 抬到 852 的瞬间，把按 792 排好的偏移换算成 852 基，
    // 判据：旧高度下正好整页对齐、新高度下不对齐。
    CGFloat off = table.contentOffset.y;
    if (off > 1.0 && height > 400.0) {
        CGFloat pages = off / height;
        CGFloat nearest = (CGFloat)llround(pages);
        BOOL alignedOld = fabs(pages - nearest) < 0.02;
        BOOL alignedNew = fabs(off / target - (CGFloat)llround(off / target)) < 0.02;
        if (alignedOld && !alignedNew) {
            table.contentOffset = CGPointMake(0, nearest * target);
        }
    }

    CGRect frame = table.frame;
    frame.size.height = target;
    table.frame = frame;
}

// 规则 3：把打开落点归位到 initialIndex。
static void DYYYDetailFixInitialOffset(UIViewController *vc) {
    NSNumber *idxNum = objc_getAssociatedObject(vc, &kDYYYOpenIdxKey);
    NSNumber *dlNum = objc_getAssociatedObject(vc, &kDYYYOpenDeadlineKey);
    if (!idxNum || !dlNum) return;
    UITableView *table = DYYYDetailTable(vc);
    if (!table || !table.window) return;

    // 手指按下/拖动 = 用户接管，放弃；decelerating 可能只是原生自己的初始滚动，等它停下。
    if (table.tracking || table.dragging) {
        objc_setAssociatedObject(vc, &kDYYYOpenIdxKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (table.decelerating) return;
    if (CACurrentMediaTime() > dlNum.doubleValue) {
        objc_setAssociatedObject(vc, &kDYYYOpenIdxKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    CGFloat h = table.rowHeight;
    if (h < 400.0) return;
    if (table.bounds.size.height + 1.0 < h) return;   // 还没撑满

    long long idx = idxNum.longLongValue;
    NSInteger count = [table numberOfRowsInSection:0];
    if (idx <= 0) {
        objc_setAssociatedObject(vc, &kDYYYOpenIdxKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (count <= 0) return;
    // 详情列表分页加载：目标索引还没加载出来时必须等，不能当成非法索引清掉。
    if (idx >= count) return;

    CGFloat off = table.contentOffset.y;
    if (fabs(off / h - (CGFloat)idx) <= 0.5) return;

    NSNumber *applied = objc_getAssociatedObject(vc, &kDYYYOpenAppliedKey);
    if (applied.integerValue >= 4) return;
    objc_setAssociatedObject(vc, &kDYYYOpenAppliedKey, @(applied.integerValue + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 优先原生接口：会同时更新偏移、currentVisibleCellIndex 和播放器。
    SEL usel = NSSelectorFromString(@"updateTableViewLayoutForTargetPageIndex:");
    if ([vc respondsToSelector:usel] && objc_getAssociatedObject(vc, &kDYYYOpenBusyKey) == nil) {
        objc_setAssociatedObject(vc, &kDYYYOpenBusyKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, long long))[vc methodForSelector:usel])(vc, usel, idx);
        objc_setAssociatedObject(vc, &kDYYYOpenBusyKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (fabs(table.contentOffset.y / h - (CGFloat)idx) <= 0.5) return;
    }
    [table setContentOffset:CGPointMake(0, (CGFloat)idx * h) animated:NO];
}

static void DYYYDetailRecordInitialIndex(UIViewController *vc) {
    if (objc_getAssociatedObject(vc, &kDYYYOpenIdxKey) != nil) return;
    long long init = DYYYVCLLValue(vc, @"initialIndex");
    if (init <= 0) return;
    objc_setAssociatedObject(vc, &kDYYYOpenIdxKey, @(init), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(vc, &kDYYYOpenDeadlineKey, @(CACurrentMediaTime() + 8.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ==================== 详情页 Hook ====================
%group DYYYDetailHeightHook

%hook AWEAwemeDetailTableViewController

- (void)viewWillLayoutSubviews {
    %orig;
    DYYYDetailZeroBottomConstraint(self);
    DYYYDetailSyncTableHeight(self);
    DYYYDetailRecordInitialIndex(self);
    DYYYDetailFixInitialOffset(self);
}

// 有的入口通过这个方法下发起始索引，提前记下来。
- (void)pi_setupWithInitialIndex:(long long)index {
    %orig;
    if (index > 0 && objc_getAssociatedObject(self, &kDYYYOpenIdxKey) == nil) {
        objc_setAssociatedObject(self, &kDYYYOpenIdxKey, @(index), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &kDYYYOpenDeadlineKey, @(CACurrentMediaTime() + 8.0), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    DYYYDetailZeroBottomConstraint(self);
    DYYYDetailSyncTableHeight(self);
    DYYYDetailRecordInitialIndex(self);
    DYYYDetailFixInitialOffset(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    // 原生可能在出现动画结束后才写完初始偏移 → 稍后再补两次。
    __weak UIViewController *weakVC = self;
    for (double delay in @[@0.35, @1.0, @2.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *vc = weakVC;
            if (!vc) return;
            DYYYDetailSyncTableHeight(vc);
            DYYYDetailFixInitialOffset(vc);
        });
    }
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
