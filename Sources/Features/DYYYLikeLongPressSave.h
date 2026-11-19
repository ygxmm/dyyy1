#import <UIKit/UIKit.h>

@class AWEAwemeModel;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, DYYYMenuMediaSaveAction) {
    DYYYMenuMediaSaveCurrent,
    DYYYMenuMediaSaveAll,
    DYYYMenuMediaSaveCover,
    DYYYMenuMediaSaveVideo,
};

/// Shared by the existing DYYY panels; independent of the like-button switch.
FOUNDATION_EXPORT void DYYYSaveMenuMedia(AWEAwemeModel * _Nullable model, DYYYMenuMediaSaveAction action);

/// Registers preference observers after the user agreement; never writes defaults.
FOUNDATION_EXPORT void DYYYStartLikeLongPressSave(void);
/// Called from the existing AWEFeedVideoButton layout hook, not another lifecycle hook.
FOUNDATION_EXPORT void DYYYLikeLongPressSaveUpdateButton(UIButton *button);
FOUNDATION_EXPORT UITargetedPreview * _Nullable DYYYLikeLongPressSavePreview(UIButton *button);
FOUNDATION_EXPORT void DYYYLikeLongPressSaveWillDisplay(UIButton *button, id<UIContextMenuInteractionAnimating> _Nullable animator);
FOUNDATION_EXPORT void DYYYLikeLongPressSaveWillEnd(UIButton *button, id<UIContextMenuInteractionAnimating> _Nullable animator);
FOUNDATION_EXPORT UIImage * _Nullable DYYYLikeLongPressSaveSettingsIcon(CGSize size);

NS_ASSUME_NONNULL_END
