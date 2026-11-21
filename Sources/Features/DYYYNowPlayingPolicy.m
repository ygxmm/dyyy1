#import "DYYYNowPlayingPolicy.h"

@implementation DYYYNowPlayingPolicy {
    NSRecursiveLock *_lock;
    NSMapTable<id, NSMutableDictionary<NSString *, id> *> *_requests;
    NSMutableSet<NSString *> *_applyingKeys;
    NSMutableDictionary<NSString *, id> *_hidden;
    NSMutableDictionary<NSString *, void (^)(id, id)> *_sinks;
    BOOL _suppressed;
}
- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = [NSRecursiveLock new];
        _requests = [NSMapTable weakToStrongObjectsMapTable];
        _applyingKeys = [NSMutableSet set];
        _hidden = [NSMutableDictionary dictionary];
        _sinks = [NSMutableDictionary dictionary];
    }
    return self;
}
- (BOOL)suppressed {
    [_lock lock];
    @try { return _suppressed; } @finally { [_lock unlock]; }
}
- (BOOL)hasRequestForChannel:(NSString *)channel owner:(id)owner {
    if (!owner || !channel.length) return NO;
    [_lock lock];
    @try { return [_requests objectForKey:owner][channel] != nil; } @finally { [_lock unlock]; }
}
- (BOOL)configureChannel:(NSString *)channel hiddenValue:(id)value sink:(void (^)(id, id))sink {
    if (!channel.length || !sink) return NO;
    [_lock lock];
    @try {
        _hidden[channel] = value ?: NSNull.null;
        _sinks[channel] = [sink copy];
        return YES;
    } @finally { [_lock unlock]; }
}
- (void)deliverValue:(id)value owner:(id)owner channel:(NSString *)channel sink:(void (^)(id, id))sink {
    NSString *key = [NSString stringWithFormat:@"%p|%@", owner, channel];
    if ([_applyingKeys containsObject:key]) return;
    [_applyingKeys addObject:key];
    @try { sink(owner, value == NSNull.null ? nil : value); }
    @finally { [_applyingKeys removeObject:key]; }
}
- (void)recordValue:(id)value owner:(id)owner channel:(NSString *)channel onlyIfMissing:(BOOL)seed {
    if (!owner) return;
    [_lock lock];
    @try {
        BOOL policyCascade = _applyingKeys.count > 0;
        void (^sink)(id, id) = _sinks[channel];
        if (!sink) return;
        NSMutableDictionary *record = [_requests objectForKey:owner];
        if (!record) {
            record = [NSMutableDictionary dictionary];
            [_requests setObject:record forKey:owner];
        }
        if (seed && !policyCascade && record[channel]) return;
        // 策略写回时跨setter触发的宿主副作用不能覆盖最新原生恢复快照。
        if (!policyCascade) {
            id snapshot = [value isKindOfClass:NSDictionary.class] ? [value copy] : value;
            record[channel] = snapshot ?: NSNull.null;
            // 初始化快照只观察原值；开关关闭时不重复触发系统发布副作用。
            if (seed && !_suppressed) return;
        }
        id output = _suppressed ? _hidden[channel] : (policyCascade ? value : record[channel]);
        [self deliverValue:output owner:owner channel:channel sink:sink];
    } @finally { [_lock unlock]; }
}
- (void)writeValue:(id)value owner:(id)owner channel:(NSString *)channel {
    [self recordValue:value owner:owner channel:channel onlyIfMissing:NO];
}
- (void)seedValue:(id)value owner:(id)owner channel:(NSString *)channel {
    [self recordValue:value owner:owner channel:channel onlyIfMissing:YES];
}
- (void)forgetOwner:(id)owner {
    [_lock lock];
    @try { [_requests removeObjectForKey:owner]; } @finally { [_lock unlock]; }
}
- (BOOL)setSuppressed:(BOOL)suppressed {
    [_lock lock];
    @try {
        if (_suppressed == suppressed) return NO;
        _suppressed = suppressed;
        NSArray *order = suppressed ? @[@"session-eligible", @"session-auto", @"controller-auto", @"metadata", @"content-item", @"session-base", @"session-info", @"state"] :
                                     @[@"metadata", @"content-item", @"session-base", @"session-info", @"state", @"session-auto", @"session-eligible", @"controller-auto"];
        NSArray *owners = _requests.keyEnumerator.allObjects;
        for (NSString *channel in order) {
            for (id owner in owners) {
                id requested = [_requests objectForKey:owner][channel];
                void (^sink)(id, id) = _sinks[channel];
                if (!requested || !sink) continue;
                id value = _suppressed ? _hidden[channel] : requested;
                [self deliverValue:value owner:owner channel:channel sink:sink];
            }
        }
        return YES;
    } @finally { [_lock unlock]; }
}
@end
