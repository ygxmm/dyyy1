#import "../../Sources/Media/DYYYVideoQualityPolicy.h"
#include <stdio.h>

static NSDictionary *DYYYQualityTier(NSString *gear, NSInteger rate, id hdr, NSString *url) {
    return @{@"gearName":gear, @"bitrate":@(rate), @"hdrType":hdr, @"hdrBit":@"10",
        @"playAddr":url ? @{@"originURLList":@[url]} : @{} };
}

static int DYYYVerifyQuality(BOOL pass, const char *meaning) {
    printf("%s video quality: %s\n", pass ? "PASS" : "FAIL", meaning);
    return !pass;
}

int DYYYRunVideoQualityPolicyTests(void) {
    int failed = 0;
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
    failed += DYYYVerifyQuality(DYYYSelectHDRPlaybackTier(choices) == hdr, "prefer top HDR despite SDR having a higher bitrate");
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
    return failed;
}
