#import <Foundation/Foundation.h>

@class AWEFeedTopBarContainer;
@class UIView;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void DYYYStartFPSOverlay(void);
FOUNDATION_EXPORT void DYYYFPSOverlayTopBarChanged(AWEFeedTopBarContainer *bar);
FOUNDATION_EXPORT void DYYYFPSOverlaySegmentChanged(UIView *segment);

NS_ASSUME_NONNULL_END
