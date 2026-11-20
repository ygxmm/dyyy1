#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, DYYYPlaybackQualityMode) {
    DYYYPlaybackQualityOriginal,
    DYYYPlaybackQualityHighest,
    DYYYPlaybackQualityPreferHDR,
};

// Missing/unknown preferences preserve the existing highest-bitrate default.
FOUNDATION_EXPORT NSString *DYYYNormalizedPlaybackQualityPolicy(id _Nullable preference);
FOUNDATION_EXPORT DYYYPlaybackQualityMode DYYYPlaybackQualityModeForSettings(BOOL enabled, id _Nullable preference);

// Selection helpers shared by addresses, prefetch and native playback models.
FOUNDATION_EXPORT id _Nullable DYYYSelectHighestPlaybackTier(NSArray * _Nullable tiers);
FOUNDATION_EXPORT id _Nullable DYYYSelectHDRPlaybackTier(NSArray * _Nullable tiers);

// Apply HDR preference only to a recognized native tier from this video's list.
// Nil/unsupported native results and the original stored cache remain unchanged.
FOUNDATION_EXPORT id _Nullable DYYYResolveNativePlaybackTier(id _Nullable nativeTier,
    NSArray * _Nullable tiers, DYYYPlaybackQualityMode mode, BOOL nativeHDRAllowed);

// Restore at most one HDR tier that the host exposes for manual selection and
// originally supplied for this same video. Retain all native fallback tiers.
FOUNDATION_EXPORT NSArray * _Nullable DYYYPlaybackTiersWithPreferredHDR(NSArray * _Nullable effective,
    NSArray * _Nullable manual, NSArray * _Nullable original);

NS_ASSUME_NONNULL_END
