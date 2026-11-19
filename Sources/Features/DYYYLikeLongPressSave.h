#import <UIKit/UIKit.h>

@class AWEAwemeModel;

NS_ASSUME_NONNULL_BEGIN

/// Use the shared photo/Live Photo pipeline from the existing action sheet.
/// Independent of the "长按点赞保存" switch.
FOUNDATION_EXPORT void DYYYSaveMediaFromLegacyMenu(AWEAwemeModel * _Nullable model, BOOL allPages);

/// Registers preference observers after the user agreement; never writes defaults.
FOUNDATION_EXPORT void DYYYStartLikeLongPressSave(void);
/// Called from the existing AWEFeedVideoButton layout hook, not another lifecycle hook.
FOUNDATION_EXPORT void DYYYLikeLongPressSaveUpdateButton(UIButton *button);
FOUNDATION_EXPORT UITargetedPreview * _Nullable DYYYLikeLongPressSavePreview(UIButton *button);
FOUNDATION_EXPORT void DYYYLikeLongPressSaveWillDisplay(UIButton *button, id<UIContextMenuInteractionAnimating> _Nullable animator);
FOUNDATION_EXPORT void DYYYLikeLongPressSaveWillEnd(UIButton *button, id<UIContextMenuInteractionAnimating> _Nullable animator);
FOUNDATION_EXPORT UIImage * _Nullable DYYYLikeLongPressSaveSettingsIcon(CGSize size);

NS_ASSUME_NONNULL_END
