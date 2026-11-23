// 必须在真实 runtime 头之后、同一 TU 内包含，以调用其 static helper。
@implementation UIColor
+ (instancetype)colorWithRed:(CGFloat)r green:(CGFloat)g blue:(CGFloat)b alpha:(CGFloat)a {
    UIColor *color = [self new];
    color->_dyyyColor = CGColorCreateGenericRGB(r, g, b, a);
    return color;
}
+ (instancetype)clearColor {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ color = [self colorWithRed:0 green:0 blue:0 alpha:0]; });
    return color;
}
- (CGColorRef)CGColor { return _dyyyColor; }
- (void)dealloc { if (_dyyyColor) CGColorRelease(_dyyyColor); }
@end

// 真 CAShapeLayer 的测试 subclass：只适配唯一 production setter 的头像分支。
// 没有复制 registry/binding/restore；其他黑条、收藏 gate 不在此夹具内。
@interface DYYYAvatarTestLayer : CAShapeLayer
@property(nonatomic) NSUInteger dyyyHiddenWrites;
@end
@implementation DYYYAvatarTestLayer
#define DYYY_TEST_LAYER_SETTER(method, type, argument, property, boxed, forced, predicate) \
- (void)method:(type)argument { \
    if (DYYYAvatarActionIsOwnWrite(self, property)) { [super method:argument]; return; } \
    DYYYAvatarActionState *state = DYYYAvatarActionStateForObject(self); \
    if (state) DYYYAvatarActionRecordNative(self, state, property, boxed); \
    BOOL suppress = predicate(state); \
    if (state) { DYYY_AVATAR_WRITE(self, property, [super method:(suppress ? forced : argument)];); } \
    else { [super method:argument]; } \
}
- (void)setHidden:(BOOL)hidden {
    self.dyyyHiddenWrites++;
    if (DYYYAvatarActionIsOwnWrite(self, DYYYAvatarLayerHidden)) { [super setHidden:hidden]; return; }
    DYYYAvatarActionState *state = DYYYAvatarActionStateForObject(self);
    if (state) DYYYAvatarActionRecordNative(self, state, DYYYAvatarLayerHidden, @(hidden));
    if (state) { DYYY_AVATAR_WRITE(self, DYYYAvatarLayerHidden, [super setHidden:(DYYYAvatarActionHideLayer(state) ? YES : hidden)];); }
    else { [super setHidden:hidden]; }
}
DYYY_TEST_LAYER_SETTER(setContents, id, contents, DYYYAvatarLayerContents, contents, nil, DYYYAvatarActionClearChrome)
DYYY_TEST_LAYER_SETTER(setBackgroundColor, CGColorRef, color, DYYYAvatarLayerBackground, DYYYAvatarActionBoxColor(color), UIColor.clearColor.CGColor, DYYYAvatarActionClearChrome)
DYYY_TEST_LAYER_SETTER(setOpaque, BOOL, opaque, DYYYAvatarLayerOpaque, @(opaque), NO, DYYYAvatarActionClearChrome)
DYYY_TEST_LAYER_SETTER(setBorderWidth, CGFloat, width, DYYYAvatarLayerBorderWidth, @(width), 0, DYYYAvatarActionClearChrome)
DYYY_TEST_LAYER_SETTER(setBorderColor, CGColorRef, color, DYYYAvatarLayerBorderColor, DYYYAvatarActionBoxColor(color), UIColor.clearColor.CGColor, DYYYAvatarActionClearChrome)
DYYY_TEST_LAYER_SETTER(setShadowOpacity, float, opacity, DYYYAvatarLayerShadowOpacity, @(opacity), 0, DYYYAvatarActionClearChrome)
DYYY_TEST_LAYER_SETTER(setShadowColor, CGColorRef, color, DYYYAvatarLayerShadowColor, DYYYAvatarActionBoxColor(color), UIColor.clearColor.CGColor, DYYYAvatarActionClearChrome)
DYYY_TEST_LAYER_SETTER(setFillColor, CGColorRef, color, DYYYAvatarLayerFillColor, DYYYAvatarActionBoxColor(color), UIColor.clearColor.CGColor, DYYYAvatarActionClearChrome)
DYYY_TEST_LAYER_SETTER(setStrokeColor, CGColorRef, color, DYYYAvatarLayerStrokeColor, DYYYAvatarActionBoxColor(color), UIColor.clearColor.CGColor, DYYYAvatarActionClearChrome)
#undef DYYY_TEST_LAYER_SETTER
- (void)addSublayer:(CALayer *)layer {
    [super addSublayer:layer];
    DYYYPrepareAvatarActionSublayer(self, layer);
}
- (void)removeFromSuperlayer {
    [super removeFromSuperlayer];
    DYYYAvatarActionObjectTopologyDidChange(self);
}
@end

@implementation UIView
@synthesize alpha = _alpha, bounds = _bounds, frame = _frame;
- (instancetype)init {
    if ((self = [super init])) {
        _userInteractionEnabled = YES; _alpha = 1;
        _dyyySubviews = [NSMutableArray array];
        _layer = [DYYYAvatarTestLayer layer]; _layer.delegate = self;
    }
    return self;
}
- (BOOL)isHidden { return _hidden; }
- (BOOL)isUserInteractionEnabled { return _userInteractionEnabled; }
- (UIColor *)backgroundColor { return _backgroundColor; }
- (CALayer *)layer { return _layer; }
- (NSArray *)subviews { return [_dyyySubviews copy]; }
- (UIView *)superview { return _superview; }
- (UIWindow *)window { return [self isKindOfClass:UIWindow.class] ? (UIWindow *)self : _superview.window; }
- (NSUInteger)dyyyHiddenWrites { return _dyyyHiddenWrites; }
- (NSUInteger)dyyyInteractionWrites { return _dyyyInteractionWrites; }
- (void)dyyyOrigHidden:(BOOL)hidden {
    _dyyyHiddenWrites++; _hidden = hidden;
    // 对应 UIView 原生 setter 派生到自身 backing layer 的写入。
    _layer.hidden = hidden;
    if (self.dyyyOnOrigWrite) self.dyyyOnOrigWrite(self, DYYYAvatarViewHidden);
}
- (void)dyyyOrigInteraction:(BOOL)enabled {
    _dyyyInteractionWrites++; _userInteractionEnabled = enabled;
    if (self.dyyyOnOrigWrite) self.dyyyOnOrigWrite(self, DYYYAvatarViewInteraction);
}
- (void)dyyyOrigBackground:(UIColor *)color {
    _backgroundColor = color; _layer.backgroundColor = color.CGColor;
    if (self.dyyyOnOrigWrite) self.dyyyOnOrigWrite(self, DYYYAvatarViewBackground);
}
- (void)setHidden:(BOOL)hidden {
    if (DYYYAvatarActionIsOwnWrite(self, DYYYAvatarViewHidden)) { [self dyyyOrigHidden:hidden]; return; }
    DYYYAvatarActionState *state = DYYYAvatarActionStateForObject(self);
    if (!state) { [self dyyyOrigHidden:hidden]; return; }
    DYYYAvatarActionRecordNative(self, state, DYYYAvatarViewHidden, @(hidden));
    DYYY_AVATAR_WRITE(self, DYYYAvatarViewHidden, [self dyyyOrigHidden:(DYYYAvatarActionHideView(state) ? YES : hidden)];);
}
- (void)setUserInteractionEnabled:(BOOL)enabled {
    if (DYYYAvatarActionIsOwnWrite(self, DYYYAvatarViewInteraction)) { [self dyyyOrigInteraction:enabled]; return; }
    DYYYAvatarActionState *state = DYYYAvatarActionStateForObject(self);
    if (!state) { [self dyyyOrigInteraction:enabled]; return; }
    DYYYAvatarActionRecordNative(self, state, DYYYAvatarViewInteraction, @(enabled));
    DYYY_AVATAR_WRITE(self, DYYYAvatarViewInteraction, [self dyyyOrigInteraction:(DYYYAvatarActionBlocksViewInteraction(state) ? NO : enabled)];);
}
- (void)setBackgroundColor:(UIColor *)color {
    if (DYYYAvatarActionIsOwnWrite(self, DYYYAvatarViewBackground)) { [self dyyyOrigBackground:color]; return; }
    DYYYAvatarActionState *state = DYYYAvatarActionStateForObject(self);
    if (!state) { [self dyyyOrigBackground:color]; return; }
    DYYYAvatarActionRecordNative(self, state, DYYYAvatarViewBackground, color);
    DYYY_AVATAR_WRITE(self, DYYYAvatarViewBackground, [self dyyyOrigBackground:(DYYYAvatarActionClearChrome(state) ? UIColor.clearColor : color)];);
}
- (BOOL)isDescendantOfView:(UIView *)view {
    for (UIView *candidate = self; candidate; candidate = candidate.superview) if (candidate == view) return YES;
    return NO;
}
- (void)removeFromSuperview {
    UIView *parent = _superview;
    if (parent) [parent->_dyyySubviews removeObjectIdenticalTo:self];
    [_layer removeFromSuperlayer]; _superview = nil;
    DYYYAvatarActionObjectTopologyDidChange(self);
}
- (void)addSubview:(UIView *)view {
    [view removeFromSuperview];
    view->_superview = self; [_dyyySubviews addObject:view];
    [_layer addSublayer:view.layer];
    // production didAddSubview 在 orig 后执行 Prepare，树关系已存在。
    DYYYPrepareAvatarActionSubview(self, view);
}
@end
@implementation UIWindow
@end
@implementation UIViewController
@end
