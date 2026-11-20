#import "../../Sources/Media/DYYYVideoQualityPolicy.h"
#import "../../Sources/Core/DYYYConstants.h"
#include <stdio.h>
#import <objc/runtime.h>

// Foundation-only host doubles, not a real Aweme/BDSim integration test.
@interface DYYYQualityAddressFixture : NSObject
@property (nonatomic, copy) NSArray *originURLList;
@end
@implementation DYYYQualityAddressFixture
@end

@interface DYYYQualityTierFixture : NSObject
@property (nonatomic, copy) NSString *gearName;
@property (nonatomic, strong) NSNumber *bitrate;
@property (nonatomic, copy) NSString *hdrType;
@property (nonatomic, strong) id playAddr;
@end
@implementation DYYYQualityTierFixture
@end

@interface DYYYQualityVideoFixture : NSObject
@property (nonatomic, copy) NSArray *nativeTiers;
@property (nonatomic, strong) id preloadedBSModel;
@property (nonatomic, assign) NSUInteger tierReads;
@property (nonatomic, assign) BOOL throwOnRead;
- (NSArray *)bitrateModels;
@end
@implementation DYYYQualityVideoFixture
- (NSArray *)bitrateModels {
    self.tierReads++;
    if (self.throwOnRead) [NSException raise:@"DYYYTestGetter" format:@"unavailable native list"];
    return self.nativeTiers;
}
@end

static DYYYQualityTierFixture *DYYYQualityObjectTier(Class addressClass, NSString *gear, NSInteger rate, NSString *hdr, NSString *url) {
    DYYYQualityAddressFixture *address = [addressClass new];
    address.originURLList = url ? @[url] : @[];
    DYYYQualityTierFixture *tier = [DYYYQualityTierFixture new];
    tier.gearName = gear;
    tier.bitrate = @(rate);
    tier.hdrType = hdr;
    tier.playAddr = address;
    return tier;
}

static NSDictionary *DYYYQualityTier(NSString *gear, NSInteger rate, id hdr, NSString *url) {
    return @{@"gearName":gear, @"bitrate":@(rate), @"hdrType":hdr, @"hdrBit":@"10",
        @"playAddr":url ? @{@"originURLList":@[url]} : @{} };
}

static int DYYYVerifyQuality(BOOL pass, const char *meaning) {
    printf("%s video quality: %s\n", pass ? "PASS" : "FAIL", meaning);
    return !pass;
}

int DYYYRunVideoQualityPolicyTests(void) {
    // These host doubles require a fresh macOS test process, never Aweme.
    if (NSClassFromString(@"AWEURLModel")) return DYYYVerifyQuality(NO, "host fixture requires an isolated test process");
    int failed = 0;
    failed += DYYYVerifyQuality(DYYYPlaybackQualityModeForSettings(NO, DYYY_VIDEO_QUALITY_PREFER_HDR) == DYYYPlaybackQualityOriginal,
        "master switch off always preserves native selection");
    failed += DYYYVerifyQuality(DYYYPlaybackQualityModeForSettings(YES, DYYY_VIDEO_QUALITY_OFF) == DYYYPlaybackQualityOriginal &&
        [DYYYNormalizedPlaybackQualityPolicy(DYYY_VIDEO_QUALITY_OFF) isEqual:DYYY_VIDEO_QUALITY_OFF],
        "explicit Off is a native mode and remains visible in both settings menus");
    failed += DYYYVerifyQuality(DYYYPlaybackQualityModeForSettings(YES, nil) == DYYYPlaybackQualityHighest &&
        DYYYPlaybackQualityModeForSettings(YES, @"unknown") == DYYYPlaybackQualityHighest &&
        [DYYYNormalizedPlaybackQualityPolicy(nil) isEqual:DYYY_VIDEO_QUALITY_HIGHEST] &&
        [DYYYNormalizedPlaybackQualityPolicy(@42) isEqual:DYYY_VIDEO_QUALITY_HIGHEST],
        "missing or invalid legacy preferences keep the original highest-bitrate default");
    failed += DYYYVerifyQuality(DYYYPlaybackQualityModeForSettings(YES, DYYY_VIDEO_QUALITY_PREFER_HDR) == DYYYPlaybackQualityPreferHDR &&
        [DYYYNormalizedPlaybackQualityPolicy(DYYY_VIDEO_QUALITY_PREFER_HDR) isEqual:DYYY_VIDEO_QUALITY_PREFER_HDR],
        "HDR selection is distinct from native and original highest-bitrate modes");
    NSDictionary *sdr = DYYYQualityTier(@"1440_1_1", 3062288, @"", @"https://cdn.example/sdr?sig=a%2Bb");
    NSDictionary *hdr = DYYYQualityTier(@"adapt_lowest_1440_1", 2952206, @"3", @"https://cdn.example/hdr?sig=c%2Bd");
    NSDictionary *hdrSmall = DYYYQualityTier(@"adapt_lowest_1080_1", 1424498, @3, @"https://cdn.example/hdr-1080");
    NSDictionary *sdrSmall = DYYYQualityTier(@"1080_1_1", 1412432, @0, @"https://cdn.example/sdr-1080");
    NSArray *stock = @[sdr, sdrSmall];
    NSArray *issued = @[hdr, sdr, hdrSmall, sdrSmall];
    NSArray *choices = DYYYPlaybackTiersWithPreferredHDR(stock, issued, issued);
    failed += DYYYVerifyQuality(DYYYSelectHighestPlaybackTier(issued) == sdr, "original policy still picks highest bitrate, not HDR");
    failed += DYYYVerifyQuality([choices isEqualToArray:@[sdr,sdrSmall,hdr]] && [stock isEqualToArray:@[sdr,sdrSmall]],
        "restore one native manual HDR tier with SDR fallbacks unmodified and in order");
    NSDictionary *sameGearSDR = DYYYQualityTier(@"adapt_lowest_1440_1", 3000000, @0, @"https://cdn.example/same-gear-sdr");
    NSDictionary *sameGearHDR = DYYYQualityTier(@"adapt_lowest_1440_1", 2800000, @3, @"https://cdn.example/same-gear-hdr");
    NSDictionary *sameGearHDRSmall = DYYYQualityTier(@"adapt_lowest_1080_1", 1400000, @3, @"https://cdn.example/same-gear-hdr-small");
    NSArray *sameGearEffective = @[sameGearSDR, sdrSmall];
    NSArray *sameGearNative = @[sameGearSDR, sameGearHDR, sdrSmall, sameGearHDRSmall];
    NSArray *sameGearChoices = DYYYPlaybackTiersWithPreferredHDR(sameGearEffective, sameGearNative, sameGearNative);
    failed += DYYYVerifyQuality(sameGearChoices.count == 3 && sameGearChoices[0] == sameGearSDR &&
        sameGearChoices[1] == sdrSmall && sameGearChoices[2] == sameGearHDR &&
        DYYYSelectHDRPlaybackTier(sameGearChoices) == sameGearHDR,
        "restore HDR when SDR and HDR share a gear name, preserving SDR order");
    failed += DYYYVerifyQuality(DYYYSelectHDRPlaybackTier(choices) == hdr, "prefer top HDR despite SDR having a higher bitrate");
    NSDictionary *nativeCache = sameGearSDR;
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTier(nativeCache, sameGearChoices, DYYYPlaybackQualityPreferHDR, YES) == sameGearHDR,
        "select-once cached SDR resolves to the real HDR model despite an identical gear name");
    failed += DYYYVerifyQuality(nativeCache == sameGearSDR && [sameGearEffective isEqualToArray:@[sameGearSDR,sdrSmall]] &&
        DYYYResolveNativePlaybackTier(nativeCache, sameGearChoices, DYYYPlaybackQualityOriginal, YES) == sameGearSDR,
        "HDR reads never mutate the native cache and Off immediately reveals the original cached SDR");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTier(sameGearHDR, sameGearChoices, DYYYPlaybackQualityOriginal, YES) == sameGearHDR,
        "Off preserves an HDR model that the host itself selected");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTier(sameGearSDR, sameGearChoices, DYYYPlaybackQualityHighest, YES) == sameGearSDR,
        "native model hooks do not change the legacy highest-bitrate mode");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTier(sameGearSDR, sameGearChoices, DYYYPlaybackQualityPreferHDR, NO) == sameGearSDR,
        "system or native HDR denial preserves the native result");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTier(nil, sameGearChoices, DYYYPlaybackQualityPreferHDR, YES) == nil,
        "an empty native cache is not fabricated and native first-selection bookkeeping can run");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTier(sameGearSDR, sameGearEffective, DYYYPlaybackQualityPreferHDR, YES) == sameGearSDR &&
        DYYYResolveNativePlaybackTier(sameGearSDR, nil, DYYYPlaybackQualityPreferHDR, YES) == sameGearSDR,
        "no usable HDR or no native tier list keeps the original result");
    NSDictionary *nativeCopy = [sameGearSDR mutableCopy];
    failed += DYYYVerifyQuality(nativeCopy != sameGearSDR &&
        DYYYResolveNativePlaybackTier(nativeCopy, sameGearChoices, DYYYPlaybackQualityPreferHDR, YES) == sameGearHDR,
        "source identity survives native tier copies without matching by gear alone");
    NSDictionary *foreignSDR = DYYYQualityTier(@"adapt_lowest_1440_1", 3000000, @0, @"https://cdn.example/other-video");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTier(foreignSDR, sameGearChoices, DYYYPlaybackQualityPreferHDR, YES) == foreignSDR,
        "same gear and rate with a different source cannot override an unrelated native model");
    NSObject *unsupported = [NSObject new];
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTier(unsupported, sameGearChoices, DYYYPlaybackQualityPreferHDR, YES) == unsupported,
        "an opaque or detached DASH native result remains native");
    NSDictionary *unusableNative = DYYYQualityTier(@"adapt_lowest_1440_1", 3000000, @0, nil);
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTier(unusableNative, @[unusableNative,sameGearHDR], DYYYPlaybackQualityPreferHDR, YES) == unusableNative,
        "native results without a usable source are never made playable");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTier(sameGearHDR, sameGearChoices, DYYYPlaybackQualityPreferHDR, YES) == sameGearHDR,
        "the already chosen highest HDR model stays the same object");
    failed += DYYYVerifyQuality(DYYYSelectHDRPlaybackTier(stock) == nil && DYYYSelectHighestPlaybackTier(stock) == sdr,
        "no HDR evidence (including 10-bit alone) falls back to the original ranking");
    failed += DYYYVerifyQuality(DYYYPlaybackTiersWithPreferredHDR(stock, stock, issued) == stock &&
        DYYYPlaybackTiersWithPreferredHDR(stock, issued, nil) == stock, "do not restore an HDR tier without both native manual and source entries");
    failed += DYYYVerifyQuality(DYYYPlaybackTiersWithPreferredHDR(choices, issued, issued) == choices,
        "does not duplicate an already active gear");
    NSDictionary *differentSource = DYYYQualityTier(@"adapt_lowest_1440_1", 2952206, @"3", @"https://cdn.example/unrelated");
    failed += DYYYVerifyQuality(DYYYPlaybackTiersWithPreferredHDR(stock, @[differentSource], issued) == stock,
        "matching gear and rate cannot restore an unrelated source URL");
    NSDictionary *bad = DYYYQualityTier(@"adapt_lowest_2160_1", 9000000, @"3", nil);
    NSDictionary *unproven = DYYYQualityTier(@"adapt_lowest_2160_1", 9000000, @"3invalid", @"https://cdn.example/unknown");
    failed += DYYYVerifyQuality(DYYYSelectHDRPlaybackTier(@[bad, unproven, hdrSmall]) == hdrSmall,
        "invalid URL or malformed HDR type is not a usable HDR tier");
    NSDictionary *sameRate = DYYYQualityTier(@"1080_1_1", 3062288, @0, @"https://cdn.example/equal");
    failed += DYYYVerifyQuality(DYYYSelectHighestPlaybackTier(@[sameRate,sdr]) == sdr,
        "equal bitrates use the original resolution tie-break");
    failed += DYYYVerifyQuality(DYYYSelectHighestPlaybackTier(nil) == nil && DYYYSelectHDRPlaybackTier(@[]) == nil,
        "missing and empty lists fall through to stock playback");
    // Register a synthetic host address subclass only after the dictionary
    // cases, so this matrix also exercises the production AWEURLModel guard.
    Class addressClass = objc_allocateClassPair(DYYYQualityAddressFixture.class, "AWEURLModel", 0);
    if (!addressClass) return failed + DYYYVerifyQuality(NO, "synthetic host address class allocation succeeds");
    objc_registerClassPair(addressClass);
    DYYYQualityTierFixture *nativeObject = DYYYQualityObjectTier(addressClass, @"1440_1_1", 5857463, @"", @"https://cdn.example/775547-sdr?sig=a%2Bb");
    DYYYQualityTierFixture *hdrObject = DYYYQualityObjectTier(addressClass, @"adapt_lowest_1440_1", 4886602, @"3", @"https://cdn.example/775547-hdr?sig=c%2Bd");
    DYYYQualityVideoFixture *selectorVideo = [DYYYQualityVideoFixture new];
    selectorVideo.nativeTiers = @[nativeObject, hdrObject];
    // This mirrors the failed samples: BDSim has a native result while the AWE
    // preloaded ivar is empty. The BDSim result must not depend on that getter.
    failed += DYYYVerifyQuality(selectorVideo.preloadedBSModel == nil &&
        DYYYResolveNativePlaybackTierForVideo(nativeObject, selectorVideo, DYYYPlaybackQualityPreferHDR, YES) == hdrObject,
        "selector-owned native SDR resolves to HDR even with no AWE preloaded cache");
    failed += DYYYVerifyQuality(selectorVideo.preloadedBSModel == nil &&
        [selectorVideo.nativeTiers isEqualToArray:@[nativeObject, hdrObject]] && [nativeObject.hdrType isEqual:@""],
        "native objects, original cache and fallback array remain unmodified");
    DYYYQualityTierFixture *nativeObjectCopy = DYYYQualityObjectTier(addressClass, nativeObject.gearName, nativeObject.bitrate.integerValue,
        nativeObject.hdrType, @"https://cdn.example/775547-sdr?sig=a%2Bb");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(nativeObjectCopy, selectorVideo, DYYYPlaybackQualityPreferHDR, YES) == hdrObject,
        "native object copy matches by exact issued URL rather than object address");
    DYYYQualityTierFixture *wrongSignature = DYYYQualityObjectTier(addressClass, nativeObject.gearName, nativeObject.bitrate.integerValue,
        nativeObject.hdrType, @"https://cdn.example/775547-sdr?sig=DIFFERENT");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(wrongSignature, selectorVideo, DYYYPlaybackQualityPreferHDR, YES) == wrongSignature,
        "identical object metadata with a different signed URL stays native");
    DYYYQualityVideoFixture *otherVideo = [DYYYQualityVideoFixture new];
    otherVideo.nativeTiers = @[wrongSignature, hdrObject];
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(nativeObject, otherVideo, DYYYPlaybackQualityPreferHDR, YES) == nativeObject,
        "selector ownership cannot be borrowed from the visible or another video");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(hdrObject, selectorVideo, DYYYPlaybackQualityPreferHDR, YES) == hdrObject,
        "an already selected native HDR object is not cloned or relabeled");
    NSUInteger readsBefore = selectorVideo.tierReads;
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(nativeObject, selectorVideo, DYYYPlaybackQualityOriginal, YES) == nativeObject &&
        selectorVideo.tierReads == readsBefore, "Off forwards original result without reading candidate getters");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(nativeObject, selectorVideo, DYYYPlaybackQualityHighest, YES) == nativeObject &&
        selectorVideo.tierReads == readsBefore, "legacy highest mode leaves native selector result untouched");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(nativeObject, selectorVideo, DYYYPlaybackQualityPreferHDR, NO) == nativeObject &&
        selectorVideo.tierReads == readsBefore, "HDR denial does not inspect or override the native candidate list");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(nil, selectorVideo, DYYYPlaybackQualityPreferHDR, YES) == nil &&
        selectorVideo.tierReads == readsBefore, "a nil native selector result is not synthesized from candidates");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(nativeObject, nil, DYYYPlaybackQualityPreferHDR, YES) == nativeObject,
        "a released weak selector video keeps its original native result");
    selectorVideo.nativeTiers = @[nativeObject];
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(nativeObject, selectorVideo, DYYYPlaybackQualityPreferHDR, YES) == nativeObject,
        "no HDR candidates remains a native SDR fallback");
    selectorVideo.throwOnRead = YES;
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(nativeObject, selectorVideo, DYYYPlaybackQualityPreferHDR, YES) == nativeObject,
        "an unavailable native list getter fails closed to the native result");
    selectorVideo.throwOnRead = NO;
    DYYYQualityTierFixture *wrongAddressClass = DYYYQualityObjectTier(DYYYQualityAddressFixture.class, @"1080_1_1", 1, @"", @"https://cdn.example/opaque");
    selectorVideo.nativeTiers = @[wrongAddressClass, hdrObject];
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(wrongAddressClass, selectorVideo, DYYYPlaybackQualityPreferHDR, YES) == wrongAddressClass,
        "wrong native address class is not promoted even if its URL looks valid");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(nativeObject, [NSObject new], DYYYPlaybackQualityPreferHDR, YES) == nativeObject,
        "a non-video selector owner preserves the original tier");
    return failed;
}
