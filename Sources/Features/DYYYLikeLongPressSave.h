#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Registers preference observers after the user agreement; never writes defaults.
FOUNDATION_EXPORT void DYYYStartLikeLongPressSave(void);
/// Called from the existing AWEFeedVideoButton layout hook, not another lifecycle hook.
FOUNDATION_EXPORT void DYYYLikeLongPressSaveUpdateButton(UIButton *button);
FOUNDATION_EXPORT UITargetedPreview * _Nullable DYYYLikeLongPressSavePreview(UIButton *button);
FOUNDATION_EXPORT void DYYYLikeLongPressSaveWillDisplay(UIButton *button, id<UIContextMenuInteractionAnimating> _Nullable animator);
FOUNDATION_EXPORT void DYYYLikeLongPressSaveWillEnd(UIButton *button, id<UIContextMenuInteractionAnimating> _Nullable animator);
FOUNDATION_EXPORT UIImage * _Nullable DYYYLikeLongPressSaveSettingsIcon(CGSize size);

NS_ASSUME_NONNULL_END
