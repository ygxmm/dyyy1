#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Pure selection helpers shared by playURL and currentPlayingURLKey.
FOUNDATION_EXPORT id _Nullable DYYYSelectHighestPlaybackTier(NSArray * _Nullable tiers);
FOUNDATION_EXPORT id _Nullable DYYYSelectHDRPlaybackTier(NSArray * _Nullable tiers);

// Restore at most one HDR tier that the host exposes for manual selection and
// originally supplied for this same video. Retain all native fallback tiers.
FOUNDATION_EXPORT NSArray * _Nullable DYYYPlaybackTiersWithPreferredHDR(NSArray * _Nullable effective,
    NSArray * _Nullable manual, NSArray * _Nullable original);

NS_ASSUME_NONNULL_END
