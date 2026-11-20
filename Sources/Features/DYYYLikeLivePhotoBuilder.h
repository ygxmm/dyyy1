#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Pairs two local files without writing to Photos or changing either input.
/// Copies a nonempty description at submission and replaces the MOV's Description tag;
/// nil/empty preserves existing descriptions. The image must already carry its caption.
/// Completion runs once, asynchronously on the main queue. On success the caller owns
/// both temporary files; on failure both URLs are nil and an error is returned.
FOUNDATION_EXPORT void DYYYLikeBuildLivePhoto(NSURL *photoURL, NSURL *videoURL,
    NSString * _Nullable albumDescription,
    void (^completion)(NSURL * _Nullable pairedPhotoURL, NSURL * _Nullable pairedVideoURL,
                       NSError * _Nullable error));

/// Whether this failure came from the motion clip rather than the still image.
FOUNDATION_EXPORT BOOL DYYYLikeLivePhotoHasVideoError(NSError * _Nullable error);

/// PhotoKit dates for a batch with two or more Live Photos; nil leaves dates alone.
/// Space pages by four seconds while keeping order and never dating them in the future.
FOUNDATION_EXPORT NSArray<NSDate *> * _Nullable DYYYLikeLivePhotoAlbumDates(NSArray<NSNumber *> *livePages, NSDate *latestDate);

NS_ASSUME_NONNULL_END
