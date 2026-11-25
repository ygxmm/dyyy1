#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DYYYOptionsSelectionView : NSObject

/**
 * 显示选项选择视图，返回当前选中值。
 * @param preferenceKey 存储选择结果的 NSUserDefaults 键
 */
+ (NSString *)showWithPreferenceKey:(NSString *)preferenceKey optionsArray:(NSArray<NSString *> *)optionsArray headerText:(NSString *)headerText onPresentingVC:(UIViewController *)presentingVC;

/**
 * 显示选项选择视图（选项改变时回调），返回当前选中值。
 * @param preferenceKey 存储选择结果的 NSUserDefaults 键
 */
+ (NSString *)showWithPreferenceKey:(NSString *)preferenceKey
                       optionsArray:(NSArray<NSString *> *)optionsArray
                         headerText:(NSString *)headerText
                     onPresentingVC:(UIViewController *)presentingVC
                   selectionChanged:(nullable void (^)(NSString *selectedValue))callback;

/**
 * 显示选项选择视图；selectionWillDismiss 在选择确认后、dismiss 动画开始前同步调用，
 * selectionChanged 保持原有关闭完成后回调时机。
 */
+ (NSString *)showWithPreferenceKey:(NSString *)preferenceKey
                       optionsArray:(NSArray<NSString *> *)optionsArray
                         headerText:(NSString *)headerText
                     onPresentingVC:(UIViewController *)presentingVC
                 selectionWillDismiss:(nullable void (^)(NSString *selectedValue))commitCallback
                   selectionChanged:(nullable void (^)(NSString *selectedValue))callback;

@end

NS_ASSUME_NONNULL_END
