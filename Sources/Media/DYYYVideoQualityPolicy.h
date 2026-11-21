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

// 过滤与选流共用 HDR 标记判据；原始字典仅检查当前作品的 video 结构。
FOUNDATION_EXPORT BOOL DYYYPlaybackTierHasHDRMetadata(id _Nullable tier);
FOUNDATION_EXPORT BOOL DYYYAwemeRawVideoHasHDRMetadata(id _Nullable rawAweme);

// Usable issued sources only; bitrate first, real dimensions break equal rates.
FOUNDATION_EXPORT id _Nullable DYYYSelectHighestPlaybackTier(NSArray * _Nullable tiers);
FOUNDATION_EXPORT id _Nullable DYYYSelectHDRPlaybackTier(NSArray * _Nullable tiers);

// One policy for addresses, cache reads and final native selection. HDR denial
// excludes HDR candidates; PreferHDR without HDR falls back to highest bitrate.
FOUNDATION_EXPORT id _Nullable DYYYSelectPlaybackTier(NSArray * _Nullable tiers,
    DYYYPlaybackQualityMode mode, BOOL nativeHDRAllowed);

// Apply either enabled policy only to a recognized native tier from this video.
// Nil/unsupported native results and the original stored cache remain unchanged.
FOUNDATION_EXPORT id _Nullable DYYYResolveNativePlaybackTier(id _Nullable nativeTier,
    NSArray * _Nullable tiers, DYYYPlaybackQualityMode mode, BOOL nativeHDRAllowed);

// Resolve against the selector-owned video, not a global visible item. This
// bridge is shared by cache reads and BDSim's public selection boundaries.
FOUNDATION_EXPORT id _Nullable DYYYResolveNativePlaybackTierForVideo(id _Nullable nativeTier,
    id _Nullable video, DYYYPlaybackQualityMode mode, BOOL nativeHDRAllowed);

// Restore at most one HDR tier that the host exposes for manual selection and
// originally supplied for this same video. Retain all native fallback tiers.
FOUNDATION_EXPORT NSArray * _Nullable DYYYPlaybackTiersWithPreferredHDR(NSArray * _Nullable effective,
    NSArray * _Nullable manual, NSArray * _Nullable original);

NS_ASSUME_NONNULL_END
