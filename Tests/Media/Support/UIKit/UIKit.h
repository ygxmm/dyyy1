#pragma once
// 仅供 macOS Foundation + QuartzCore 状态回归；不是 UIKit，也不实现 hitTest。
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dispatch/dispatch.h>

@class UIWindow;
@interface UIColor : NSObject {
    CGColorRef _dyyyColor;
}
@property(nonatomic, readonly) CGColorRef CGColor;
+ (instancetype)clearColor;
+ (instancetype)colorWithRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha;
@end

@interface UIView : NSObject <CALayerDelegate> {
    BOOL _hidden, _userInteractionEnabled;
    CGFloat _alpha;
    CGRect _bounds, _frame;
    UIColor *_backgroundColor;
    CALayer *_layer;
    NSMutableArray<UIView *> *_dyyySubviews;
    __weak UIView *_superview;
    NSUInteger _dyyyHiddenWrites, _dyyyInteractionWrites;
}
@property(nonatomic, getter=isHidden) BOOL hidden;
@property(nonatomic, getter=isUserInteractionEnabled) BOOL userInteractionEnabled;
@property(nonatomic, strong) UIColor *backgroundColor;
@property(nonatomic) CGFloat alpha;
@property(nonatomic) CGRect bounds;
@property(nonatomic) CGRect frame;
@property(nonatomic, readonly) CALayer *layer;
@property(nonatomic, readonly) NSArray<UIView *> *subviews;
@property(nonatomic, readonly) UIView *superview;
@property(nonatomic, readonly) UIWindow *window;
@property(nonatomic, readonly) NSUInteger dyyyHiddenWrites;
@property(nonatomic, readonly) NSUInteger dyyyInteractionWrites;
// 在薄 orig setter 内同步调用，用于模拟宿主重入另一对象。
@property(nonatomic, copy) void (^dyyyOnOrigWrite)(UIView *, NSUInteger);
- (void)addSubview:(UIView *)view;
- (void)removeFromSuperview;
- (BOOL)isDescendantOfView:(UIView *)view;
@end
@interface UIWindow : UIView
@end
@interface UIViewController : NSObject
@property(nonatomic, strong) UIView *viewIfLoaded;
@end
