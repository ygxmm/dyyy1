#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Returns platform-provided URLs unchanged; known URL markers cannot detect baked-in watermarks.
FOUNDATION_EXPORT NSArray<NSURL *> *DYYYMediaSourceURLs(id _Nullable value);
FOUNDATION_EXPORT NSArray<NSURL *> *DYYYMediaSourceHighestVideoURLs(id _Nullable video);
FOUNDATION_EXPORT NSArray<NSURL *> *DYYYMediaSourceCoverURLs(id _Nullable video);
FOUNDATION_EXPORT NSArray<NSURL *> *DYYYMediaSourceImageURLs(id _Nullable image, id _Nullable matchedOriginal);

NS_ASSUME_NONNULL_END
