#import "../../Sources/Media/DYYYMediaSourceSelection.h"
#include <stdio.h>

@interface DYYYMediaSourceTestURLModel : NSObject
@property (nonatomic, copy) NSArray *originURLList;
@property (nonatomic, copy) NSArray *URLList;
@end

@implementation DYYYMediaSourceTestURLModel
@end

@interface DYYYMediaSourceTestBrokenURLModel : DYYYMediaSourceTestURLModel
@end

@implementation DYYYMediaSourceTestBrokenURLModel
- (NSArray *)originURLList {
    @throw [NSException exceptionWithName:NSGenericException reason:@"Synthetic missing getter" userInfo:nil];
}
@end

static BOOL DYYYMediaSourceTestMatches(NSArray<NSURL *> *actual, NSArray<NSString *> *expected) {
    if (actual.count != expected.count) return NO;
    for (NSUInteger i = 0; i < expected.count; i++) {
        if (![actual[i].absoluteString isEqualToString:expected[i]]) return NO;
    }
    return YES;
}

static int DYYYMediaSourceTestReport(BOOL passed, const char *name) {
    printf("%s media source: %s\n", passed ? "PASS" : "FAIL", name);
    return passed ? 0 : 1;
}

int DYYYRunMediaSourceSelectionTests(void) {
    int failures = 0;
    NSString *signedText = @"https://cdn.example/video%2fraw?z=A%2Bb%3d&a=1&a=2&X-Signature=x+y%2F%3D";
    NSURL *signedURL = [NSURL URLWithString:signedText];
    NSArray<NSURL *> *signedURLs = DYYYMediaSourceURLs(@[signedURL, signedText]);
    failures += DYYYMediaSourceTestReport(signedURLs.firstObject == signedURL &&
        DYYYMediaSourceTestMatches(signedURLs, @[signedText]) &&
        DYYYMediaSourceTestMatches(DYYYMediaSourceURLs(signedText), @[signedText]),
        "signed URL is unchanged and exact duplicates are collapsed");

    NSString *plain = @"http://cdn.example/plain?notwatermark=1&watermark=0&watermark=10&sig=watermark%3D1";
    NSArray *filtered = @[@"", @"a relative path", @"https:///no-host", @"ftp://cdn.example/a",
        @"https://cdn.example/contains space", @"https://cdn.example/bad%escape",
        @"https://cdn.example/image~tplv-dy-water:jpg", @"https://cdn.example/PLAYWM/track",
        @"https://cdn.example/play?watermark=1&watermark=0", @"https://cdn.example/play?%77atermark=%31",
        NSNull.null, plain];
    failures += DYYYMediaSourceTestReport(DYYYMediaSourceTestMatches(DYYYMediaSourceURLs(filtered), @[plain]),
        "invalid URLs and known positive watermark markers are rejected, not rewritten");

    NSString *high = @"https://cdn.example/origin";
    NSString *backup = @"https://backup.example/origin";
    NSString *low = @"https://cdn.example/2160p";
    NSString *fallback = @"https://cdn.example/fallback";
    DYYYMediaSourceTestURLModel *address = [DYYYMediaSourceTestURLModel new];
    address.originURLList = @[high];
    address.URLList = @[high, backup];
    NSDictionary *badTop = @{@"bitrate": @5000, @"playAddr": @{@"URLList": @[
        @"https://cdn.example/playwm/top", @"https://cdn.example/top?watermark=1", @"not a URL"]}};
    NSDictionary *original = @{@"bitrate": @3000, @"playAddr": address};
    NSDictionary *smaller = @{@"bitrate": @1000, @"playAddr": low};
    NSDictionary *video = @{@"bitrateModels_origin": @[original], @"bitrateModels": @[smaller, badTop],
                            @"h264URL": fallback};
    failures += DYYYMediaSourceTestReport(DYYYMediaSourceTestMatches(DYYYMediaSourceHighestVideoURLs(video), @[high, backup]),
        "invalid highest tier is skipped and the original tier beats a lower tier regardless of URL name");

    NSString *tie = @"https://backup.example/equal?sig=1%2B2";
    NSDictionary *equal = @{@"bitrate": @0, @"realBitrate": @3000, @"playAddr": @[backup, tie]};
    NSDictionary *higher = @{@"videoBitrate": @4000, @"playAddr": signedText};
    failures += DYYYMediaSourceTestReport(DYYYMediaSourceTestMatches(DYYYMediaSourceHighestVideoURLs(@{
        @"bitrateModels_origin": @[original], @"bitrateModels": @[equal, badTop]}), @[high, backup, tie]),
        "equal rates merge both model lists in order, deduplicating alternates");
    failures += DYYYMediaSourceTestReport(DYYYMediaSourceTestMatches(DYYYMediaSourceHighestVideoURLs(@{
        @"bitrateModels_origin": @[original], @"bitrateModels": @[higher]}), @[signedText]),
        "higher current tier wins and videoBitrate can supply missing bitrate metadata");

    NSDictionary *oldVideo = @{@"bitrateModels": @[badTop],
        @"h264URL": @{@"URLList": @[fallback]}, @"playURL": @[fallback, signedText], @"downloadURL": low};
    failures += DYYYMediaSourceTestReport(DYYYMediaSourceTestMatches(DYYYMediaSourceHighestVideoURLs(oldVideo), @[fallback, signedText]) &&
        DYYYMediaSourceTestMatches(DYYYMediaSourceHighestVideoURLs(@{@"playURL": signedText}), @[signedText]),
        "legacy fallback uses h264URL then playURL and ignores downloadURL");

    NSString *cover = @"https://cdn.example/cover.jpg";
    failures += DYYYMediaSourceTestReport(DYYYMediaSourceTestMatches(DYYYMediaSourceCoverURLs(@{
        @"originCover": address, @"coverURL": @[high, @"https://cdn.example/tplv-dy-water/cover", cover]}), @[high, backup, cover]),
        "origin cover first, deduplicated with usable cover URL alternatives");

    NSString *originalFree = @"https://cdn.example/page2-original-free";
    NSString *currentFree = @"https://cdn.example/page2-current-free";
    NSString *originalPlain = @"https://cdn.example/page2-original";
    NSString *currentPlain = @"https://cdn.example/page2-current";
    NSDictionary *originalPage = @{@"watermarkFreeUrlList": @[originalFree], @"urlList": @[originalPlain, currentFree]};
    NSDictionary *currentPage = @{@"watermarkFreeUrlList": @[originalFree, currentFree],
        @"urlList": @[originalPlain, @"https://cdn.example/page2?watermark=1", currentPlain], @"downloadURLList": @[low]};
    failures += DYYYMediaSourceTestReport(DYYYMediaSourceTestMatches(DYYYMediaSourceImageURLs(currentPage, originalPage),
        @[originalFree, currentFree, originalPlain, currentPlain]), "one gallery page merges original and current free lists before plain lists");

    NSMutableArray<NSString *> *many = [NSMutableArray array];
    for (NSUInteger i = 0; i < 15; i++) [many addObject:[NSString stringWithFormat:@"https://cdn.example/%lu", (unsigned long)i]];
    failures += DYYYMediaSourceTestReport(DYYYMediaSourceTestMatches(DYYYMediaSourceURLs(many), [many subarrayWithRange:NSMakeRange(0, 8)]) &&
        DYYYMediaSourceTestMatches(DYYYMediaSourceImageURLs(@{@"watermarkFreeUrlList": many}, nil), [many subarrayWithRange:NSMakeRange(0, 12)]),
        "generic and gallery candidate limits preserve order");

    NSDictionary *liveVideo = @{@"bitrateModels_origin": @[
        @{@"realBitrate": @760255, @"playAddr": [many subarrayWithRange:NSMakeRange(4, 4)]},
        @{@"bitrate": @880099, @"playAddr": many}], @"bitrateModels": @[
        @{@"videoBitrate": @100000, @"playAddr": [many subarrayWithRange:NSMakeRange(8, 4)]}],
        @"h264URL": fallback, @"playURL": signedURL};
    NSArray *liveExpected = [[many subarrayWithRange:NSMakeRange(0, 10)] arrayByAddingObjectsFromArray:@[fallback, signedText]];
    failures += DYYYMediaSourceTestReport(DYYYMediaSourceTestMatches(DYYYMediaSourceLiveVideoURLs(liveVideo), liveExpected),
        "live tiers descend, cap mirrors at four, retain the second tier and reserve trusted fallbacks within twelve");
    failures += DYYYMediaSourceTestReport(DYYYMediaSourceTestMatches(DYYYMediaSourceHighestVideoURLs(liveVideo),
        [many subarrayWithRange:NSMakeRange(0, 8)]), "highest-only selection still keeps eight top-tier mirrors without fallbacks");
    failures += DYYYMediaSourceTestReport(DYYYMediaSourceTestMatches(DYYYMediaSourceLiveVideoURLs(@{
        @"bitrateModels_origin": @[original], @"bitrateModels": @[equal, smaller, badTop],
        @"h264URL": @[@"https://cdn.example/play?watermark=1", fallback], @"playURL": @[@"not a URL", signedURL],
        @"downloadURL": @"https://cdn.example/download"}), @[high, backup, tie, low, fallback, signedText]),
        "live merges equal tiers in original order, filters invalid/watermarked URLs and leaves signatures unchanged");
    failures += DYYYMediaSourceTestReport(DYYYMediaSourceTestMatches(DYYYMediaSourceLiveVideoURLs(oldVideo), @[fallback, signedText]) &&
        DYYYMediaSourceLiveVideoURLs(nil).count == 0 &&
        DYYYMediaSourceLiveVideoURLs(@{@"bitrateModels": @[badTop], @"downloadURL": low}).count == 0,
        "live supports legacy trusted fallbacks but never download-only or empty candidates");

    DYYYMediaSourceTestURLModel *cyclic = [DYYYMediaSourceTestURLModel new];
    cyclic.originURLList = @[cyclic];
    DYYYMediaSourceTestBrokenURLModel *broken = [DYYYMediaSourceTestBrokenURLModel new];
    broken.URLList = @[signedURL];
    NSArray<NSURL *> *afterBroken = DYYYMediaSourceURLs(@[cyclic, broken]);
    cyclic.originURLList = nil;
    failures += DYYYMediaSourceTestReport(DYYYMediaSourceTestMatches(afterBroken, @[signedText]),
        "cycles and throwing getters do not hide a valid sibling");

    failures += DYYYMediaSourceTestReport(DYYYMediaSourceURLs(nil).count == 0 &&
        DYYYMediaSourceHighestVideoURLs(@{@"bitrateModels": @[badTop], @"downloadURL": low}).count == 0 &&
        DYYYMediaSourceCoverURLs(nil).count == 0 &&
        DYYYMediaSourceImageURLs(@{@"downloadURLList": @[low]}, nil).count == 0,
        "empty or download-only candidates produce empty arrays");
    return failures;
}
