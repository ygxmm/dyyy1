// ===== v670 探针：行高到底由谁提供 =====
// 五份快照显示 cell 一直是 792，而表被我们撑到 852 → 分页按 852 吸附、行按 792 排，
// 每页漂 60pt。这里记录原生返回值、我们返回值，以及表的 delegate/dataSource 到底是谁。
static void DYYYProbeRowLine(NSString *line) {
    if (line.length == 0) return;
    static NSMutableSet *seen; static dispatch_once_t once;
    dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
    @synchronized (seen) {
        if (seen.count > 40 || [seen containsObject:line]) return;
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

static NSString *DYYYProbeClassName(id obj) {
    if (!obj) return @"nil";
    return NSStringFromClass([obj class]);
}

static void DYYYProbeRowInfo(UITableView *table, NSString *src, double nativeH, double retH) {
    if (!table) return;
    NSString *line = [NSString stringWithFormat:@"[ROW] src=%@ native=%.1f ret=%.1f rowH=%.1f est=%.1f boundsH=%.0f del=%@ ds=%@",
        src, nativeH, retH, table.rowHeight, table.estimatedRowHeight,
        table.bounds.size.height,
        DYYYProbeClassName(table.delegate), DYYYProbeClassName(table.dataSource)];
    DYYYProbeRowLine(line);
}

static void DYYYProbeDetailGeometry(UIViewController *vc, UITableView *table) {
    if (!table || table.window == nil) return;
    NSString *cellH = @"-";
    if ([table numberOfSections] > 0 && [table numberOfRowsInSection:0] > 0) {
        @try {
            CGRect r = [table rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
            cellH = [NSString stringWithFormat:@"%.0f", r.size.height];
        } @catch (NSException *e) {}
    }
    NSString *line = [NSString stringWithFormat:@"[DETAILINFO] rowH=%.1f est=%.1f boundsH=%.0f off=%.1f cell0=%@ rows=%ld del=%@ ds=%@",
        table.rowHeight, table.estimatedRowHeight, table.bounds.size.height, table.contentOffset.y, cellH,
        (long)[table numberOfRowsInSection:0],
        DYYYProbeClassName(table.delegate), DYYYProbeClassName(table.dataSource)];
    DYYYProbeRowLine(line);
}

