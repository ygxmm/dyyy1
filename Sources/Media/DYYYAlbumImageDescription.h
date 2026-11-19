#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Make a metadata-only copy, if ImageIO can preserve the original format and frames.
/// Caller owns the returned temporary file. On unsupported formats, keep the original.
FOUNDATION_EXPORT NSURL * _Nullable DYYYCopyImageWithAlbumDescription(NSURL *sourceURL, NSString * _Nullable description);

NS_ASSUME_NONNULL_END
