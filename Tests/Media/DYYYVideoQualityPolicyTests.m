#import "../../Sources/Media/DYYYVideoQualityPolicy.h"
#import "../../Sources/Core/DYYYConstants.h"
#include <stdio.h>
#include <math.h>
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

static NSDictionary *DYYYQualitySizedTier(NSString *gear, NSInteger rate, double width, double height) {
    NSMutableDictionary *tier = [DYYYQualityTier(gear, rate, @0, @"https://cdn.example/sized") mutableCopy];
    tier[@"playAddr"] = @{@"originURLList":@[@"https://cdn.example/sized"], @"imageWidth":@(width), @"imageHeight":@(height)};
    return tier;
}

static int DYYYVerifyQuality(BOOL pass, const char *meaning) {
    printf("%s video quality: %s\n", pass ? "PASS" : "FAIL", meaning);
    return !pass;
}

static int DYYYRunPlaybackPolicySelectionCases(void) {
    int failed = 0;
    NSDictionary *low = DYYYQualityTier(@"720_1_1", 1000000, @0, @"https://cdn.example/low?sig=a%2Bb");
    NSDictionary *high = DYYYQualityTier(@"1440_1_1", 6000000, @0, @"https://cdn.example/high?sig=c%2Bd");
    NSDictionary *hdr = DYYYQualityTier(@"adapt_lowest_1080_1", 3000000, @3, @"https://cdn.example/hdr");
    NSDictionary *hdrTop = DYYYQualityTier(@"adapt_lowest_1440_1", 8000000, @3, @"https://cdn.example/hdr-top");
    NSArray *mixed = @[low, hdr, high];
    failed += DYYYVerifyQuality(DYYYSelectPlaybackTier(mixed, DYYYPlaybackQualityOriginal, YES) == nil,
        "Off does not produce an address-layer replacement");
    failed += DYYYVerifyQuality(DYYYSelectPlaybackTier(mixed, DYYYPlaybackQualityHighest, YES) == high,
        "highest mode selects maximum bitrate rather than preferring HDR");
    failed += DYYYVerifyQuality(DYYYSelectPlaybackTier(mixed, DYYYPlaybackQualityPreferHDR, YES) == hdr,
        "HDR mode prefers a usable HDR tier even below SDR bitrate");
    failed += DYYYVerifyQuality(DYYYSelectPlaybackTier(@[low, high], DYYYPlaybackQualityPreferHDR, YES) == high,
        "HDR mode without HDR chooses highest bitrate rather than the native lower tier");
    failed += DYYYVerifyQuality(DYYYSelectPlaybackTier(@[high, hdrTop], DYYYPlaybackQualityHighest, YES) == hdrTop,
        "highest mode can select permitted HDR when it is the maximum bitrate");
    failed += DYYYVerifyQuality(DYYYSelectPlaybackTier(@[high, hdr, hdrTop], DYYYPlaybackQualityPreferHDR, YES) == hdrTop,
        "HDR preference selects the maximum bitrate among usable HDR sources");
    failed += DYYYVerifyQuality(DYYYSelectPlaybackTier(@[high, hdrTop], DYYYPlaybackQualityHighest, NO) == high &&
        DYYYSelectPlaybackTier(@[high, hdrTop], DYYYPlaybackQualityPreferHDR, NO) == high,
        "both modes exclude HDR denied by the device or native service");
    failed += DYYYVerifyQuality(DYYYSelectPlaybackTier(@[hdrTop], DYYYPlaybackQualityPreferHDR, NO) == nil,
        "no allowed source means native fallback instead of manufacturing playable HDR");
    NSDictionary *badAddress = DYYYQualityTier(@"2160_1_1", 9000000, @0, nil);
    NSDictionary *badHDR = DYYYQualityTier(@"adapt_lowest_2160_1", 10000000, @3, nil);
    NSDictionary *badKey = DYYYQualityTier(@"", 11000000, @0, @"https://cdn.example/no-key");
    NSDictionary *zero = DYYYQualityTier(@"2160_1_1", 0, @0, @"https://cdn.example/zero");
    NSDictionary *negative = DYYYQualityTier(@"2160_1_1", -1, @0, @"https://cdn.example/negative");
    NSArray *invalid = @[badAddress, badHDR, badKey, zero, negative, [NSObject new]];
    failed += DYYYVerifyQuality(DYYYSelectHighestPlaybackTier([invalid arrayByAddingObject:high]) == high,
        "bad maximum source, empty key and nonpositive bitrate cannot hide the valid runner-up");
    failed += DYYYVerifyQuality(DYYYSelectHighestPlaybackTier(invalid) == nil,
        "an entirely unusable list cannot return an address with an unrelated key");
    failed += DYYYVerifyQuality(DYYYSelectPlaybackTier(@[badHDR, low, high], DYYYPlaybackQualityPreferHDR, YES) == high,
        "unusable HDR counts as absent and falls back to maximum usable bitrate");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTier(low, @[low, high], DYYYPlaybackQualityHighest, YES) == high,
        "final native low result is upgraded in highest mode");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTier(low, @[low, high], DYYYPlaybackQualityPreferHDR, YES) == high,
        "final native low result upgrades to maximum bitrate when HDR is absent");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTier(low, mixed, DYYYPlaybackQualityPreferHDR, YES) == hdr,
        "final native low result uses the same HDR preference as address selection");
    NSDictionary *foreign = DYYYQualityTier(@"720_1_1", 1000000, @0, @"https://cdn.example/foreign");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTier(foreign, mixed, DYYYPlaybackQualityHighest, YES) == foreign &&
        DYYYResolveNativePlaybackTier(nil, mixed, DYYYPlaybackQualityHighest, YES) == nil,
        "highest mode preserves nil and unrelated native sources");
    NSDictionary *large = DYYYQualitySizedTier(@"4_1_1", 3000000, 1900, 3378);
    NSDictionary *small = DYYYQualitySizedTier(@"1080_1_1", 3000000, 1080, 1920);
    failed += DYYYVerifyQuality(DYYYSelectHighestPlaybackTier(@[small, large]) == large &&
        DYYYSelectHighestPlaybackTier(@[large, small]) == large,
        "real dimensions resolve equal-bitrate opaque gear names independently of array order");
    NSDictionary *higherRate = DYYYQualitySizedTier(@"720_1_1", 3000001, 720, 1280);
    failed += DYYYVerifyQuality(DYYYSelectHighestPlaybackTier(@[large, higherRate]) == higherRate,
        "pixel dimensions never outrank a higher bitrate");
    NSDictionary *samePixels = DYYYQualitySizedTier(@"2160_1_1", 3000000, 1080, 1920);
    failed += DYYYVerifyQuality(DYYYSelectHighestPlaybackTier(@[small, samePixels]) == small,
        "identical real resolution and bitrate retain native order without trusting the gear label");
    NSDictionary *unknownSize = DYYYQualitySizedTier(@"1440_1_1", 3000000, -1, 2560);
    failed += DYYYVerifyQuality(DYYYSelectHighestPlaybackTier(@[small, unknownSize]) == unknownSize,
        "invalid or missing dimensions fall back to comparable legacy gear names");
    double invalidSizes[][2] = {{0, 2560}, {-1, 2560}, {NAN, 2560}, {INFINITY, 2560}, {1e300, 1e300}};
    for (NSUInteger i = 0; i < sizeof(invalidSizes) / sizeof(invalidSizes[0]); ++i) {
        NSDictionary *invalidSize = DYYYQualitySizedTier(@"1440_1_1", 3000000, invalidSizes[i][0], invalidSizes[i][1]);
        failed += DYYYVerifyQuality(DYYYSelectHighestPlaybackTier(@[small, invalidSize]) == invalidSize,
            "zero, negative, nonfinite and overflowing dimensions use a finite gear fallback");
    }
    NSDictionary *wide = DYYYQualitySizedTier(@"720_1_1", 3000000, 720, 3000);
    NSDictionary *misnamed = DYYYQualitySizedTier(@"2160_1_1", 3000000, 1080, 1920);
    NSDictionary *estimated = DYYYQualityTier(@"1440_1_1", 3000000, @0, @"https://cdn.example/estimated");
    NSArray *permutations = @[@[wide, misnamed, estimated], @[wide, estimated, misnamed],
        @[misnamed, wide, estimated], @[misnamed, estimated, wide], @[estimated, wide, misnamed], @[estimated, misnamed, wide]];
    for (NSArray *order in permutations) {
        failed += DYYYVerifyQuality(DYYYSelectHighestPlaybackTier(order) == estimated,
            "a fixed real-or-estimated short-edge key avoids mixed-dimension comparison cycles");
    }
    failed += DYYYVerifyQuality([mixed isEqualToArray:@[low, hdr, high]] &&
        DYYYResolveNativePlaybackTier(low, mixed, DYYYPlaybackQualityOriginal, YES) == low,
        "selection never reorders the original list and Off restores its native result");
    return failed;
}

static int DYYYRunNativePlaybackPolicyCases(Class addressClass) {
    int failed = 0;
    DYYYQualityTierFixture *low = DYYYQualityObjectTier(addressClass, @"720_1_1", 1000000, @"", @"https://cdn.example/object-low?sig=a%2Bb");
    DYYYQualityTierFixture *high = DYYYQualityObjectTier(addressClass, @"1440_1_1", 6000000, @"", @"https://cdn.example/object-high");
    DYYYQualityTierFixture *hdr = DYYYQualityObjectTier(addressClass, @"adapt_lowest_1080_1", 3000000, @"3", @"https://cdn.example/object-hdr");
    DYYYQualityTierFixture *bad = DYYYQualityObjectTier(addressClass, @"2160_1_1", 9000000, @"", nil);
    DYYYQualityTierFixture *wrongClass = DYYYQualityObjectTier(DYYYQualityAddressFixture.class, @"2160_1_1", 10000000, @"", @"https://cdn.example/wrong-class");
    DYYYQualityTierFixture *copy = DYYYQualityObjectTier(addressClass, low.gearName, low.bitrate.integerValue, @"", @"https://cdn.example/object-low?sig=a%2Bb");
    DYYYQualityTierFixture *foreign = DYYYQualityObjectTier(addressClass, low.gearName, low.bitrate.integerValue, @"", @"https://cdn.example/object-low?sig=OTHER");
    DYYYQualityVideoFixture *video = [DYYYQualityVideoFixture new];
    video.preloadedBSModel = low;
    DYYYPlaybackQualityMode modes[] = { DYYYPlaybackQualityHighest, DYYYPlaybackQualityPreferHDR };
    for (NSUInteger i = 0; i < 2; ++i) {
        DYYYPlaybackQualityMode mode = modes[i];
        video.nativeTiers = @[low, high, hdr, bad, wrongClass];
        id expected = mode == DYYYPlaybackQualityHighest ? high : hdr;
        failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(low, video, mode, YES) == expected,
            "enabled policy replaces a genuinely lower final native result with its selected real object");
        failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(copy, video, mode, YES) == expected,
            "both policies recognize exact signed source copies, not just object pointers");
        failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(foreign, video, mode, YES) == foreign,
            "both policies reject same-gear same-rate native results with another signature");
        failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(low, video, mode, NO) == high &&
            DYYYResolveNativePlaybackTierForVideo(hdr, video, mode, NO) == high,
            "denied HDR falls back to the highest SDR for both low SDR and HDR native inputs");
        NSUInteger reads = video.tierReads;
        failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(nil, video, mode, YES) == nil && video.tierReads == reads,
            "both enabled policies preserve nil without inspecting or synthesizing a source");
        NSObject *opaque = [NSObject new];
        failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(opaque, video, mode, YES) == opaque &&
            DYYYResolveNativePlaybackTierForVideo(wrongClass, video, mode, YES) == wrongClass,
            "opaque DASH and wrong native address types stay untouched in both modes");
        video.nativeTiers = @[low, high];
        failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(low, video, mode, YES) == high,
            "a video without HDR still upgrades its lower native result to maximum bitrate");
        video.nativeTiers = @[low];
        failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(low, video, mode, YES) == low,
            "single usable native source remains unchanged");
        video.nativeTiers = @[];
        failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(low, video, mode, YES) == low,
            "an empty list cannot manufacture a native replacement");
        video.nativeTiers = nil;
        failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(low, video, mode, YES) == low,
            "a nil list preserves the native object in both modes");
        video.nativeTiers = @[hdr];
        failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(hdr, video, mode, NO) == hdr,
            "no permitted alternative returns the native result rather than forcing an invalid source");
        video.throwOnRead = YES;
        failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(low, video, mode, YES) == low,
            "both policies fail closed when the owner's list is unavailable");
        video.throwOnRead = NO;
    }
    failed += DYYYVerifyQuality(video.preloadedBSModel == low && low.bitrate.integerValue == 1000000 && [low.hdrType isEqual:@""],
        "coordinating both policies never mutates the original cache or tier metadata");
    return failed;
}

static int DYYYRunVideoQualitySettingCases(void) {
    int failed = 0;
    failed += DYYYVerifyQuality([DYYYVideoQualitySettingDisplayValue(NO, DYYY_VIDEO_QUALITY_PREFER_HDR) isEqualToString:DYYY_VIDEO_QUALITY_OFF],
        "旧总开关关闭时，即使保存策略为 HDR，仍显示关闭");
    failed += DYYYVerifyQuality([DYYYVideoQualitySettingDisplayValue(YES, nil) isEqualToString:DYYY_VIDEO_QUALITY_HIGHEST] &&
        [DYYYVideoQualitySettingDisplayValue(YES, @42) isEqualToString:DYYY_VIDEO_QUALITY_HIGHEST],
        "总开关开启但策略缺失或无效时显示最高码率");
    failed += DYYYVerifyQuality([DYYYVideoQualitySettingDisplayValue(YES, DYYY_VIDEO_QUALITY_PREFER_HDR) isEqualToString:DYYY_VIDEO_QUALITY_PREFER_HDR],
        "旧配置启用 HDR 策略时显示 HDR 首选");

    NSString *suiteName = [NSString stringWithFormat:@"DYYYVideoQualitySettingsTests.%@", NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
    if (!defaults) return failed + DYYYVerifyQuality(NO, "可创建独立的偏好设置域");
    [defaults removePersistentDomainForName:suiteName];
    failed += DYYYVerifyQuality([DYYYPrepareVideoQualitySettingPicker(defaults) isEqualToString:DYYY_VIDEO_QUALITY_OFF] &&
        DYYYPlaybackQualityModeForSettings([defaults boolForKey:DYYY_ENABLE_HIGHEST_VIDEO_QUALITY_KEY],
            [defaults objectForKey:DYYY_VIDEO_QUALITY_POLICY_KEY]) == DYYYPlaybackQualityOriginal,
        "全新默认设置显示关闭并保持抖音原生播放");

    [defaults setBool:NO forKey:DYYY_ENABLE_HIGHEST_VIDEO_QUALITY_KEY];
    [defaults setObject:DYYY_VIDEO_QUALITY_PREFER_HDR forKey:DYYY_VIDEO_QUALITY_POLICY_KEY];
    failed += DYYYVerifyQuality([DYYYPrepareVideoQualitySettingPicker(defaults) isEqualToString:DYYY_VIDEO_QUALITY_OFF] &&
        [[defaults objectForKey:DYYY_VIDEO_QUALITY_POLICY_KEY] isEqualToString:DYYY_VIDEO_QUALITY_OFF] &&
        DYYYPlaybackQualityModeForSettings([defaults boolForKey:DYYY_ENABLE_HIGHEST_VIDEO_QUALITY_KEY],
            [defaults objectForKey:DYYY_VIDEO_QUALITY_POLICY_KEY]) == DYYYPlaybackQualityOriginal,
        "旧总开关关闭但策略为 HDR 时规范化为关闭，不启用画质策略");

    failed += DYYYVerifyQuality(DYYYStoreVideoQualitySelection(defaults, DYYY_VIDEO_QUALITY_OFF) &&
        ![defaults boolForKey:DYYY_ENABLE_HIGHEST_VIDEO_QUALITY_KEY] &&
        [[defaults objectForKey:DYYY_VIDEO_QUALITY_POLICY_KEY] isEqualToString:DYYY_VIDEO_QUALITY_OFF] &&
        DYYYPlaybackQualityModeForSettings([defaults boolForKey:DYYY_ENABLE_HIGHEST_VIDEO_QUALITY_KEY],
            [defaults objectForKey:DYYY_VIDEO_QUALITY_POLICY_KEY]) == DYYYPlaybackQualityOriginal,
        "选择关闭时同步两个兼容键并保持抖音原生播放");
    failed += DYYYVerifyQuality(DYYYStoreVideoQualitySelection(defaults, DYYY_VIDEO_QUALITY_HIGHEST) &&
        [defaults boolForKey:DYYY_ENABLE_HIGHEST_VIDEO_QUALITY_KEY] &&
        [[defaults objectForKey:DYYY_VIDEO_QUALITY_POLICY_KEY] isEqualToString:DYYY_VIDEO_QUALITY_HIGHEST] &&
        DYYYPlaybackQualityModeForSettings([defaults boolForKey:DYYY_ENABLE_HIGHEST_VIDEO_QUALITY_KEY],
            [defaults objectForKey:DYYY_VIDEO_QUALITY_POLICY_KEY]) == DYYYPlaybackQualityHighest,
        "选择最高码率时同步两个兼容键并启用原最高码率策略");
    failed += DYYYVerifyQuality(DYYYStoreVideoQualitySelection(defaults, DYYY_VIDEO_QUALITY_PREFER_HDR) &&
        [defaults boolForKey:DYYY_ENABLE_HIGHEST_VIDEO_QUALITY_KEY] &&
        [[defaults objectForKey:DYYY_VIDEO_QUALITY_POLICY_KEY] isEqualToString:DYYY_VIDEO_QUALITY_PREFER_HDR] &&
        DYYYPlaybackQualityModeForSettings([defaults boolForKey:DYYY_ENABLE_HIGHEST_VIDEO_QUALITY_KEY],
            [defaults objectForKey:DYYY_VIDEO_QUALITY_POLICY_KEY]) == DYYYPlaybackQualityPreferHDR,
        "选择 HDR 首选时同步两个兼容键并启用 HDR 策略");
    failed += DYYYVerifyQuality(!DYYYStoreVideoQualitySelection(defaults, @"invalid choice") &&
        [defaults boolForKey:DYYY_ENABLE_HIGHEST_VIDEO_QUALITY_KEY] &&
        [[defaults objectForKey:DYYY_VIDEO_QUALITY_POLICY_KEY] isEqualToString:DYYY_VIDEO_QUALITY_PREFER_HDR],
        "拒绝未知选项且不改变任一兼容设置");

    [defaults setBool:YES forKey:DYYY_ENABLE_HIGHEST_VIDEO_QUALITY_KEY];
    [defaults removeObjectForKey:DYYY_VIDEO_QUALITY_POLICY_KEY];
    failed += DYYYVerifyQuality([DYYYPrepareVideoQualitySettingPicker(defaults) isEqualToString:DYYY_VIDEO_QUALITY_HIGHEST] &&
        [[defaults objectForKey:DYYY_VIDEO_QUALITY_POLICY_KEY] isEqualToString:DYYY_VIDEO_QUALITY_HIGHEST] &&
        DYYYPlaybackQualityModeForSettings([defaults boolForKey:DYYY_ENABLE_HIGHEST_VIDEO_QUALITY_KEY],
            [defaults objectForKey:DYYY_VIDEO_QUALITY_POLICY_KEY]) == DYYYPlaybackQualityHighest,
        "总开关开启但旧策略缺失时规范化为最高码率");
    [defaults removePersistentDomainForName:suiteName];
    return failed;
}

int DYYYRunVideoQualityPolicyTests(void) {
    // These host doubles require a fresh macOS test process, never Aweme.
    if (NSClassFromString(@"AWEURLModel")) return DYYYVerifyQuality(NO, "host fixture requires an isolated test process");
    int failed = DYYYRunPlaybackPolicySelectionCases();
    failed += DYYYRunVideoQualitySettingCases();
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
        "an already highest native tier remains the same object in highest mode");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTier(sameGearSDR, sameGearChoices, DYYYPlaybackQualityPreferHDR, NO) == sameGearSDR,
        "HDR denial retains an already highest SDR result");
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
    failed += DYYYRunNativePlaybackPolicyCases(addressClass);
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
        selectorVideo.tierReads == readsBefore + 1, "highest mode checks candidates and retains the already highest native object");
    failed += DYYYVerifyQuality(DYYYResolveNativePlaybackTierForVideo(nativeObject, selectorVideo, DYYYPlaybackQualityPreferHDR, NO) == nativeObject &&
        selectorVideo.tierReads == readsBefore + 2, "HDR denial falls back to the highest allowed SDR rather than skipping selection");
    readsBefore = selectorVideo.tierReads;
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
