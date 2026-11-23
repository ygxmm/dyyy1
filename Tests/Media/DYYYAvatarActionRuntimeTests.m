// macOS Foundation + QuartzCore + UIKit 测试 double 状态回归。
// 不证明真实 UIKit 渲染、hitTest、Logos 安装、私有 getter 或真机点击通过。
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <stdio.h>
#include <math.h>

static NSMutableDictionary<NSString *, NSNumber *> *DYYYTestSettings;
static uint32_t DYYYTestSettingsGeneration;
static BOOL DYYYTestGetBoolCached(NSString *key) { return [DYYYTestSettings[key] boolValue]; }
#import "Support/DYYYAvatarRuntimeDispatch.inc"
// 设置和调度只在独立 TU 中隔离；没有修改 defaults 或生产宏/全局变量。
#define DYYYGetBoolCached DYYYTestGetBoolCached
#define gDYYYSettingsGeneration DYYYTestSettingsGeneration
#define dispatch_async DYYYTestDispatchAsync
#define dispatch_after DYYYTestDispatchAfter
#import "DYYYAvatarActionRuntime.h"
#undef dispatch_after
#undef dispatch_async
#undef gDYYYSettingsGeneration
#undef DYYYGetBoolCached
#import "Support/DYYYAvatarUIKitDouble.inc"

static int DYYYTestFailures, DYYYTestAssertions;
static const char *DYYYTestCase;
#define CHECK(condition) do { DYYYTestAssertions++; if (!(condition)) { \
    DYYYTestFailures++; printf("FAIL AvatarRuntime/%s:%d %s\n", DYYYTestCase, __LINE__, #condition); \
} } while (0)
static void DYYYTestSet(NSString *key, BOOL value) {
    DYYYTestSettings[key] = @(value);
    __atomic_add_fetch(&DYYYTestSettingsGeneration, 1, __ATOMIC_RELAXED);
}
static void DYYYTestRefresh(void) { DYYYAvatarActionReconcileBoundaries(); }
static DYYYAvatarActionState *State(id object) { return DYYYAvatarActionStateForObject(object); }
static BOOL NativeBool(id object, DYYYAvatarActionProperty property) {
    return [DYYYAvatarActionValue(State(object), property) boolValue];
}
static BOOL NativeNil(id object, DYYYAvatarActionProperty property) {
    return DYYYAvatarActionValue(State(object), property) == NSNull.null;
}
static UIColor *Red(void) { return [UIColor colorWithRed:0.8 green:0.2 blue:0.1 alpha:1]; }
static BOOL ColorEqual(CGColorRef a, CGColorRef b) { return a == b || (a && b && CGColorEqualToColor(a, b)); }
static id TestImage(void) {
    uint8_t pixel[4] = {255, 0, 0, 255};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, space, kCGImageAlphaPremultipliedLast);
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context); CGColorSpaceRelease(space);
    return CFBridgingRelease(image);
}
static void DYYYTestReset(void) {
    if (!DYYYTestSettings) DYYYTestSettings = [NSMutableDictionary dictionary];
    [DYYYTestSettings removeAllObjects];
    __atomic_add_fetch(&DYYYTestSettingsGeneration, 1, __ATOMIC_RELAXED);
    DYYYAvatarActionEnsureTables(); DYYYAvatarActionRefreshTrackedObjects();
    [DYYYAvatarActionObjects removeAllObjects]; [DYYYAvatarActionOwners removeAllObjects];
    [DYYYAvatarActionBoundaryViews removeAllObjects];
    DYYYAvatarActionEverMarked = NO; DYYYAvatarActionBoundaryDirty = YES;
    DYYYAvatarActionTopologyDirty = YES; DYYYAvatarActionReconcileScheduled = NO;
    DYYYAvatarActionBoundGeneration = UINT32_MAX; DYYYAvatarActionResolveCount = 0;
    CHECK(DYYYAvatarActionRegistrationDepth == 0 && DYYYAvatarActionCurrentWrite == NULL);
    DYYYTestImmediateBlocks = [NSMutableArray array]; DYYYTestDelayedBlocks = [NSMutableArray array];
}

// 两 owner 只暴露各自动作 getter，不互相伪造 selector。
@interface DYYYTestFollowOwner : NSObject
@property(nonatomic, strong) UIView *target;
- (UIView *)followAddView;
@end
@implementation DYYYTestFollowOwner
- (UIView *)followAddView { return self.target; }
@end
@interface DYYYTestMessageOwner : NSObject
@property(nonatomic, strong) UIView *target;
- (UIView *)sendMessageView;
@end
@implementation DYYYTestMessageOwner
- (UIView *)sendMessageView { return self.target; }
@end
@interface DYYYTestStoreOwner : NSObject
@property(nonatomic, strong) UIView *target;
- (UIView *)enterStoreView;
@end
@implementation DYYYTestStoreOwner
- (UIView *)enterStoreView { return self.target; }
@end

static void TestNativeUpdates(void) {
    for (NSUInteger store = 0; store < 2; store++) for (NSUInteger update = 0; update < 3; update++) {
        DYYYTestReset();
        UIView *follow = [UIView new], *action = [UIView new];
        DYYYTestFollowOwner *followOwner = [DYYYTestFollowOwner new]; followOwner.target = follow;
        id owner = store ? [DYYYTestStoreOwner new] : [DYYYTestMessageOwner new];
        [owner setTarget:action];
        NSString *key = store ? DYYYHideAvatarEnterStoreKey : DYYYHideAvatarSendMessageKey;
        // 真实 shouldShow hook 是否保留原生答案由配套只读结构检查覆盖；这里输入宿主原生请求。
        action.hidden = NO; action.userInteractionEnabled = YES;
        DYYYTestSet(DYYYAvatarFollowDeleteKey, YES);
        DYYYApplyAvatarActionSettingsSafely(followOwner);
        DYYYApplyAvatarActionSettingsSafely(owner); // 本项 Native 时也先登记边界
        CHECK(DYYYAvatarActionBoundaryForView(action).registered);
        DYYYTestSet(key, YES); DYYYTestRefresh();
        CHECK(action.hidden && !action.userInteractionEnabled);
        CHECK(!NativeBool(action, DYYYAvatarViewHidden)); // 压制自己的 YES 不写回 native
        BOOL requestedHidden = update == 1, requestedInteraction = update == 0;
        action.hidden = requestedHidden; action.userInteractionEnabled = requestedInteraction;
        CHECK(action.hidden && !action.userInteractionEnabled);
        CHECK(NativeBool(action, DYYYAvatarViewHidden) == requestedHidden);
        CHECK(NativeBool(action.layer, DYYYAvatarLayerHidden) == requestedHidden);
        CHECK(NativeBool(action, DYYYAvatarViewInteraction) == requestedInteraction);
        DYYYTestSet(key, NO); DYYYTestRefresh();
        CHECK(action.hidden == requestedHidden);
        CHECK(action.layer.hidden == requestedHidden);
        CHECK(action.userInteractionEnabled == requestedInteraction);
        CHECK(follow.hidden && !follow.userInteractionEnabled);
        CHECK(State(action).mode == DYYYAvatarActionModeNative);
    }
}

static void TestSharedParentChild(void) {
    for (NSUInteger reverse = 0; reverse < 2; reverse++) {
        DYYYTestReset();
        UIView *parent = [UIView new], *message = [UIView new];
        parent.bounds = CGRectMake(0, 0, 160, 160); message.bounds = CGRectMake(0, 0, 83, 67);
        [parent addSubview:message];
        DYYYTestFollowOwner *f = [DYYYTestFollowOwner new]; f.target = parent;
        DYYYTestMessageOwner *m = [DYYYTestMessageOwner new]; m.target = message;
        DYYYTestSet(DYYYAvatarFollowDeleteKey, YES);
        DYYYApplyAvatarActionSettingsSafely(reverse ? (id)m : f);
        DYYYApplyAvatarActionSettingsSafely(reverse ? (id)f : m);
        DYYYAvatarActionBoundary *boundary = DYYYAvatarActionBoundaryForView(message);
        CHECK(boundary.registered && boundary.kind == DYYYAvatarActionSendMessage);
        CHECK(DYYYAvatarActionBoundaryForView(parent).shared);
        CHECK(!parent.hidden && parent.userInteractionEnabled);
        CHECK(!message.hidden && message.userInteractionEnabled);
        CHECK(!State(message) || State(message).kind == DYYYAvatarActionSendMessage);
        DYYYTestSet(DYYYHideAvatarSendMessageKey, YES); DYYYTestRefresh();
        DYYYAvatarActionState *state = State(message);
        NSMutableDictionary *native = state.nativeValues;
        CHECK(state.kind == DYYYAvatarActionSendMessage && state.owner == m);
        CHECK(message.hidden && !message.userInteractionEnabled);
        CHECK(!parent.hidden && parent.userInteractionEnabled);
        for (NSUInteger iteration = 0; iteration < 2; iteration++) {
            DYYYTestSet(DYYYAvatarFollowDeleteKey, iteration != 0); DYYYTestRefresh();
            DYYYApplyAvatarActionSettingsSafely(f); DYYYApplyAvatarActionSettingsSafely(m);
            CHECK(State(message) == state && state.nativeValues == native);
            CHECK(state.kind == DYYYAvatarActionSendMessage && state.owner == m);
            CHECK(message.hidden && !message.userInteractionEnabled);
            CHECK(!parent.hidden && parent.userInteractionEnabled);
        }
        DYYYTestSet(DYYYHideAvatarSendMessageKey, NO); DYYYTestRefresh();
        DYYYApplyAvatarActionSettingsSafely(f);
        CHECK(State(message) == state && state.kind == DYYYAvatarActionSendMessage);
        CHECK(!parent.hidden && parent.userInteractionEnabled);
        CHECK(!message.hidden && message.userInteractionEnabled);
        // 新增已确认消息 child，didAddSubview 不得把它继承成 Follow。
        [message removeFromSuperview]; [parent addSubview:message];
        CHECK(State(message) == state && state.kind == DYYYAvatarActionSendMessage);
        CHECK(!parent.hidden && parent.userInteractionEnabled);
    }
}

static void TestSharedVersusReuse(void) {
    for (NSUInteger reverse = 0; reverse < 2; reverse++) {
        DYYYTestReset();
        UIView *view = [UIView new], *replacement = [UIView new];
        // 相同尺寸也不是复用证据；大于旧 52pt 猜测阈值。
        view.bounds = replacement.bounds = CGRectMake(0, 0, 91, 91);
        view.userInteractionEnabled = NO;
        DYYYTestFollowOwner *f = [DYYYTestFollowOwner new]; f.target = view;
        DYYYTestMessageOwner *m = [DYYYTestMessageOwner new]; m.target = view;
        DYYYTestSet(DYYYAvatarFollowDeleteKey, YES); DYYYTestSet(DYYYHideAvatarSendMessageKey, YES);
        DYYYApplyAvatarActionSettingsSafely(reverse ? (id)m : f);
        DYYYAvatarActionState *original = State(view);
        NSMutableDictionary *native = original.nativeValues;
        DYYYApplyAvatarActionSettingsSafely(reverse ? (id)f : m);
        CHECK(DYYYAvatarActionBoundaryForView(view).ambiguous);
        CHECK(State(view) == original && original.nativeValues == native);
        CHECK(original.kind == (reverse ? DYYYAvatarActionSendMessage : DYYYAvatarActionFollow));
        CHECK(!view.hidden && !view.userInteractionEnabled); // 合法共享保守恢复，不猜 YES
        // 旧 getter 明确放弃 view，新 getter 仍指向它，才能认定确证迁移。
        if (reverse) { m.target = replacement; DYYYApplyAvatarActionSettingsSafely(f); }
        else { f.target = replacement; DYYYApplyAvatarActionSettingsSafely(m); }
        DYYYAvatarActionKind next = reverse ? DYYYAvatarActionFollow : DYYYAvatarActionSendMessage;
        CHECK(!DYYYAvatarActionBoundaryForView(view).ambiguous);
        CHECK(DYYYAvatarActionBoundaryForView(view).kind == next);
        CHECK(State(view) == original && original.nativeValues == native);
        CHECK(original.kind == next && original.owner == (reverse ? (id)f : m));
        CHECK(view.hidden && !view.userInteractionEnabled);
        DYYYTestSet(reverse ? DYYYAvatarFollowDeleteKey : DYYYHideAvatarSendMessageKey, NO);
        DYYYTestRefresh();
        CHECK(!view.hidden && !view.userInteractionEnabled);
        CHECK(!NativeBool(view, DYYYAvatarViewHidden));
    }
    DYYYTestReset();
    UIView *view = [UIView new];
    DYYYTestFollowOwner *first = [DYYYTestFollowOwner new], *second = [DYYYTestFollowOwner new];
    first.target = view; second.target = view;
    DYYYTestSet(DYYYAvatarFollowDeleteKey, YES); DYYYApplyAvatarActionSettingsSafely(first);
    DYYYAvatarActionState *state = State(view);
    first.target = nil; DYYYApplyAvatarActionSettingsSafely(first);
    DYYYApplyAvatarActionSettingsSafely(second);
    CHECK(State(view) == state && state.owner == second); // 同 kind 重绑更新 weak owner
}

static void TestSynchronousReentry(void) {
    for (NSUInteger visual = 0; visual < 2; visual++) {
        DYYYTestReset();
        UIView *a = [UIView new], *b = [UIView new];
        UIColor *red = Red(); a.backgroundColor = red; b.backgroundColor = red;
        b.layer.contents = TestImage(); b.layer.borderColor = red.CGColor;
        DYYYTestFollowOwner *f = [DYYYTestFollowOwner new]; f.target = a;
        DYYYTestMessageOwner *m = [DYYYTestMessageOwner new]; m.target = b;
        DYYYTestSet(DYYYHideAvatarSendMessageKey, YES); DYYYApplyAvatarActionSettingsSafely(m);
        DYYYApplyAvatarActionSettingsSafely(f);
        __block BOOL fired = NO;
        a.dyyyOnOrigWrite = ^(UIView *source, NSUInteger property) {
            if (fired || property != (visual ? DYYYAvatarViewBackground : DYYYAvatarViewHidden)) return;
            fired = YES;
            CHECK(DYYYAvatarActionIsOwnWrite(source, (DYYYAvatarActionProperty)property));
            CHECK(!DYYYAvatarActionIsOwnWrite(b, DYYYAvatarViewHidden));
            // 同线程另一 kind 的最新 nil/false 请求必须走真正 RecordNative。
            b.hidden = NO; b.userInteractionEnabled = visual != 0;
            b.backgroundColor = nil; b.layer.contents = nil; b.layer.borderColor = NULL;
            ((CAShapeLayer *)b.layer).fillColor = NULL; ((CAShapeLayer *)b.layer).strokeColor = NULL;
            if (!visual) source.userInteractionEnabled = NO; // 同对象不同属性也不是自身写
        };
        DYYYTestSet(visual ? DYYYAvatarFollowRemoveVisualKey : DYYYAvatarFollowDeleteKey, YES);
        DYYYTestRefresh();
        CHECK(fired && DYYYAvatarActionCurrentWrite == NULL);
        CHECK(!NativeBool(a, DYYYAvatarViewHidden));
        CHECK(!NativeBool(a.layer, DYYYAvatarLayerHidden));
        CHECK(DYYYAvatarActionValue(State(a), DYYYAvatarViewBackground) == red);
        CHECK(ColorEqual(DYYYAvatarActionUnboxColor(DYYYAvatarActionValue(State(a.layer), DYYYAvatarLayerBackground)), red.CGColor));
        CHECK(!NativeBool(b, DYYYAvatarViewHidden) && !NativeBool(b.layer, DYYYAvatarLayerHidden));
        CHECK(NativeBool(b, DYYYAvatarViewInteraction) == (visual != 0));
        CHECK(NativeNil(b, DYYYAvatarViewBackground) && NativeNil(b.layer, DYYYAvatarLayerBackground));
        CHECK(NativeNil(b.layer, DYYYAvatarLayerContents) && NativeNil(b.layer, DYYYAvatarLayerBorderColor));
        CHECK(NativeNil(b.layer, DYYYAvatarLayerFillColor) && NativeNil(b.layer, DYYYAvatarLayerStrokeColor));
        CHECK(b.hidden && !b.userInteractionEnabled);
        if (!visual) CHECK(!NativeBool(a, DYYYAvatarViewInteraction));
        a.dyyyOnOrigWrite = nil;
        DYYYTestSet(DYYYHideAvatarSendMessageKey, NO); DYYYTestRefresh();
        CHECK(!b.hidden && b.userInteractionEnabled == (visual != 0));
        CHECK(b.backgroundColor == nil && b.layer.contents == nil && b.layer.backgroundColor == NULL);
        CHECK(b.layer.borderColor == NULL && ((CAShapeLayer *)b.layer).fillColor == NULL && ((CAShapeLayer *)b.layer).strokeColor == NULL);
    }
}

static void TestModeTransitions(void) {
    for (NSUInteger initial = 0; initial < 4; initial++) {
        DYYYTestReset();
        UIView *view = [UIView new];
        DYYYAvatarTestLayer *backing = (DYYYAvatarTestLayer *)view.layer;
        DYYYAvatarTestLayer *drawing = [DYYYAvatarTestLayer layer];
        UIColor *red = Red(); id image = TestImage();
        BOOL nativeHidden = (initial & 1) != 0, nativeInteraction = (initial & 2) != 0;
        view.hidden = nativeHidden; view.userInteractionEnabled = nativeInteraction;
        view.alpha = 0.37; view.bounds = CGRectMake(3, 5, 79, 93); view.backgroundColor = red;
        backing.hidden = !nativeHidden; backing.opacity = 0.63;
        drawing.contents = image; drawing.backgroundColor = red.CGColor;
        drawing.opaque = YES; drawing.borderWidth = 2.5; drawing.borderColor = red.CGColor;
        drawing.shadowOpacity = 0.7; drawing.shadowColor = red.CGColor;
        drawing.fillColor = red.CGColor; drawing.strokeColor = NULL;
        [backing addSublayer:drawing];
        DYYYTestFollowOwner *owner = [DYYYTestFollowOwner new]; owner.target = view;
        DYYYApplyAvatarActionSettingsSafely(owner);
        NSUInteger hiddenWrites = view.dyyyHiddenWrites, interactionWrites = view.dyyyInteractionWrites;
        NSUInteger backingWrites = backing.dyyyHiddenWrites;
        DYYYTestSet(DYYYAvatarFollowRemoveVisualKey, YES); DYYYTestRefresh();
        CHECK(State(view).mode == DYYYAvatarActionModeRemoveVisual);
        CHECK(view.hidden == nativeHidden && view.userInteractionEnabled == nativeInteraction);
        CHECK(view.dyyyHiddenWrites == hiddenWrites && view.dyyyInteractionWrites == interactionWrites);
        CHECK(backing.dyyyHiddenWrites == backingWrites && backing.hidden == !nativeHidden);
        CHECK(fabs(view.alpha - 0.37) < 0.0001 && CGRectEqualToRect(view.bounds, CGRectMake(3, 5, 79, 93)));
        CHECK(fabs(backing.opacity - 0.63) < 0.0001);
        CHECK(drawing.hidden && drawing.contents == nil && drawing.borderWidth == 0 && !drawing.opaque);
        CHECK(CGColorGetAlpha(drawing.fillColor) == 0);
        DYYYTestSet(DYYYAvatarFollowRemoveVisualKey, NO); DYYYTestSet(DYYYAvatarFollowDeleteKey, YES);
        DYYYTestRefresh();
        CHECK(view.hidden && !view.userInteractionEnabled && drawing.hidden);
        // 隐藏期间最新原生请求，不准恢复时猜 hidden=NO / interaction=YES。
        view.hidden = nativeHidden; view.userInteractionEnabled = nativeInteraction;
        backing.hidden = !nativeHidden; // 晚于 UIView 请求的直接 layer 写
        view.backgroundColor = nil; drawing.contents = nil;
        drawing.borderColor = NULL; drawing.fillColor = NULL; drawing.strokeColor = red.CGColor;
        drawing.borderWidth = 4.25; drawing.shadowOpacity = 0.3; drawing.shadowColor = NULL;
        view.alpha = 0.41; view.bounds = CGRectMake(7, 9, 101, 87);
        CHECK(NativeBool(backing, DYYYAvatarLayerHidden) == !nativeHidden);
        DYYYTestSet(DYYYAvatarFollowDeleteKey, NO); DYYYTestSet(DYYYAvatarFollowRemoveVisualKey, YES);
        DYYYTestRefresh();
        CHECK(view.hidden == nativeHidden && view.userInteractionEnabled == nativeInteraction);
        CHECK(backing.hidden == !nativeHidden); // 真实 Refresh 的 UIView→layer 两遍恢复
        CHECK(drawing.hidden && drawing.contents == nil && drawing.borderWidth == 0);
        DYYYTestSet(DYYYAvatarFollowRemoveVisualKey, NO); DYYYTestRefresh();
        CHECK(State(view).mode == DYYYAvatarActionModeNative);
        CHECK(view.hidden == nativeHidden && view.userInteractionEnabled == nativeInteraction);
        CHECK(backing.hidden == !nativeHidden && !drawing.hidden);
        CHECK(view.backgroundColor == nil && drawing.contents == nil && drawing.borderColor == NULL);
        CHECK(drawing.fillColor == NULL && ColorEqual(drawing.strokeColor, red.CGColor));
        CHECK(fabs(drawing.borderWidth - 4.25) < 0.0001 && fabs(drawing.shadowOpacity - 0.3) < 0.0001);
        CHECK(drawing.shadowColor == NULL && drawing.opaque);
        CHECK(fabs(view.alpha - 0.41) < 0.0001 && CGRectEqualToRect(view.bounds, CGRectMake(7, 9, 101, 87)));
        CHECK(fabs(backing.opacity - 0.63) < 0.0001);
    }
}

@interface DYYYTestContext : NSObject
@property(nonatomic, strong) UIView *elementView;
@end
@implementation DYYYTestContext
@end
@interface DYYYTestRetryOwner : DYYYTestFollowOwner
@property(nonatomic, strong) DYYYTestContext *context;
@property(nonatomic) NSUInteger getterCalls;
@property(nonatomic) NSUInteger throwAtCall;
@property(nonatomic) BOOL throwContext;
- (DYYYTestContext *)userAvatarContext;
@end
@implementation DYYYTestRetryOwner
- (UIView *)followAddView {
    self.getterCalls++;
    if (self.throwAtCall && self.getterCalls == self.throwAtCall)
        @throw [NSException exceptionWithName:@"DYYYRuntimeTestException" reason:@"测试 getter 主动抛异常" userInfo:nil];
    return self.target;
}
- (DYYYTestContext *)userAvatarContext {
    if (self.throwContext)
        @throw [NSException exceptionWithName:@"DYYYRuntimeTestException" reason:@"测试离窗 getter 主动抛异常" userInfo:nil];
    return self.context;
}
@end
static DYYYTestRetryOwner *RetryOwner(UIWindow *window) {
    DYYYTestRetryOwner *owner = [DYYYTestRetryOwner new]; owner.target = [UIView new];
    owner.context = [DYYYTestContext new]; owner.context.elementView = owner.target;
    [window addSubview:owner.target]; return owner;
}
static BOOL Pending(id object) { return [objc_getAssociatedObject(object, &kDYYYAvatarActionPendingKey) boolValue]; }
static BOOL Applying(id object) { return [objc_getAssociatedObject(object, &kDYYYAvatarActionApplyingKey) boolValue]; }
static void TestRetryCleanup(void) {
    // 正常、同步应用异常、首段应用异常、首段离窗 getter 异常、延迟应用异常、延迟离窗 getter 异常、离窗。
    for (NSUInteger scenario = 0; scenario < 7; scenario++) {
        DYYYTestReset(); DYYYTestSet(DYYYAvatarFollowDeleteKey, YES);
        UIWindow *window = [UIWindow new]; DYYYTestRetryOwner *owner = RetryOwner(window);
        if (scenario == 1) owner.throwAtCall = 1;
        NSException *synchronous = nil;
        @try { DYYYApplyAvatarActionSettingsWithRetry(owner); }
        @catch (NSException *exception) { synchronous = exception; }
        CHECK(!Applying(owner));
        if (scenario == 1) {
            CHECK([synchronous.name isEqualToString:@"DYYYRuntimeTestException"]);
            CHECK(!Pending(owner) && !DYYYTestImmediateBlocks.count && !DYYYTestDelayedBlocks.count);
            continue;
        }
        CHECK(!synchronous && Pending(owner) && DYYYTestImmediateBlocks.count == 1);
        NSUInteger registeredCalls = owner.getterCalls;
        if (scenario == 2) owner.throwAtCall = registeredCalls + 1;
        if (scenario == 3) owner.throwContext = YES;
        if (scenario == 6) [owner.target removeFromSuperview];
        NSException *first = DYYYTestDrainOne(NO);
        CHECK(!Applying(owner));
        if (scenario == 2 || scenario == 3 || scenario == 6) {
            CHECK((first != nil) == (scenario != 6));
            CHECK(!Pending(owner) && !DYYYTestDelayedBlocks.count);
            CHECK(owner.getterCalls == registeredCalls + (scenario == 2 ? 1 : 0));
        } else {
            CHECK(!first && Pending(owner) && DYYYTestDelayedBlocks.count == 1);
            if (scenario == 4) owner.throwAtCall = owner.getterCalls + 1;
            if (scenario == 5) owner.throwContext = YES;
            NSException *last = DYYYTestDrainOne(YES);
            CHECK((last != nil) == (scenario == 4 || scenario == 5));
            CHECK(!Pending(owner) && !Applying(owner) && !DYYYTestDelayedBlocks.count);
            if (owner.getterCalls != registeredCalls + (scenario == 5 ? 1 : 2))
                printf("DIAG AvatarRuntime/retry scenario=%lu registered=%lu observed=%lu resolves=%lu\n",
                       (unsigned long)scenario, (unsigned long)registeredCalls, (unsigned long)owner.getterCalls,
                       (unsigned long)DYYYAvatarActionResolveCount);
            CHECK(owner.getterCalls == registeredCalls + (scenario == 5 ? 1 : 2));
        }
        // 移出窗口只多排队一次拓扑对齐，不产生另一次重试或无限回调。
        NSUInteger topologyBlocks = DYYYTestImmediateBlocks.count;
        CHECK(topologyBlocks == (scenario == 6 ? 1 : 0));
        if (topologyBlocks) CHECK(DYYYTestDrainOne(NO) == nil);
        CHECK(!DYYYTestImmediateBlocks.count && !DYYYTestDelayedBlocks.count && !Pending(owner));
    }
    DYYYTestReset(); DYYYTestSet(DYYYAvatarFollowDeleteKey, YES);
    UIViewController *controller = [UIViewController new];
    CHECK(DYYYAvatarActionTargetDetached(controller) && controller.viewIfLoaded == nil);
    CHECK(DYYYAvatarActionTargetDetached([NSObject new]));
    UIWindow *window = [UIWindow new];
    DYYYTestRetryOwner *owner = RetryOwner(window);
    CHECK(!DYYYAvatarActionTargetDetached(owner));
    [owner.target removeFromSuperview]; CHECK(DYYYAvatarActionTargetDetached(owner));
    __weak DYYYTestRetryOwner *weakOwner;
    @autoreleasepool {
        DYYYTestRetryOwner *temporary = RetryOwner(window); weakOwner = temporary;
        DYYYApplyAvatarActionSettingsWithRetry(temporary); temporary = nil;
    }
    CHECK(weakOwner == nil); // registry 和重试 block 不保活 owner
    CHECK(!DYYYTestDrainOne(NO) && !DYYYTestDelayedBlocks.count);
}

static void TestExpiredClaims(void) {
    for (NSUInteger visual = 0; visual < 2; visual++) {
        DYYYTestReset();
        UIView *view = [UIView new];
        view.hidden = NO; view.userInteractionEnabled = NO;
        view.backgroundColor = Red();
        id image = TestImage(); view.layer.contents = image;
        DYYYAvatarActionState *state;
        __weak id weakOwner;
        @autoreleasepool {
            id owner = visual ? (id)[DYYYTestFollowOwner new] : [DYYYTestMessageOwner new];
            [owner setTarget:view]; weakOwner = owner;
            DYYYTestSet(visual ? DYYYAvatarFollowRemoveVisualKey : DYYYHideAvatarSendMessageKey, YES);
            DYYYApplyAvatarActionSettingsSafely(owner); state = State(view);
            CHECK(state != nil);
            if (visual) {
                view.layer.contents = image;
                CHECK(view.layer.contents == nil);
            } else CHECK(view.hidden && !view.userInteractionEnabled);
            owner = nil;
        }
        CHECK(weakOwner == nil);
        CHECK(DYYYAvatarActionModeForState(state) == DYYYAvatarActionModeNative);
        CHECK(DYYYTestImmediateBlocks.count == 1); // 生命周期通知合并，不保存 owner
        CHECK(DYYYTestDrainOne(NO) == nil);
        CHECK(State(view) == state && state.mode == DYYYAvatarActionModeNative);
        CHECK(!view.hidden && !view.userInteractionEnabled);
        CHECK(view.layer.contents == image);
        view.hidden = NO; view.userInteractionEnabled = YES; view.backgroundColor = nil;
        CHECK(!view.hidden && view.userInteractionEnabled && view.backgroundColor == nil);
        CHECK(!NativeBool(view, DYYYAvatarViewHidden) && NativeBool(view, DYYYAvatarViewInteraction));
    }
    for (NSUInteger scenario = 0; scenario < 4; scenario++) {
        DYYYTestReset();
        UIView *view = [UIView new];
        DYYYTestMessageOwner *owner = [DYYYTestMessageOwner new]; owner.target = view;
        DYYYTestSet(DYYYHideAvatarSendMessageKey, YES); DYYYApplyAvatarActionSettingsSafely(owner);
        DYYYAvatarActionState *state = State(view);
        NSMutableDictionary *native = state.nativeValues;
        owner.target = (scenario & 1) ? [UIView new] : nil;
        // 没有调用旧 owner.Safely；同时覆盖一次低频验证和原生 setter 的本 root 核验。
        if (scenario >= 2) {
            view.hidden = NO; view.userInteractionEnabled = YES;
            CHECK(!view.hidden && view.userInteractionEnabled && state.mode == DYYYAvatarActionModeNative);
            CHECK(DYYYTestImmediateBlocks.count == 1);
        }
        DYYYTestRefresh();
        CHECK(!DYYYAvatarActionBoundaryForView(view).registered);
        CHECK(State(view) == state && state.nativeValues == native);
        CHECK(state.mode == DYYYAvatarActionModeNative && !view.hidden && view.userInteractionEnabled);
        view.hidden = NO; view.userInteractionEnabled = NO;
        CHECK(!view.hidden && !view.userInteractionEnabled);
    }
}

static void TestInheritedObjectsMoved(void) {
    for (NSUInteger visual = 0; visual < 2; visual++) {
        DYYYTestReset();
        UIView *root = [UIView new], *child = [UIView new], *foreign = [UIView new], *message = [UIView new];
        child.backgroundColor = Red();
        DYYYAvatarTestLayer *drawing = [DYYYAvatarTestLayer layer];
        id image = TestImage(); drawing.contents = image; drawing.borderWidth = 3;
        [root addSubview:child]; [root.layer addSublayer:drawing];
        DYYYTestFollowOwner *f = [DYYYTestFollowOwner new]; f.target = root;
        DYYYTestMessageOwner *m = [DYYYTestMessageOwner new]; m.target = message;
        DYYYTestSet(visual ? DYYYAvatarFollowRemoveVisualKey : DYYYAvatarFollowDeleteKey, YES);
        DYYYTestSet(DYYYHideAvatarSendMessageKey, YES);
        DYYYApplyAvatarActionSettingsSafely(f); DYYYApplyAvatarActionSettingsSafely(m);
        DYYYAvatarActionState *childState = State(child), *layerState = State(drawing), *messageState = State(message);
        NSMutableDictionary *messageNative = messageState.nativeValues;
        CHECK(childState.boundary == root && layerState.boundary == root);
        child.hidden = NO; child.userInteractionEnabled = YES;
        drawing.contents = image;
        // 移入未标记容器只走原生拓扑入口，不额外注册新 owner 或直接调用恢复答案。
        [foreign addSubview:child]; [foreign.layer addSublayer:drawing];
        CHECK(!child.hidden && child.userInteractionEnabled && !drawing.hidden);
        CHECK(drawing.contents == image && fabs(drawing.borderWidth - 3) < 0.0001);
        CHECK(DYYYAvatarActionModeForState(childState) == DYYYAvatarActionModeNative);
        CHECK(DYYYAvatarActionModeForState(layerState) == DYYYAvatarActionModeNative);
        CHECK(DYYYTestImmediateBlocks.count == 1);
        CHECK(DYYYTestDrainOne(NO) == nil);
        CHECK(State(child) == childState && State(drawing) == layerState);
        CHECK(messageState == State(message) && messageState.nativeValues == messageNative);
        CHECK(message.hidden && !message.userInteractionEnabled);
        CHECK(!child.hidden && child.userInteractionEnabled && !drawing.hidden);
        child.hidden = YES; child.hidden = NO; child.userInteractionEnabled = NO; child.userInteractionEnabled = YES;
        drawing.contents = nil;
        CHECK(!child.hidden && child.userInteractionEnabled && drawing.contents == nil);
        CHECK(NativeNil(drawing, DYYYAvatarLayerContents));
        DYYYTestSet(visual ? DYYYAvatarFollowRemoveVisualKey : DYYYAvatarFollowDeleteKey, NO); DYYYTestRefresh();
        DYYYTestSet(visual ? DYYYAvatarFollowRemoveVisualKey : DYYYAvatarFollowDeleteKey, YES); DYYYTestRefresh();
        CHECK(!child.hidden && child.userInteractionEnabled && !drawing.hidden && drawing.contents == nil);
        CHECK(childState.kind == DYYYAvatarActionFollow && layerState.kind == DYYYAvatarActionFollow);
    }
}

static void TestStableLayoutCost(void) {
    DYYYTestReset();
    UIView *parent = [UIView new], *message = [UIView new], *foreign = [UIView new];
    [parent addSubview:message];
    DYYYTestFollowOwner *f = [DYYYTestFollowOwner new]; f.target = parent;
    DYYYTestMessageOwner *m = [DYYYTestMessageOwner new]; m.target = message;
    DYYYTestSet(DYYYAvatarFollowDeleteKey, YES);
    DYYYApplyAvatarActionSettingsSafely(f); DYYYApplyAvatarActionSettingsSafely(m);
    CHECK(DYYYAvatarActionBoundaryForView(parent).shared && !parent.hidden);
    NSArray *previous = objc_getAssociatedObject(m, &kDYYYAvatarActionOwnerClaimsKey);
    id claim = previous.firstObject;
    NSUInteger resolves = DYYYAvatarActionResolveCount;
    for (NSUInteger repeat = 0; repeat < 80; repeat++) {
        DYYYApplyAvatarActionSettingsSafely(f); DYYYApplyAvatarActionSettingsSafely(m);
    }
    CHECK(DYYYAvatarActionResolveCount == resolves);
    CHECK([objc_getAssociatedObject(m, &kDYYYAvatarActionOwnerClaimsKey) firstObject] == claim);
    CHECK(DYYYAvatarActionBoundaryForView(message).registered); // Native 子边界仍登记
    DYYYTestRefresh(); CHECK(DYYYAvatarActionResolveCount == resolves);
    DYYYTestSet(DYYYHideAvatarSendMessageKey, YES); DYYYTestRefresh();
    CHECK(DYYYAvatarActionResolveCount == resolves && message.hidden);
    [foreign addSubview:message];
    CHECK(DYYYTestImmediateBlocks.count == 1);
    CHECK(DYYYTestDrainOne(NO) == nil);
    CHECK(DYYYAvatarActionResolveCount == resolves + 1);
    CHECK(!DYYYAvatarActionBoundaryForView(parent).shared && parent.hidden);
    CHECK(message.hidden); // 精确认领的消息本体迁移，仍由自己的消息开关控制
}

static void TestMovedChildClaimedByNewKind(void) {
    for (NSUInteger visual = 0; visual < 2; visual++) {
        DYYYTestReset();
        UIView *parent = [UIView new], *child = [UIView new], *foreign = [UIView new];
        DYYYAvatarTestLayer *drawing = [DYYYAvatarTestLayer layer];
        id image = TestImage(); drawing.contents = image;
        [child.layer addSublayer:drawing]; [parent addSubview:child];
        DYYYTestFollowOwner *oldOwner = [DYYYTestFollowOwner new]; oldOwner.target = parent;
        DYYYTestMessageOwner *newOwner = [DYYYTestMessageOwner new];
        DYYYTestSet(visual ? DYYYAvatarFollowRemoveVisualKey : DYYYAvatarFollowDeleteKey, YES);
        DYYYTestSet(DYYYHideAvatarSendMessageKey, YES);
        DYYYApplyAvatarActionSettingsSafely(oldOwner);
        DYYYAvatarActionState *viewState = State(child), *backingState = State(child.layer), *drawState = State(drawing);
        NSMutableDictionary *viewNative = viewState.nativeValues, *drawNative = drawState.nativeValues;
        CHECK(viewState.kind == DYYYAvatarActionFollow && viewState.boundary == parent);
        CHECK(drawState.kind == DYYYAvatarActionFollow && drawState.boundary == parent);
        [foreign addSubview:child];
        child.hidden = NO; child.userInteractionEnabled = YES; drawing.contents = image;
        CHECK(!child.hidden && child.userInteractionEnabled && drawing.contents == image);
        newOwner.target = child; DYYYApplyAvatarActionSettingsSafely(newOwner);
        // 旧 P/owner 仍有效，但 V 已移出 P且被新 getter明确认领，不能再拒绝接管。
        CHECK(DYYYAvatarActionBoundaryForView(parent).registered);
        CHECK(!DYYYAvatarActionBoundaryForView(parent).shared && oldOwner.target == parent);
        CHECK(State(child) == viewState && State(child.layer) == backingState && State(drawing) == drawState);
        CHECK(viewState.nativeValues == viewNative && drawState.nativeValues == drawNative);
        CHECK(viewState.kind == DYYYAvatarActionSendMessage && viewState.boundary == child && viewState.owner == newOwner);
        CHECK(backingState.kind == DYYYAvatarActionSendMessage && drawState.kind == DYYYAvatarActionSendMessage);
        CHECK(child.hidden && !child.userInteractionEnabled && drawing.hidden);
        child.hidden = NO; child.userInteractionEnabled = YES;
        CHECK(child.hidden && !child.userInteractionEnabled);
        DYYYApplyAvatarActionSettingsSafely(oldOwner);
        CHECK(viewState.kind == DYYYAvatarActionSendMessage && child.hidden);
        DYYYTestSet(DYYYHideAvatarSendMessageKey, NO); DYYYTestRefresh();
        CHECK(!child.hidden && child.userInteractionEnabled && !drawing.hidden && drawing.contents == image);
        CHECK(viewState.mode == DYYYAvatarActionModeNative);
    }
}

static void TestWriteFrameException(void) {
    DYYYTestReset(); UIView *view = [UIView new];
    NSException *caught = nil;
    @try {
        DYYY_AVATAR_WRITE(view, DYYYAvatarViewHidden,
            CHECK(DYYYAvatarActionIsOwnWrite(view.layer, DYYYAvatarLayerHidden));
            @throw [NSException exceptionWithName:@"DYYYRuntimeTestException" reason:@"写栈 finally" userInfo:nil];
        );
    } @catch (NSException *exception) { caught = exception; }
    CHECK(caught != nil && DYYYAvatarActionCurrentWrite == NULL);
    CHECK(!DYYYAvatarActionIsOwnWrite(view, DYYYAvatarViewHidden));
}

int DYYYRunAvatarActionRuntimeTests(void) {
    if (!NSThread.isMainThread) { printf("FAIL AvatarRuntime requires main thread\n"); return 1; }
    DYYYTestFailures = 0; DYYYTestAssertions = 0;
    const struct { const char *name; void (*run)(void); } cases[] = {
        {"native-message-store-updates", TestNativeUpdates},
        {"shared-parent-child-orders", TestSharedParentChild},
        {"shared-vs-confirmed-reuse", TestSharedVersusReuse},
        {"synchronous-other-kind-reentry", TestSynchronousReentry},
        {"native-visual-delete-restore", TestModeTransitions},
        {"retry-exception-detached-cleanup", TestRetryCleanup},
        {"expired-owner-single-getter-claims", TestExpiredClaims},
        {"inherited-view-layer-moved-out", TestInheritedObjectsMoved},
        {"stable-layout-no-global-reresolve", TestStableLayoutCost},
        {"moved-inherited-child-new-kind-claim", TestMovedChildClaimedByNewKind},
        {"write-frame-exception-cleanup", TestWriteFrameException},
    };
    for (NSUInteger i = 0; i < sizeof(cases) / sizeof(cases[0]); i++) {
        @autoreleasepool {
            DYYYTestCase = cases[i].name; int before = DYYYTestFailures;
            @try { cases[i].run(); }
            @catch (NSException *exception) {
                DYYYTestFailures++;
                printf("FAIL AvatarRuntime/%s unexpected exception %s: %s\n", DYYYTestCase,
                       exception.name.UTF8String, exception.reason.UTF8String);
            }
            if (before == DYYYTestFailures) printf("PASS AvatarRuntime/%s\n", DYYYTestCase);
        }
    }
    printf("%s AvatarRuntime Foundation+QuartzCore+UIKit-double: %d assertions, %d failures\n",
           DYYYTestFailures ? "FAIL" : "PASS", DYYYTestAssertions, DYYYTestFailures);
    return DYYYTestFailures ? 1 : 0;
}
