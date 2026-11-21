#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

/// 无 UIKit 状态的几何计算，可在宿主机直接验证。
@interface DYYYFullscreenGeometry : NSObject
+ (CGRect)translateRect:(CGRect)rect fromReference:(CGRect)previous toReference:(CGRect)current;
+ (BOOL)isUsablePlayerFrame:(CGRect)frame;
+ (BOOL)awaitsNativePlayerFrame:(BOOL)awaiting adjusted:(BOOL)adjusted current:(CGRect)current lastApplied:(CGRect)lastApplied;
/// 仅撤销仍可精确归属于本模块的评论改写；普通播放或原生已更新几何时使用当前 frame。
+ (CGRect)nativePlayerFrameForLayout:(CGRect)current savedNative:(CGRect)native lastApplied:(CGRect)lastApplied adjusted:(BOOL)adjusted;
+ (CGRect)aspectFit:(CGSize)media inRect:(CGRect)viewport;
+ (CGAffineTransform)aspectFitTransformForBounds:(CGRect)bounds contentRect:(CGRect)content center:(CGPoint)center inRect:(CGRect)viewport;
+ (CGRect)unoccludedViewport:(CGRect)viewport top:(CGFloat)top panel:(CGRect)panel gap:(CGFloat)gap;
@end
