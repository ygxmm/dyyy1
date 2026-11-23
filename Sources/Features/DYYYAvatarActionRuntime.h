#pragma once
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdint.h>
#import "DYYYAvatarInteractionPolicy.h"

// 只保存已确认动作边界的原生请求；头像本体、彩环、挂件不进入此作用域。
typedef NS_ENUM(NSUInteger, DYYYAvatarActionProperty) {
    DYYYAvatarViewHidden, DYYYAvatarViewInteraction, DYYYAvatarViewBackground,
    DYYYAvatarLayerHidden, DYYYAvatarLayerContents, DYYYAvatarLayerBackground,
    DYYYAvatarLayerOpaque, DYYYAvatarLayerBorderWidth, DYYYAvatarLayerBorderColor,
    DYYYAvatarLayerShadowOpacity, DYYYAvatarLayerShadowColor,
    DYYYAvatarLayerFillColor, DYYYAvatarLayerStrokeColor,
};
@interface DYYYAvatarActionState : NSObject
@property(nonatomic) DYYYAvatarActionKind kind;
@property(nonatomic) DYYYAvatarActionMode mode;
@property(nonatomic) BOOL backingLayer;
@property(nonatomic) BOOL avatarBody;
@property(nonatomic) BOOL avatarLive;
@property(nonatomic, weak) id owner;
@property(nonatomic, weak) id object;
@property(nonatomic, weak) UIView *boundary;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, id> *nativeValues;
@end
@implementation DYYYAvatarActionState
@end

static char kDYYYAvatarActionStateKey;
static char kDYYYAvatarActionApplyingKey;
static char kDYYYAvatarActionPendingKey;
// 写来源只匹配对象/属性；不屏蔽同线程其他对象的原生重入。
// DYYY_AVATAR_WRITE_CORE_BEGIN
static inline BOOL DYYYAvatarActionWriteMatches(uintptr_t source, NSUInteger sourceProperty,
                                              uintptr_t derived, NSUInteger derivedProperty,
                                              uintptr_t object, NSUInteger property) {
    return (source == object && sourceProperty == property) ||
           (derived && derived == object && derivedProperty == property);
}
// 这些纯状态规则由同一个 runtime 使用，workspace 回归直接抽取，不另造实现。
static inline BOOL DYYYAvatarActionBoundaryPermits(BOOL registered, BOOL shared, BOOL ambiguous,
                                                  BOOL protect, NSUInteger kind, NSUInteger requested) {
    return registered && !shared && !ambiguous && !protect && kind == requested;
}
static inline BOOL DYYYAvatarActionChildBlocksParent(BOOL registered, BOOL protect, BOOL ambiguous,
                                                    NSUInteger childKind, NSUInteger parentKind) {
    return registered && (protect || ambiguous || childKind != parentKind);
}
// DYYY_AVATAR_WRITE_CORE_END
struct DYYYAvatarActionWriteFrame {
    __unsafe_unretained id object;
    DYYYAvatarActionProperty property;
    __unsafe_unretained id derived;
    DYYYAvatarActionProperty derivedProperty;
    struct DYYYAvatarActionWriteFrame *previous;
};
static __thread struct DYYYAvatarActionWriteFrame *DYYYAvatarActionCurrentWrite;
static struct DYYYAvatarActionWriteFrame DYYYAvatarActionWriteFrameForObject(id object, DYYYAvatarActionProperty property) {
    struct DYYYAvatarActionWriteFrame frame = {object, property, nil, property, DYYYAvatarActionCurrentWrite};
    if ([object isKindOfClass:UIView.class]) {
        if (property == DYYYAvatarViewHidden) { frame.derived = ((UIView *)object).layer; frame.derivedProperty = DYYYAvatarLayerHidden; }
        if (property == DYYYAvatarViewBackground) { frame.derived = ((UIView *)object).layer; frame.derivedProperty = DYYYAvatarLayerBackground; }
    }
    return frame;
}
static BOOL DYYYAvatarActionIsOwnWrite(id object, DYYYAvatarActionProperty property) {
    for (struct DYYYAvatarActionWriteFrame *frame = DYYYAvatarActionCurrentWrite; frame; frame = frame->previous) {
        if (DYYYAvatarActionWriteMatches((uintptr_t)(__bridge void *)frame->object, frame->property,
            (uintptr_t)(__bridge void *)frame->derived, frame->derivedProperty,
            (uintptr_t)(__bridge void *)object, property)) return YES;
    }
    return NO;
}
#define DYYY_AVATAR_WRITE(object, property, ...) do { \
    struct DYYYAvatarActionWriteFrame _dyyyFrame = DYYYAvatarActionWriteFrameForObject(object, property); \
    DYYYAvatarActionCurrentWrite = &_dyyyFrame; \
    @try { __VA_ARGS__; } @finally { DYYYAvatarActionCurrentWrite = _dyyyFrame.previous; } \
} while (0)
static NSHashTable *DYYYAvatarActionObjects;
static NSHashTable *DYYYAvatarActionOwners;
static BOOL DYYYAvatarActionEverMarked;
static BOOL DYYYAvatarActionRefreshing;
static BOOL DYYYAvatarActionBoundaryDirty;
static BOOL DYYYAvatarActionTopologyDirty;
static BOOL DYYYAvatarActionReconcileScheduled;
static NSUInteger DYYYAvatarActionRegistrationDepth;
static NSUInteger DYYYAvatarActionResolveCount;
static uint32_t DYYYAvatarActionBoundGeneration = UINT32_MAX;
static BOOL DYYYAvatarActionScopePermits(DYYYAvatarActionState *state);
static void DYYYAvatarActionValidateStateClaim(DYYYAvatarActionState *state);
static void DYYYAvatarActionScheduleReconcile(void);

static inline DYYYAvatarActionSettings DYYYAvatarActionSnapshot(void) {
    return (DYYYAvatarActionSettings){
        DYYYGetBoolCached(DYYYAvatarFollowRemoveVisualKey),
        DYYYGetBoolCached(DYYYAvatarFollowDeleteKey),
        DYYYGetBoolCached(DYYYHideAvatarSendMessageKey),
        DYYYGetBoolCached(DYYYHideAvatarEnterStoreKey),
        DYYYGetBoolCached(DYYYHideAvatarAdLinkKey),
    };
}
static BOOL DYYYAvatarActionRuntimeNeeded(void) {
    return DYYYAvatarActionEverMarked || DYYYAvatarActionActiveKinds(DYYYAvatarActionSnapshot()) != DYYYAvatarActionNone;
}
static DYYYAvatarActionState *DYYYAvatarActionStateForObject(id object) {
    return object && DYYYAvatarActionRuntimeNeeded() ? objc_getAssociatedObject(object, &kDYYYAvatarActionStateKey) : nil;
}
static void DYYYAvatarActionEnsureTables(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        DYYYAvatarActionObjects = [NSHashTable weakObjectsHashTable];
        DYYYAvatarActionOwners = [NSHashTable weakObjectsHashTable];
    });
}
static id DYYYAvatarObjectForSelector(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) return nil;
    // 已确认的无参对象 getter 按准确签名调用，不吞掉宿主异常。
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}
static UIView *DYYYAvatarViewForSelector(id object, SEL selector) {
    id value = DYYYAvatarObjectForSelector(object, selector);
    return [value isKindOfClass:UIView.class] ? value : nil;
}
static DYYYAvatarActionState *DYYYAvatarActionTrackIndependentVisibility(UIView *view, BOOL live);
static void DYYYApplyAvatarBodyVisibilityForSelector(id owner, SEL selector);
static id DYYYAvatarActionBoxColor(CGColorRef color) { return color ? (__bridge id)color : NSNull.null; }
static CGColorRef DYYYAvatarActionUnboxColor(id value) { return value == NSNull.null ? NULL : (__bridge CGColorRef)value; }
static void DYYYAvatarActionSave(DYYYAvatarActionState *state, DYYYAvatarActionProperty property, id value) {
    @synchronized (state) { state.nativeValues[@(property)] = value ?: NSNull.null; }
}
static id DYYYAvatarActionValue(DYYYAvatarActionState *state, DYYYAvatarActionProperty property) {
    @synchronized (state) { return state.nativeValues[@(property)]; }
}
static DYYYAvatarActionMode DYYYAvatarActionModeForState(DYYYAvatarActionState *state) {
    if (state.avatarBody) return DYYYGetBoolCached(@"DYYYHideAvatarButton") ? DYYYAvatarActionModeDelete : DYYYAvatarActionModeNative;
    if (state.avatarLive) return DYYYGetBoolCached(@"DYYYHideAvatarLive") ? DYYYAvatarActionModeDelete : DYYYAvatarActionModeNative;
    return DYYYAvatarActionScopePermits(state) ? DYYYAvatarActionModeForSettings(DYYYAvatarActionSnapshot(), state.kind) : DYYYAvatarActionModeNative;
}
static BOOL DYYYAvatarActionClearChrome(DYYYAvatarActionState *state) {
    return state && DYYYAvatarActionModeForState(state) == DYYYAvatarActionModeRemoveVisual;
}
static BOOL DYYYAvatarActionHideView(DYYYAvatarActionState *state) {
    return state && DYYYAvatarActionModeForState(state) == DYYYAvatarActionModeDelete;
}
static BOOL DYYYAvatarActionBlocksViewInteraction(DYYYAvatarActionState *state) {
    return state && !state.avatarBody && !state.avatarLive && DYYYAvatarActionHideView(state);
}
static BOOL DYYYAvatarActionHideLayer(DYYYAvatarActionState *state) {
    if (!state) return NO;
    DYYYAvatarActionMode mode = DYYYAvatarActionModeForState(state);
    return mode == DYYYAvatarActionModeDelete || (!state.backingLayer && mode == DYYYAvatarActionModeRemoveVisual);
}

static void DYYYAvatarActionApplyState(id object, DYYYAvatarActionState *state, DYYYAvatarActionMode mode) {
    DYYYAvatarActionMode previous = state.mode;
    state.mode = mode;
        if ([object isKindOfClass:UIView.class]) {
            UIView *view = object;
            if (mode == DYYYAvatarActionModeDelete || previous == DYYYAvatarActionModeDelete) {
                DYYY_AVATAR_WRITE(view, DYYYAvatarViewHidden, view.hidden = mode == DYYYAvatarActionModeDelete ? YES : [DYYYAvatarActionValue(state, DYYYAvatarViewHidden) boolValue];);
                if (!state.avatarBody && !state.avatarLive) {
                    DYYY_AVATAR_WRITE(view, DYYYAvatarViewInteraction, view.userInteractionEnabled = mode == DYYYAvatarActionModeDelete ? NO : [DYYYAvatarActionValue(state, DYYYAvatarViewInteraction) boolValue];);
                }
            }
            if (mode == DYYYAvatarActionModeRemoveVisual || previous == DYYYAvatarActionModeRemoveVisual) {
                id color = DYYYAvatarActionValue(state, DYYYAvatarViewBackground);
                DYYY_AVATAR_WRITE(view, DYYYAvatarViewBackground, view.backgroundColor = mode == DYYYAvatarActionModeRemoveVisual ? UIColor.clearColor : (color == NSNull.null ? nil : color););
            }
            // 从不写 alpha；RemoveVisual 不写任何视图 hidden / interaction / hitTest。
        } else {
            CALayer *layer = object;
            if ([layer.delegate isKindOfClass:UIView.class]) state.backingLayer = YES;
            if (!state.backingLayer || mode == DYYYAvatarActionModeDelete || previous == DYYYAvatarActionModeDelete) {
                BOOL hide = mode == DYYYAvatarActionModeDelete || (!state.backingLayer && mode == DYYYAvatarActionModeRemoveVisual);
                DYYY_AVATAR_WRITE(layer, DYYYAvatarLayerHidden, layer.hidden = hide ? YES : [DYYYAvatarActionValue(state, DYYYAvatarLayerHidden) boolValue];);
            }
            if (mode == DYYYAvatarActionModeRemoveVisual || previous == DYYYAvatarActionModeRemoveVisual) {
                BOOL clear = mode == DYYYAvatarActionModeRemoveVisual;
                id contents = DYYYAvatarActionValue(state, DYYYAvatarLayerContents);
                DYYY_AVATAR_WRITE(layer, DYYYAvatarLayerContents, layer.contents = clear || contents == NSNull.null ? nil : contents;);
                DYYY_AVATAR_WRITE(layer, DYYYAvatarLayerBackground, layer.backgroundColor = clear ? UIColor.clearColor.CGColor : DYYYAvatarActionUnboxColor(DYYYAvatarActionValue(state, DYYYAvatarLayerBackground)););
                DYYY_AVATAR_WRITE(layer, DYYYAvatarLayerOpaque, layer.opaque = clear ? NO : [DYYYAvatarActionValue(state, DYYYAvatarLayerOpaque) boolValue];);
                DYYY_AVATAR_WRITE(layer, DYYYAvatarLayerBorderWidth, layer.borderWidth = clear ? 0 : [DYYYAvatarActionValue(state, DYYYAvatarLayerBorderWidth) doubleValue];);
                DYYY_AVATAR_WRITE(layer, DYYYAvatarLayerBorderColor, layer.borderColor = clear ? UIColor.clearColor.CGColor : DYYYAvatarActionUnboxColor(DYYYAvatarActionValue(state, DYYYAvatarLayerBorderColor)););
                DYYY_AVATAR_WRITE(layer, DYYYAvatarLayerShadowOpacity, layer.shadowOpacity = clear ? 0 : [DYYYAvatarActionValue(state, DYYYAvatarLayerShadowOpacity) floatValue];);
                DYYY_AVATAR_WRITE(layer, DYYYAvatarLayerShadowColor, layer.shadowColor = clear ? UIColor.clearColor.CGColor : DYYYAvatarActionUnboxColor(DYYYAvatarActionValue(state, DYYYAvatarLayerShadowColor)););
                if ([layer isKindOfClass:CAShapeLayer.class]) {
                    DYYY_AVATAR_WRITE(layer, DYYYAvatarLayerFillColor, ((CAShapeLayer *)layer).fillColor = clear ? UIColor.clearColor.CGColor : DYYYAvatarActionUnboxColor(DYYYAvatarActionValue(state, DYYYAvatarLayerFillColor)););
                    DYYY_AVATAR_WRITE(layer, DYYYAvatarLayerStrokeColor, ((CAShapeLayer *)layer).strokeColor = clear ? UIColor.clearColor.CGColor : DYYYAvatarActionUnboxColor(DYYYAvatarActionValue(state, DYYYAvatarLayerStrokeColor)););
                }
            }
        }
}


static void DYYYAvatarActionRefreshTrackedObjects(void) {
    static uint32_t refreshedGeneration = UINT32_MAX;
    uint32_t generation = __atomic_load_n(&gDYYYSettingsGeneration, __ATOMIC_RELAXED);
    if (!NSThread.isMainThread || DYYYAvatarActionRefreshing || !DYYYAvatarActionEverMarked || (!DYYYAvatarActionBoundaryDirty && refreshedGeneration == generation)) return;
    DYYYAvatarActionRefreshing = YES;
    @try {
        NSArray *objects;
        @synchronized (DYYYAvatarActionObjects) { objects = DYYYAvatarActionObjects.allObjects; }
        // 先恢复 UIView，再恢复图层，保留晚于 UIView 请求的直接图层写入。
        for (NSUInteger pass = 0; pass < 2; pass++) {
            for (id object in objects) {
                if ([object isKindOfClass:UIView.class] != (pass == 0)) continue;
                DYYYAvatarActionState *state = objc_getAssociatedObject(object, &kDYYYAvatarActionStateKey);
                if (!state) continue;
                DYYYAvatarActionMode mode = DYYYAvatarActionModeForState(state);
                if (state.mode != mode) DYYYAvatarActionApplyState(object, state, mode);
            }
        }
        refreshedGeneration = generation;
        DYYYAvatarActionBoundaryDirty = NO;
    } @finally { DYYYAvatarActionRefreshing = NO; }
}
static void DYYYAvatarActionRecordNative(id object, DYYYAvatarActionState *state, DYYYAvatarActionProperty property, id value) {
    if (!state || DYYYAvatarActionIsOwnWrite(object, property)) return;
    DYYYAvatarActionSave(state, property, value);
    if (property == DYYYAvatarViewBackground || property == DYYYAvatarViewHidden) {
        DYYYAvatarActionState *layerState = objc_getAssociatedObject(((UIView *)object).layer, &kDYYYAvatarActionStateKey);
        if (layerState && property == DYYYAvatarViewBackground) DYYYAvatarActionSave(layerState, DYYYAvatarLayerBackground, DYYYAvatarActionBoxColor(((UIColor *)value).CGColor));
        if (layerState && property == DYYYAvatarViewHidden) DYYYAvatarActionSave(layerState, DYYYAvatarLayerHidden, value);
    }
    if ([object isKindOfClass:CALayer.class] && [((CALayer *)object).delegate isKindOfClass:UIView.class]) state.backingLayer = YES;
    DYYYAvatarActionValidateStateClaim(state);
    DYYYAvatarActionMode mode = DYYYAvatarActionModeForState(state);
    if (state.mode != mode && NSThread.isMainThread) {
        // owner 已失效或对象移出作用域时，代际未变也要恢复全部最新原生属性。
        DYYYAvatarActionBoundaryDirty = YES;
        DYYYAvatarActionRefreshTrackedObjects();
    }
}

static DYYYAvatarActionState *DYYYAvatarActionNewState(id object, DYYYAvatarActionKind kind, id owner) {
    DYYYAvatarActionEnsureTables();
    DYYYAvatarActionState *state = [DYYYAvatarActionState new];
    state.kind = kind;
    state.owner = owner;
    state.object = object;
    state.nativeValues = [NSMutableDictionary dictionary];
    objc_setAssociatedObject(object, &kDYYYAvatarActionStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @synchronized (DYYYAvatarActionObjects) { [DYYYAvatarActionObjects addObject:object]; }
    DYYYAvatarActionEverMarked = YES;
    return state;
}
static DYYYAvatarActionState *DYYYAvatarActionTrackIndependentVisibility(UIView *view, BOOL live) {
    if (!view) return nil;
    BOOL hide = live ? DYYYGetBoolCached(@"DYYYHideAvatarLive") : DYYYGetBoolCached(@"DYYYHideAvatarButton");
    DYYYAvatarActionState *state = objc_getAssociatedObject(view, &kDYYYAvatarActionStateKey);
    if (state && (state.kind != DYYYAvatarActionNone || state.avatarLive != live)) return nil;
    if (!state && !hide) return nil;
    if (!state) {
        state = DYYYAvatarActionNewState(view, DYYYAvatarActionNone, nil);
        state.avatarBody = !live;
        state.avatarLive = live;
        DYYYAvatarActionSave(state, DYYYAvatarViewHidden, @(view.hidden));
        DYYYAvatarActionSave(state, DYYYAvatarViewInteraction, @(view.userInteractionEnabled));
        DYYYAvatarActionSave(state, DYYYAvatarViewBackground, view.backgroundColor);
    }
    return state;
}
static void DYYYApplyAvatarBodyVisibilityForSelector(id owner, SEL selector) {
    if (!DYYYGetBoolCached(@"DYYYHideAvatarButton")) {
        DYYYAvatarActionRefreshTrackedObjects();
        return;
    }
    if (!owner || objc_getAssociatedObject(owner, &kDYYYAvatarActionApplyingKey)) return;
    // 与动作入口共用 getter 重入屏障；未开启本体隐藏时不探测 getter。
    objc_setAssociatedObject(owner, &kDYYYAvatarActionApplyingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        UIView *view = DYYYAvatarViewForSelector(owner, selector);
        DYYYAvatarActionState *state = DYYYAvatarActionTrackIndependentVisibility(view, NO);
        if (state) DYYYAvatarActionApplyState(view, state, DYYYAvatarActionModeForState(state));
    } @finally { objc_setAssociatedObject(owner, &kDYYYAvatarActionApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
}
// 精确边界登记与压制状态分离：Native 也登记，合法子动作始终是屏障。
@interface DYYYAvatarActionBoundaryClaim : NSObject
@property(nonatomic, weak) id owner;
@property(nonatomic, weak) UIView *view;
@property(nonatomic, copy) NSString *selectorName;
@property(nonatomic) DYYYAvatarActionKind kind;
@property(nonatomic) BOOL protectedVisual;
@property(nonatomic) BOOL valid;
@end
@implementation DYYYAvatarActionBoundaryClaim
@end

// 只登记生命周期，不 hook NSObject.dealloc，也不强持有 owner 或视图。
@interface DYYYAvatarActionOwnerLifetime : NSObject
@property(nonatomic, strong) NSArray<DYYYAvatarActionBoundaryClaim *> *claims;
@end
@implementation DYYYAvatarActionOwnerLifetime
- (void)dealloc {
    for (DYYYAvatarActionBoundaryClaim *claim in _claims) claim.valid = NO;
    __atomic_store_n(&DYYYAvatarActionTopologyDirty, YES, __ATOMIC_RELAXED);
    DYYYAvatarActionScheduleReconcile();
}
@end
@interface DYYYAvatarActionBoundary : NSObject
@property(nonatomic, strong) NSMutableArray<DYYYAvatarActionBoundaryClaim *> *claims;
@property(nonatomic, weak) id owner;
@property(nonatomic) DYYYAvatarActionKind kind;
@property(nonatomic) BOOL registered;
@property(nonatomic) BOOL protectedVisual;
@property(nonatomic) BOOL ambiguous;
@property(nonatomic) BOOL shared;
@end
@implementation DYYYAvatarActionBoundary
@end
static char kDYYYAvatarActionBoundaryKey;
static char kDYYYAvatarActionOwnerClaimsKey;
static char kDYYYAvatarActionOwnerLifetimeKey;
static NSHashTable *DYYYAvatarActionBoundaryViews;
static BOOL DYYYAvatarActionReconciling;
static DYYYAvatarActionBoundary *DYYYAvatarActionBoundaryForView(UIView *view) {
    return view ? objc_getAssociatedObject(view, &kDYYYAvatarActionBoundaryKey) : nil;
}
static BOOL DYYYAvatarActionObjectInsideBoundary(id object, UIView *root) {
    if (!object || !root) return NO;
    if ([object isKindOfClass:UIView.class]) return [((UIView *)object) isDescendantOfView:root];
    if ([object isKindOfClass:CALayer.class]) {
        CALayer *rootLayer = root.layer;
        for (CALayer *layer = object; layer; layer = layer.superlayer) if (layer == rootLayer) return YES;
    }
    return NO;
}
static BOOL DYYYAvatarActionBoundaryHasLiveClaim(DYYYAvatarActionBoundary *boundary, UIView *root) {
    for (DYYYAvatarActionBoundaryClaim *claim in boundary.claims) {
        if (claim.valid && claim.owner && claim.view == root && claim.kind == boundary.kind && !claim.protectedVisual) return YES;
    }
    return NO;
}
static BOOL DYYYAvatarActionScopePermits(DYYYAvatarActionState *state) {
    UIView *root = state.boundary;
    DYYYAvatarActionBoundary *boundary = DYYYAvatarActionBoundaryForView(root);
    // 有未解析的拓扑变化先保持原生；待一次批处理确认后才允许重新压制。
    if (__atomic_load_n(&DYYYAvatarActionTopologyDirty, __ATOMIC_RELAXED) ||
        !DYYYAvatarActionObjectInsideBoundary(state.object, root) ||
        !DYYYAvatarActionBoundaryHasLiveClaim(boundary, root)) return NO;
    return DYYYAvatarActionBoundaryPermits(boundary.registered, boundary.shared, boundary.ambiguous,
                                           boundary.protectedVisual, boundary.kind, state.kind);
}
static void DYYYAvatarActionValidateStateClaim(DYYYAvatarActionState *state) {
    if (state.kind == DYYYAvatarActionNone || !NSThread.isMainThread || DYYYAvatarActionRefreshing ||
        DYYYAvatarActionReconciling || DYYYAvatarActionRegistrationDepth) return;
    if (state.mode == DYYYAvatarActionModeNative &&
        DYYYAvatarActionModeForSettings(DYYYAvatarActionSnapshot(), state.kind) == DYYYAvatarActionModeNative) return;
    UIView *root = state.boundary;
    if (!DYYYAvatarActionObjectInsideBoundary(state.object, root)) return;
    DYYYAvatarActionBoundary *boundary = DYYYAvatarActionBoundaryForView(root);
    // 仅核对这个标记对象所属 root 的少量 getter，不遍历全局视图/owner。
    for (DYYYAvatarActionBoundaryClaim *claim in [boundary.claims copy]) {
        id owner = claim.owner;
        if (!claim.valid || !owner || claim.view != root || !claim.selectorName ||
            objc_getAssociatedObject(owner, &kDYYYAvatarActionApplyingKey)) continue;
        objc_setAssociatedObject(owner, &kDYYYAvatarActionApplyingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @try {
            if (DYYYAvatarViewForSelector(owner, NSSelectorFromString(claim.selectorName)) != root) {
                claim.valid = NO;
                __atomic_store_n(&DYYYAvatarActionTopologyDirty, YES, __ATOMIC_RELAXED);
                DYYYAvatarActionScheduleReconcile();
            }
        } @finally { objc_setAssociatedObject(owner, &kDYYYAvatarActionApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    }
}
static BOOL DYYYAvatarActionIsAvatarRoot(UIView *view) {
    return [view isKindOfClass:NSClassFromString(@"AWEPlayInteractionUserAvatarView")] ||
           [view isKindOfClass:NSClassFromString(@"AWEAdAvatarView")];
}
static NSArray<NSArray *> *DYYYAvatarActionSelectorGroups(void) {
    static NSArray *groups;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        groups = @[
            @[@(DYYYAvatarActionFollow), @[@"followAddView", @"followPromptView", @"followAnimationView", @"unfollowAnimationView", @"staticFollowAnimationView"]],
            @[@(DYYYAvatarActionSendMessage), @[@"sendMessageView", @"avatarSendMessageImageView", @"sendMessageGuideView"]],
            @[@(DYYYAvatarActionEnterStore), @[@"enterStoreView", @"avatarEnterStoreImageView", @"enterStoreGuideView"]],
            @[@(DYYYAvatarActionAdLink), @[@"linkIconContainerView", @"userAvatarLinkIcon"]],
        ];
    });
    return groups;
}
static void DYYYAvatarActionValidateClaims(NSArray<UIView *> *views);
static void DYYYAvatarActionRegisterClaim(id owner, NSString *selectorName, UIView *view,
                                        DYYYAvatarActionKind kind, BOOL protect,
                                        NSMutableArray *claims) {
    if (!view || !owner) return;
    if (!DYYYAvatarActionBoundaryViews) DYYYAvatarActionBoundaryViews = [NSHashTable weakObjectsHashTable];
    DYYYAvatarActionBoundary *boundary = DYYYAvatarActionBoundaryForView(view);
    if (!boundary) {
        boundary = [DYYYAvatarActionBoundary new];
        boundary.claims = [NSMutableArray array];
        objc_setAssociatedObject(view, &kDYYYAvatarActionBoundaryKey, boundary, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // 稳定布局复用已有认领，不为相同 getter 每次分配/删建并触发全局解析。
    DYYYAvatarActionBoundaryClaim *claim = nil;
    NSArray *previous = objc_getAssociatedObject(owner, &kDYYYAvatarActionOwnerClaimsKey);
    for (DYYYAvatarActionBoundaryClaim *candidate in previous) {
        BOOL sameSelector = candidate.selectorName == selectorName || [candidate.selectorName isEqualToString:selectorName];
        if (candidate.valid && candidate.owner == owner && candidate.view == view && sameSelector &&
            candidate.kind == kind && candidate.protectedVisual == protect) { claim = candidate; break; }
    }
    if (!claim) {
        claim = [DYYYAvatarActionBoundaryClaim new];
        claim.owner = owner; claim.view = view; claim.kind = kind;
        claim.selectorName = selectorName; claim.protectedVisual = protect; claim.valid = YES;
    }
    if (![boundary.claims containsObject:claim]) {
        [boundary.claims addObject:claim];
        __atomic_store_n(&DYYYAvatarActionTopologyDirty, YES, __ATOMIC_RELAXED);
    }
    if (![claims containsObject:claim]) [claims addObject:claim];
    [DYYYAvatarActionBoundaryViews addObject:view];
    // 当前 owner 的 getter 虽未变，竞争者可能已放弃这个 view；只复核本边界。
    if (boundary.ambiguous || boundary.protectedVisual) DYYYAvatarActionValidateClaims(@[view]);
}
// 低频批处理复核所有 getter，包括单 kind 及保护边界；setter 不全局调用这些 getter。
static void DYYYAvatarActionValidateClaims(NSArray<UIView *> *views) {
    for (UIView *view in views) {
        DYYYAvatarActionBoundary *boundary = DYYYAvatarActionBoundaryForView(view);
        for (DYYYAvatarActionBoundaryClaim *claim in [boundary.claims copy]) {
            id owner = claim.owner;
            if (!claim.valid || !owner || claim.view != view) {
                claim.valid = NO;
                __atomic_store_n(&DYYYAvatarActionTopologyDirty, YES, __ATOMIC_RELAXED);
                continue;
            }
            if (!claim.selectorName) {
                if (owner != view) claim.valid = NO;
            } else if (!objc_getAssociatedObject(owner, &kDYYYAvatarActionApplyingKey)) {
                objc_setAssociatedObject(owner, &kDYYYAvatarActionApplyingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                @try {
                    if (DYYYAvatarViewForSelector(owner, NSSelectorFromString(claim.selectorName)) != view) claim.valid = NO;
                } @catch (NSException *exception) {
                    claim.valid = NO;
                    __atomic_store_n(&DYYYAvatarActionTopologyDirty, YES, __ATOMIC_RELAXED);
                    @throw exception;
                } @finally { objc_setAssociatedObject(owner, &kDYYYAvatarActionApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
            }
            if (!claim.valid) __atomic_store_n(&DYYYAvatarActionTopologyDirty, YES, __ATOMIC_RELAXED);
        }
    }
}
static void DYYYAvatarActionResolveBoundaries(void) {
    NSArray<UIView *> *views = DYYYAvatarActionBoundaryViews.allObjects;
    DYYYAvatarActionValidateClaims(views);
    if (!__atomic_exchange_n(&DYYYAvatarActionTopologyDirty, NO, __ATOMIC_RELAXED)) return;
    DYYYAvatarActionResolveCount++;
    NSMutableArray<NSNumber *> *previousShared = [NSMutableArray arrayWithCapacity:views.count];
    for (UIView *view in views) {
        DYYYAvatarActionBoundary *boundary = DYYYAvatarActionBoundaryForView(view);
        DYYYAvatarActionKind kinds = DYYYAvatarActionNone;
        BOOL protect = NO, registered = NO;
        id owner = nil;
        for (DYYYAvatarActionBoundaryClaim *claim in [boundary.claims copy]) {
            if (!claim.valid || !claim.owner || claim.view != view) { [boundary.claims removeObject:claim]; continue; }
            kinds |= claim.kind; protect |= claim.protectedVisual; registered = YES; owner = claim.owner;
        }
        BOOL ambiguous = kinds && (kinds & (kinds - 1));
        if (boundary.kind != kinds || boundary.registered != registered || boundary.protectedVisual != protect ||
            boundary.ambiguous != ambiguous || boundary.owner != owner) DYYYAvatarActionBoundaryDirty = YES;
        boundary.kind = kinds; boundary.registered = registered; boundary.protectedVisual = protect;
        boundary.ambiguous = ambiguous; boundary.owner = owner;
        [previousShared addObject:@(boundary.shared)]; boundary.shared = NO;
        if (!registered) [DYYYAvatarActionBoundaryViews removeObject:view];
    }
    // 沿每个已确认子边界的祖先链登记共享，不对全部视图做两两比较。
    for (UIView *view in views) {
        DYYYAvatarActionBoundary *child = DYYYAvatarActionBoundaryForView(view);
        if (!child.registered) continue;
        for (UIView *parent = view.superview; parent; parent = parent.superview) {
            DYYYAvatarActionBoundary *boundary = DYYYAvatarActionBoundaryForView(parent);
            if (DYYYAvatarActionChildBlocksParent(child.registered, child.protectedVisual, child.ambiguous, child.kind, boundary.kind)) boundary.shared = YES;
        }
    }
    for (NSUInteger index = 0; index < views.count; index++) {
        DYYYAvatarActionBoundary *boundary = DYYYAvatarActionBoundaryForView(views[index]);
        if (boundary.shared != previousShared[index].boolValue) DYYYAvatarActionBoundaryDirty = YES;
    }
    // 成员变化也可能只影响继承对象，不必改变 root 的 kind/shared。
    DYYYAvatarActionBoundaryDirty = YES;
}
static DYYYAvatarActionState *DYYYAvatarActionRetargetState(id object, DYYYAvatarActionState *state,
        DYYYAvatarActionKind kind, id owner, UIView *root) {
    if (state && (state.avatarBody || state.avatarLive)) return nil;
    if (state && (state.kind != kind || state.boundary != root)) {
        // 只有新 root 已由 getter 明确登记且无冲突，才允许所有权转移；原值先恢复。
        DYYYAvatarActionBoundary *next = DYYYAvatarActionBoundaryForView(root);
        if (!next.registered || next.ambiguous || next.protectedVisual || next.shared || next.kind != kind) return nil;
        DYYYAvatarActionBoundary *old = DYYYAvatarActionBoundaryForView(state.boundary);
        if (state.boundary != root && old.registered && !old.shared && old.kind != kind &&
            DYYYAvatarActionBoundaryHasLiveClaim(old, state.boundary) &&
            DYYYAvatarActionObjectInsideBoundary(object, state.boundary)) return nil;
        DYYYAvatarActionApplyState(object, state, DYYYAvatarActionModeNative);
    }
    if (state) { state.kind = kind; state.owner = owner; state.boundary = root; }
    return state;
}
static void DYYYAvatarActionBindLayer(CALayer *layer, DYYYAvatarActionKind kind, id owner, UIView *root, BOOL backing) {
    if (!layer) return;
    DYYYAvatarActionBoundary *scope = DYYYAvatarActionBoundaryForView(root);
    if (!DYYYAvatarActionObjectInsideBoundary(layer, root) || !DYYYAvatarActionBoundaryHasLiveClaim(scope, root) ||
        !DYYYAvatarActionBoundaryPermits(scope.registered, scope.shared, scope.ambiguous, scope.protectedVisual, scope.kind, kind)) return;
    DYYYAvatarActionState *state = objc_getAssociatedObject(layer, &kDYYYAvatarActionStateKey);
    DYYYAvatarActionMode mode = DYYYAvatarActionModeForSettings(DYYYAvatarActionSnapshot(), kind);
    if (!state && mode == DYYYAvatarActionModeNative) return;
    if (state) {
        state = DYYYAvatarActionRetargetState(layer, state, kind, owner, root);
        if (!state) return;
    } else {
        state = DYYYAvatarActionNewState(layer, kind, owner); state.boundary = root;
        DYYYAvatarActionSave(state, DYYYAvatarLayerHidden, @(layer.hidden));
        DYYYAvatarActionSave(state, DYYYAvatarLayerContents, layer.contents);
        DYYYAvatarActionSave(state, DYYYAvatarLayerBackground, DYYYAvatarActionBoxColor(layer.backgroundColor));
        DYYYAvatarActionSave(state, DYYYAvatarLayerOpaque, @(layer.opaque));
        DYYYAvatarActionSave(state, DYYYAvatarLayerBorderWidth, @(layer.borderWidth));
        DYYYAvatarActionSave(state, DYYYAvatarLayerBorderColor, DYYYAvatarActionBoxColor(layer.borderColor));
        DYYYAvatarActionSave(state, DYYYAvatarLayerShadowOpacity, @(layer.shadowOpacity));
        DYYYAvatarActionSave(state, DYYYAvatarLayerShadowColor, DYYYAvatarActionBoxColor(layer.shadowColor));
        if ([layer isKindOfClass:CAShapeLayer.class]) {
            DYYYAvatarActionSave(state, DYYYAvatarLayerFillColor, DYYYAvatarActionBoxColor(((CAShapeLayer *)layer).fillColor));
            DYYYAvatarActionSave(state, DYYYAvatarLayerStrokeColor, DYYYAvatarActionBoxColor(((CAShapeLayer *)layer).strokeColor));
        }
    }
    state.backingLayer = backing || [layer.delegate isKindOfClass:UIView.class];
    if (state.mode != mode) DYYYAvatarActionApplyState(layer, state, mode);
    if (mode == DYYYAvatarActionModeNative) return;
    for (CALayer *child in [layer.sublayers copy]) {
        if (![child.delegate isKindOfClass:UIView.class]) DYYYAvatarActionBindLayer(child, kind, owner, root, NO);
    }
}
static void DYYYAvatarActionBindView(UIView *view, DYYYAvatarActionKind kind, id owner, UIView *root) {
    if (!view || DYYYAvatarActionIsAvatarRoot(view)) return;
    DYYYAvatarActionBoundary *exact = DYYYAvatarActionBoundaryForView(view);
    if (exact.registered) {
        // 不同 owner 的合法子边界是屏障，不能先删除它再继承父 kind。
        if (exact.protectedVisual || exact.ambiguous || exact.shared || exact.kind != kind) return;
        root = view; owner = exact.owner;
    }
    DYYYAvatarActionBoundary *scope = DYYYAvatarActionBoundaryForView(root);
    if (!DYYYAvatarActionObjectInsideBoundary(view, root) || !DYYYAvatarActionBoundaryHasLiveClaim(scope, root) ||
        !DYYYAvatarActionBoundaryPermits(scope.registered, scope.shared, scope.ambiguous, scope.protectedVisual, scope.kind, kind)) return;
    DYYYAvatarActionState *state = objc_getAssociatedObject(view, &kDYYYAvatarActionStateKey);
    DYYYAvatarActionMode mode = DYYYAvatarActionModeForSettings(DYYYAvatarActionSnapshot(), kind);
    if (!state && mode == DYYYAvatarActionModeNative) return;
    if (state) {
        state = DYYYAvatarActionRetargetState(view, state, kind, owner, root);
        if (!state) return;
    } else {
        state = DYYYAvatarActionNewState(view, kind, owner); state.boundary = root;
        DYYYAvatarActionSave(state, DYYYAvatarViewHidden, @(view.hidden));
        DYYYAvatarActionSave(state, DYYYAvatarViewInteraction, @(view.userInteractionEnabled));
        DYYYAvatarActionSave(state, DYYYAvatarViewBackground, view.backgroundColor);
    }
    DYYYAvatarActionBindLayer(view.layer, kind, owner, root, YES);
    if (state.mode != mode) DYYYAvatarActionApplyState(view, state, mode);
    if (mode == DYYYAvatarActionModeNative) return;
    for (UIView *child in [view.subviews copy]) DYYYAvatarActionBindView(child, kind, owner, root);
}
static BOOL DYYYAvatarActionNeedsReconcile(void) {
    return __atomic_load_n(&DYYYAvatarActionTopologyDirty, __ATOMIC_RELAXED) || DYYYAvatarActionBoundaryDirty ||
           DYYYAvatarActionBoundGeneration != __atomic_load_n(&gDYYYSettingsGeneration, __ATOMIC_RELAXED);
}
static void DYYYAvatarActionReconcileBoundaries(void) {
    if (DYYYAvatarActionReconciling || DYYYAvatarActionRegistrationDepth) return;
    if (DYYYAvatarActionActiveKinds(DYYYAvatarActionSnapshot()) == DYYYAvatarActionNone) {
        DYYYAvatarActionRefreshTrackedObjects();
        return;
    }
    DYYYAvatarActionReconciling = YES;
    @try {
        uint32_t generation = __atomic_load_n(&gDYYYSettingsGeneration, __ATOMIC_RELAXED);
        NSUInteger resolvedBefore = DYYYAvatarActionResolveCount;
        DYYYAvatarActionResolveBoundaries();
        BOOL needsBinding = resolvedBefore != DYYYAvatarActionResolveCount || DYYYAvatarActionBoundGeneration != generation;
        DYYYAvatarActionRefreshTrackedObjects();
        if (needsBinding && !__atomic_load_n(&DYYYAvatarActionTopologyDirty, __ATOMIC_RELAXED)) {
            for (UIView *view in DYYYAvatarActionBoundaryViews.allObjects) {
                DYYYAvatarActionBoundary *boundary = DYYYAvatarActionBoundaryForView(view);
                if (boundary.registered && !boundary.protectedVisual && !boundary.shared && !boundary.ambiguous)
                    DYYYAvatarActionBindView(view, boundary.kind, boundary.owner, view);
            }
            DYYYAvatarActionBoundGeneration = generation;
        }
    } @finally { DYYYAvatarActionReconciling = NO; }
}
static void DYYYAvatarActionScheduleReconcile(void) {
    BOOL expected = NO;
    if (!__atomic_compare_exchange_n(&DYYYAvatarActionReconcileScheduled, &expected, YES, NO, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        __atomic_store_n(&DYYYAvatarActionReconcileScheduled, NO, __ATOMIC_RELAXED);
        DYYYAvatarActionReconcileBoundaries();
    });
}
static void DYYYApplyAvatarActionSettingsSafely(id owner);
static void DYYYApplyAvatarActionSettingsForOwner(id owner) {
    NSArray *previous = objc_getAssociatedObject(owner, &kDYYYAvatarActionOwnerClaimsKey);
    NSMutableArray *claims = [NSMutableArray array];
    for (NSArray *group in DYYYAvatarActionSelectorGroups()) {
        for (NSString *name in group[1]) {
            UIView *view = DYYYAvatarViewForSelector(owner, NSSelectorFromString(name));
            if (!DYYYAvatarActionIsAvatarRoot(view)) DYYYAvatarActionRegisterClaim(owner, name, view, [group[0] unsignedIntegerValue], NO, claims);
        }
    }
    NSString *className = NSStringFromClass([owner class]);
    BOOL prompt = [className isEqualToString:@"AWEPlayInteractionFollowPromptView"];
    BOOL staticFollow = [className isEqualToString:@"AWEPlayInteractionStaticFollowAnimationView"];
    if (prompt || staticFollow) {
        DYYYAvatarActionRegisterClaim(owner, nil, owner, DYYYAvatarActionFollow, NO, claims);
        for (NSString *name in (prompt ? @[@"animationView"] : @[@"plusImageView", @"tickImageView"])) {
            DYYYAvatarActionRegisterClaim(owner, name, DYYYAvatarViewForSelector(owner, NSSelectorFromString(name)), DYYYAvatarActionFollow, NO, claims);
        }
    }
    for (NSString *name in @[@"avatarPicView", @"avatarPicContainerView", @"avatarPicAvatarButton", @"colorRingView", @"decorationView", @"liveMarkView", @"liveMarkHeadView", @"liveDecorateView"]) {
        DYYYAvatarActionRegisterClaim(owner, name, DYYYAvatarViewForSelector(owner, NSSelectorFromString(name)), DYYYAvatarActionNone, YES, claims);
    }
    if ([owner isKindOfClass:UIView.class] && DYYYAvatarActionIsAvatarRoot(owner)) DYYYAvatarActionRegisterClaim(owner, nil, owner, DYYYAvatarActionNone, YES, claims);
    id avatar = DYYYAvatarObjectForSelector(owner, NSSelectorFromString(@"userAvatarView"));
    if (avatar && avatar != owner) {
        if ([avatar isKindOfClass:NSClassFromString(@"AWEPlayInteractionUserAvatarView")]) DYYYApplyAvatarActionSettingsSafely(avatar);
        else if ([avatar isKindOfClass:UIView.class]) DYYYAvatarActionRegisterClaim(owner, @"userAvatarView", avatar, DYYYAvatarActionNone, YES, claims);
    }
    id context = DYYYAvatarObjectForSelector(owner, NSSelectorFromString(@"userAvatarContext"));
    if (context && context != owner) DYYYApplyAvatarActionSettingsSafely(context);
    UIView *element = DYYYAvatarViewForSelector(context, NSSelectorFromString(@"elementView"));
    if (element && element != owner && [element isKindOfClass:NSClassFromString(@"AWEPlayInteractionUserAvatarView")]) DYYYApplyAvatarActionSettingsSafely(element);
    for (DYYYAvatarActionBoundaryClaim *claim in previous) {
        if ([claims containsObject:claim]) continue;
        claim.valid = NO;
        [DYYYAvatarActionBoundaryForView(claim.view).claims removeObject:claim];
        __atomic_store_n(&DYYYAvatarActionTopologyDirty, YES, __ATOMIC_RELAXED);
    }
    objc_setAssociatedObject(owner, &kDYYYAvatarActionOwnerClaimsKey, claims, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    DYYYAvatarActionOwnerLifetime *lifetime = objc_getAssociatedObject(owner, &kDYYYAvatarActionOwnerLifetimeKey);
    if (!lifetime && claims.count) {
        lifetime = [DYYYAvatarActionOwnerLifetime new];
        objc_setAssociatedObject(owner, &kDYYYAvatarActionOwnerLifetimeKey, lifetime, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    lifetime.claims = claims;
}
static void DYYYApplyAvatarActionSettingsSafely(id owner) {
    if (!owner || objc_getAssociatedObject(owner, &kDYYYAvatarActionApplyingKey)) return;
    DYYYAvatarActionRegistrationDepth++;
    objc_setAssociatedObject(owner, &kDYYYAvatarActionApplyingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try { DYYYApplyAvatarActionSettingsForOwner(owner); }
    @finally {
        objc_setAssociatedObject(owner, &kDYYYAvatarActionApplyingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        DYYYAvatarActionRegistrationDepth--;
    }
    // owner/context/头像属于一次登记链，只有最外层且确实变化时才全局对齐。
    if (!DYYYAvatarActionRegistrationDepth && DYYYAvatarActionNeedsReconcile()) DYYYAvatarActionReconcileBoundaries();
}
static BOOL DYYYAvatarActionTargetDetached(id target) {
    if ([target isKindOfClass:UIView.class]) return !((UIView *)target).window;
    if ([target isKindOfClass:UIViewController.class]) return !((UIViewController *)target).viewIfLoaded.window;
    id context = DYYYAvatarObjectForSelector(target, NSSelectorFromString(@"userAvatarContext"));
    UIView *element = DYYYAvatarViewForSelector(context, NSSelectorFromString(@"elementView"));
    if (element) return !element.window;
    UIView *avatar = DYYYAvatarViewForSelector(target, NSSelectorFromString(@"userAvatarView"));
    return avatar ? !avatar.window : YES;
}
static void DYYYApplyAvatarActionSettingsWithRetry(id owner) {
    if (!owner || objc_getAssociatedObject(owner, &kDYYYAvatarActionApplyingKey)) return;
    DYYYAvatarActionEnsureTables();
    @synchronized (DYYYAvatarActionOwners) { [DYYYAvatarActionOwners addObject:owner]; }
    DYYYApplyAvatarActionSettingsSafely(owner);
    if (DYYYAvatarActionActiveKinds(DYYYAvatarActionSnapshot()) == DYYYAvatarActionNone || objc_getAssociatedObject(owner, &kDYYYAvatarActionPendingKey)) return;
    objc_setAssociatedObject(owner, &kDYYYAvatarActionPendingKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak id weakTarget = owner;
    dispatch_async(dispatch_get_main_queue(), ^{
        id target = weakTarget;
        if (!target) return;
        BOOL handedOff = NO;
        @try {
            if (DYYYAvatarActionTargetDetached(target)) return;
            DYYYApplyAvatarActionSettingsSafely(target);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                id next = weakTarget;
                if (!next) return;
                @try { if (!DYYYAvatarActionTargetDetached(next)) DYYYApplyAvatarActionSettingsSafely(next); }
                @finally { objc_setAssociatedObject(next, &kDYYYAvatarActionPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
            });
            handedOff = YES;
        } @finally {
            if (!handedOff) objc_setAssociatedObject(target, &kDYYYAvatarActionPendingKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}
static UIView *DYYYAvatarLegacyFollowBoundary(UIView *view) {
    Class cls = NSClassFromString(@"AWEPlayInteractionFollowPromptView");
    for (UIView *parent = view.superview; parent; parent = parent.superview) {
        if ([parent isKindOfClass:cls]) return parent;
        if (DYYYAvatarActionIsAvatarRoot(parent)) break;
    }
    return nil;
}
static void DYYYAvatarActionObjectTopologyDidChange(id object) {
    if (!object) return;
    DYYYAvatarActionState *state = objc_getAssociatedObject(object, &kDYYYAvatarActionStateKey);
    BOOL hasBoundary = [object isKindOfClass:UIView.class] && DYYYAvatarActionBoundaryForView(object) != nil;
    if (!state && !hasBoundary) return;
    __atomic_store_n(&DYYYAvatarActionTopologyDirty, YES, __ATOMIC_RELAXED);
    if (NSThread.isMainThread) {
        // 拓扑未确认时先释放历史压制，移出原 root 的对象无需等新 owner 来接管。
        DYYYAvatarActionBoundaryDirty = YES;
        DYYYAvatarActionRefreshTrackedObjects();
    }
    DYYYAvatarActionScheduleReconcile();
}
static void DYYYPrepareAvatarActionSubview(UIView *parent, UIView *child) {
    if (!child) return;
    // 必须在 orig 已建立真实父子关系之后调用。未标记 parent 也能撤销搬入对象的旧作用域。
    DYYYAvatarActionObjectTopologyDidChange(child);
    if (objc_getAssociatedObject(parent, &kDYYYAvatarActionStateKey) || DYYYAvatarActionBoundaryForView(parent))
        DYYYAvatarActionObjectTopologyDidChange(parent);
}
static void DYYYPrepareAvatarActionSublayer(CALayer *parent, CALayer *child) {
    if (!child) return;
    DYYYAvatarActionObjectTopologyDidChange(child);
    DYYYAvatarActionState *state = objc_getAssociatedObject(parent, &kDYYYAvatarActionStateKey);
    if (state && state.kind != DYYYAvatarActionNone) DYYYAvatarActionObjectTopologyDidChange(parent);
}
static void DYYYInstallAvatarActionRuntime(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        DYYYAvatarActionEnsureTables();
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                DYYYAvatarActionReconcileBoundaries();
                NSArray *owners;
                @synchronized (DYYYAvatarActionOwners) { owners = DYYYAvatarActionOwners.allObjects; }
                for (id owner in owners) if (!DYYYAvatarActionTargetDetached(owner)) DYYYApplyAvatarActionSettingsSafely(owner);
            });
        }];
    });
}
