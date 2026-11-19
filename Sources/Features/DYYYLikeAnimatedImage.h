#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Converts an ImageIO-readable animated image to a temporary GIF.
 Requires at least two readable source frames; fails rather than emitting a still image.
 GIF's palette and timing granularity may differ from the source encoding.
 Call on a background thread. The caller owns and must remove the returned file.
 */
FOUNDATION_EXPORT NSURL * _Nullable DYYYLikeConvertAnimatedImageToGIF(NSURL *sourceURL, NSError ** _Nullable error);

NS_ASSUME_NONNULL_END
