// v668: 回到原版 Wtrwx/DYYY 的最小方案 —— 不硬改行高，交给原生按表格自身高度算；
// 表格撑满后由 reconcileDetailPaging 用 currentVisibleCellIndex 重新下发分页，
// 偏移 / 播放器 / cell 三者始终一致。
// 之前的坑：只把 rowHeight 改成 852，原生算初始偏移时用的还是 792 → 打开错条。
static void DYYYEarlyZeroDetailTableConstraint(UIViewController *vc) {
    if (![NSThread isMainThread]) return;
    if (!DYYYGetBoolCached(@"DYYYEnableFullScreen")) return;
    SEL tsel = NSSelectorFromString(@"tableView");
    if (![vc respondsToSelector:tsel]) return;
    id tv = ((id (*)(id, SEL))[vc methodForSelector:tsel])(vc, tsel);
    if (![tv isKindOfClass:[UITableView class]]) return;
    UITableView *table = (UITableView *)tv;
    CGFloat screenH = [UIScreen mainScreen].bounds.size.height;
    if (table.bounds.size.height >= screenH - 1.0) return;
    if (objc_getAssociatedObject(table, &kDYYYV29DoneKey)) return;
    BOOL changed = NO;
    NSMutableArray *pools = [NSMutableArray arrayWithObject:table.constraints];
    if (table.superview) [pools addObject:table.superview.constraints];
    if (table.superview.superview) [pools addObject:table.superview.superview.constraints];
    for (NSArray *pool in pools) {
        for (NSLayoutConstraint *c in pool) {
            if (c.firstItem != table && c.secondItem != table) continue;
            if (c.firstAttribute != NSLayoutAttributeBottom &&
                c.secondAttribute != NSLayoutAttributeBottom) continue;
            if (fabs(c.constant) > 1.0) {
                c.constant = 0;
                changed = YES;
            }
        }
    }
    if (changed) {
        objc_setAssociatedObject(table, &kDYYYV29DoneKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// ==================== v457: 作品详情页高度统一 852 ====================
%group DYYYDetailHeightHook

%hook AWEAwemeDetailTableViewController

- (void)viewWillLayoutSubviews {
    %orig;
    // 把底栏那 60pt 的 bottom 约束归零，表格撑满整屏。
    DYYYEarlyZeroDetailTableConstraint(self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    // 原版的关键一步：行高缓存还是 792 时重建行，并让原生按 currentVisibleCellIndex
    // 重新下发分页偏移（内部调用 updateTableViewLayoutForTargetPageIndex:）。
    [DYYYFullscreenCoordinator reconcileDetailPaging:self];
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [DYYYFullscreenCoordinator reconcileDetailPaging:self];
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
