// ===== v666：参考 DYKiller —— 原生算分页之前就把详情表撑到满高 =====
// 实测原生按表格当时的高度算偏移（idx × 792），行高却被统一成 852，
// 于是落点 = idx × 792 / 852。DYKiller 的做法是在表的尺寸写入入口
// 直接把「被底栏压掉 60pt」的高度改成满高，让原生自己算出来的分页从一开始就对。
static BOOL DYYYStretchTableHeightValue(CGFloat current, CGFloat target, CGFloat *out) {
    if (!isfinite(current) || !isfinite(target)) return NO;
    if (target <= 0.5 || current <= 0.5) return NO;
    if (current >= target - 0.5) return NO;   // 已经满高
    if (current < target * 0.5) return NO;    // 布局早期半成品 / 评论区缩小态，别碰
    *out = target;
    return YES;
}

static BOOL DYYYPrepareDetailTable(UIViewController *vc) {
    if (!vc || !DYYYGetBoolCached(@"DYYYEnableFullScreen")) return NO;
    if (![NSThread isMainThread]) return NO;
    if (![vc respondsToSelector:@selector(tableView)]) return NO;
    UITableView *table = [vc tableView];
    if (!table || !CGAffineTransformIsIdentity(table.transform)) return NO;
    if ([DYYYFullscreenCoordinator hasCommentInWindow:table.window]) return NO;
    CGFloat target = 0;
    UIView *sv = table.superview;
    if (sv && sv.bounds.size.height > 0.5) {
        target = sv.bounds.size.height;
    } else {
        UIView *root = vc.viewIfLoaded;
        if (root && root.bounds.size.height > 0.5) target = root.bounds.size.height;
    }
    CGFloat stretched = 0;
    if (!DYYYStretchTableHeightValue(table.frame.size.height, target, &stretched)) return NO;
    CGRect frame = table.frame;
    frame.size.height = stretched;
    table.frame = frame;
    return YES;
}

%hook AWEAwemeDetailTableView

- (void)setFrame:(CGRect)frame {
    if (DYYYGetBoolCached(@"DYYYEnableFullScreen") && [NSThread isMainThread] &&
        CGAffineTransformIsIdentity(self.transform) && !self.dragging && !self.tracking &&
        ![DYYYFullscreenCoordinator hasCommentInWindow:self.window]) {
        CGFloat target = 0;
        UIView *sv = self.superview;
        if (sv && sv.bounds.size.height > 0.5) {
            target = sv.bounds.size.height;
        } else {
            UIWindow *win = self.window;
            if (win && fabs(frame.size.width - win.bounds.size.width) < 1.0) target = win.bounds.size.height;
        }
        CGFloat stretched = 0;
        if (DYYYStretchTableHeightValue(CGRectGetHeight(frame), target, &stretched)) {
            frame.size.height = stretched;
        }
    }
    %orig(frame);
}

%end
