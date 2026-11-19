#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Pairs two local files without writing to Photos or changing either input.
/// Completion runs once, asynchronously on the main queue. On success the caller owns
/// both temporary files; on failure both URLs are nil and an error is returned.
FOUNDATION_EXPORT void DYYYLikeBuildLivePhoto(NSURL *photoURL, NSURL *videoURL,
    void (^completion)(NSURL * _Nullable pairedPhotoURL, NSURL * _Nullable pairedVideoURL,
                       NSError * _Nullable error));

NS_ASSUME_NONNULL_END
