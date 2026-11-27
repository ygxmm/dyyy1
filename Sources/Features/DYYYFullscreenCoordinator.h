#import <UIKit/UIKit.h>

/// 按播放页承载结构协调全屏、底栏与评论避让，保留来源例外；不修改 Metal 渲染视图。
@interface DYYYFullscreenCoordinator : NSObject
+ (NSString *)buildIdentifier;
+ (BOOL)usesRecommendedLayoutForController:(UIViewController *)controller;
+ (BOOL)usesHomeFeedLayoutForController:(UIViewController *)controller;
+ (BOOL)usesDetailLayoutForController:(UIViewController *)controller;
+ (BOOL)usesFullscreenLayoutForController:(UIViewController *)controller;
+ (CGRect)frameForPureModeContainer:(UIViewController *)controller proposed:(CGRect)frame;
+ (CGFloat)bottomInsetForDetail:(CGFloat)inset controller:(UIViewController *)controller;
+ (void)reconcileDetailPaging:(UIViewController *)controller;
+ (CGFloat)heightForDetailRow:(CGFloat)height table:(UITableView *)table controller:(UIViewController *)controller;
+ (BOOL)layoutNativeInteraction:(UIViewController *)controller;
+ (BOOL)isImageContentController:(UIViewController *)controller;
+ (void)registerTabBar:(UIView *)tabBar;
+ (void)invalidateGuides;
+ (CGFloat)bottomOccupiedHeightForView:(UIView *)view;
+ (void)layoutInteraction:(UIViewController *)controller;
+ (BOOL)isInsideNearbyPage:(UIViewController *)controller;
+ (void)layoutInformationLabel:(UIView *)label;
+ (void)rememberInteractionGuide:(UIViewController *)controller;
+ (CGRect)frameForInteractionView:(UIView *)view proposed:(CGRect)frame;
+ (CGRect)boundsForMediaHost:(UIView *)view proposed:(CGRect)bounds;
+ (CGPoint)centerForMediaHost:(UIView *)view proposed:(CGPoint)center;
+ (CGRect)frameForPlayer:(UIView *)player proposed:(CGRect)frame;
+ (void)preparePlayer:(UIView *)player;
+ (void)layoutPlayerContainer:(UIViewController *)controller;
+ (void)finishPlayer:(UIView *)player;
/// 接在静图视图原生 layoutSubviews 之后；setTransform 将原始参数交给协调器，再调用原生 setter。
+ (CGAffineTransform)transformForImageView:(UIView *)view proposed:(CGAffineTransform)transform;
+ (void)layoutImageView:(UIView *)view;
/// 可选：打开动作前预采样既有文案锚点，不注册评论，也不冻结几何。
+ (void)beginCommentInWindow:(UIWindow *)window;
/// 仅对该窗口当前已挂载且可见的真实半屏评论为真，与设置开关无关。
+ (BOOL)hasCommentInWindow:(UIWindow *)window;
+ (BOOL)hasCommentForInteractionController:(UIViewController *)controller;
/// 主线程。只传 AWECommentContainerViewController；出现/布局后报 YES，实际退出后报 NO。
+ (void)commentController:(UIViewController *)controller visible:(BOOL)visible;
@end
