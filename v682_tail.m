// ==================== 详情页几何（v682 收口） ====================
// 只保留三条规则，不再往上叠：
//   1) 表 = 满屏：底栏 60pt 约束归零，布局后仍矮时补高；
//   2) 行高 = 表高：原生返回「表高 − 60」时归一，其它值放行；
//   3) 打开阶段的偏移写入按表高换算（792 基 → 852 基），不做任何事后纠正。
// 之前那些「写完之后再改」的补位全部删掉——拉拽感就是它们造成的。

static char kDYYYDetailConstraintKey;

static UITableView *DYYYDetailTable(UIViewController *vc) {
    if (!vc) return nil;
    SEL tsel = NSSelectorFromString(@"tableView");
    if (![vc respondsToSelector:tsel]) return nil;
    id tv = ((id (*)(id, SEL))[vc methodForSelector:tsel])(vc, tsel);
    return [tv isKindOfClass:[UITableView class]] ? (UITableView *)tv : nil;
}

// 规则 1a：底栏 60pt 约束归零。原生会改回 -60，所以每次布局都重做（约束只找一次，缓存）。
static void DYYYDetailZeroBottomConstraint(UIViewController *vc) {
    if (![NSThread isMainThread] || !DYYYGetBoolCached(@"DYYYEnableFullScreen")) return;
    UITableView *table = DYYYDetailTable(vc);
    if (!table) return;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    if (table.bounds.size.height >= screenH - 1.0) return;
    NSArray *cached = objc_getAssociatedObject(table, &kDYYYDetailConstraintKey);
    if (!cached) {
        NSMutableArray *found = [NSMutableArray array];
        NSMutableArray *pools = [NSMutableArray arrayWithObject:table.constraints];
        if (table.superview) [pools addObject:table.superview.constraints];
        if (table.superview.superview) [pools addObject:table.superview.superview.constraints];
        for (NSArray *pool in pools) {
            for (NSLayoutConstraint *c in pool) {
                if (c.firstItem != table && c.secondItem != table) continue;
                if (c.firstAttribute != NSLayoutAttributeBottom &&
                    c.secondAttribute != NSLayoutAttributeBottom) continue;
                [found addObject:c];
            }
        }
        cached = found;
        objc_setAssociatedObject(table, &kDYYYDetailConstraintKey, found, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (NSLayoutConstraint *c in cached) {
        if (fabs(c.constant) > 1.0) c.constant = 0;
    }
}

// 规则 1b：约束没覆盖到时，布局后直接把表补到满屏。
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
    if (table.frame.size.height >= target - 0.5) return;
    if (table.frame.size.height < target * 0.5) return;   // 转场早期半成品不动
    CGRect frame = table.frame;
    frame.size.height = target;
    table.frame = frame;
}

// 规则 2：行高归一化。只把「表高 − 60」（典型 792）改成表高，其它值原样返回。
static double DYYYDetailRowHeight(UITableView *table, double nativeH) {
    if (!table || !DYYYGetBoolCached(@"DYYYEnableFullScreen")) return nativeH;
    CGFloat target = table.bounds.size.height;
    if (target < 400.0 || !isfinite(nativeH)) return nativeH;
    if (fabs(nativeH - target) <= 0.5) return nativeH;
    if (fabs(nativeH - (target - 60.0)) <= 0.5) return target;
    return nativeH;
}

// ==================== 详情页 Hook ====================
%group DYYYDetailHeightHook

%hook AWEAwemeDetailTableViewController

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    // 页面显示前就把表撑到满屏并让约束生效，行随后按 852 建，不需要任何事后补位。
    DYYYDetailZeroBottomConstraint(self);
    [DYYYDetailTable(self) layoutIfNeeded];
    DYYYDetailSyncTableHeight(self);
}

- (void)viewWillLayoutSubviews {
    %orig;
    DYYYDetailZeroBottomConstraint(self);
    DYYYDetailSyncTableHeight(self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    DYYYDetailZeroBottomConstraint(self);
    DYYYDetailSyncTableHeight(self);
}

- (double)tableView:(id)a0 heightForRowAtIndexPath:(id)a1 {
    double nativeH = %orig;
    if ([a0 isKindOfClass:[UITableView class]]) return DYYYDetailRowHeight((UITableView *)a0, nativeH);
    return nativeH;
}

- (double)cellHeight {
    return DYYYDetailRowHeight([self tableView], %orig);
}

- (double)fixedCellHeight {
    return DYYYDetailRowHeight([self tableView], %orig);
}

- (double)cellHeightAtIndex:(long long)index {
    return DYYYDetailRowHeight([self tableView], %orig);
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
