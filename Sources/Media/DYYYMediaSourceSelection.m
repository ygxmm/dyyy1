#import "DYYYMediaSourceSelection.h"
#include <math.h>

static const NSUInteger DYYYMediaSourceURLLimit = 8;
static const NSUInteger DYYYMediaSourceImageLimit = 12;
static const NSUInteger DYYYMediaSourceMaxDepth = 8;
static const NSUInteger DYYYMediaSourceMaxVisited = 512;

static id DYYYMediaSourceGet(id model, NSString *key) {
    @try {
        if ([model isKindOfClass:NSDictionary.class]) return [model objectForKey:key];
        if (model == NSNull.null || [model isKindOfClass:NSArray.class]) return nil;
        return [model valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSURL *DYYYMediaSourceCleanURL(id value) {
    NSURL *url = nil;
    if ([value isKindOfClass:NSURL.class]) {
        url = value;
        if (url.baseURL) return nil; // Do not resolve a relative URL.
    } else if ([value isKindOfClass:NSString.class]) {
        url = [NSURL URLWithString:value];
        // Recent Foundation versions may auto-encode malformed input. Do not use that result.
        if (![url.absoluteString isEqualToString:value]) return nil;
    }
    if (!url) return nil;

    NSURLComponents *parts = [NSURLComponents componentsWithString:url.absoluteString];
    NSString *scheme = parts.scheme.lowercaseString;
    if (!parts.host.length || !([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])) return nil;

    // Inspect both raw and decoded paths, but never reconstruct the returned URL.
    NSString *rawPath = parts.percentEncodedPath.lowercaseString;
    NSString *path = parts.path.lowercaseString;
    if ([rawPath containsString:@"tplv-dy-water"] || [path containsString:@"tplv-dy-water"] ||
        [rawPath containsString:@"/playwm/"] || [path containsString:@"/playwm/"]) return nil;
    for (NSURLQueryItem *item in parts.queryItems) {
        if ([item.name.lowercaseString isEqualToString:@"watermark"] && [item.value isEqualToString:@"1"]) return nil;
    }
    return url;
}

static void DYYYMediaSourceAdd(NSURL *url, NSMutableArray<NSURL *> *urls, NSMutableSet<NSString *> *seen) {
    NSString *text = url.absoluteString;
    if (![seen containsObject:text]) {
        [seen addObject:text];
        [urls addObject:url];
    }
}

static void DYYYMediaSourceCollect(id value, NSMutableArray<NSURL *> *urls,
                                   NSMutableSet<NSString *> *seen, NSUInteger limit,
                                   NSUInteger depth, NSUInteger *remaining) {
    if (!value || !*remaining || depth > DYYYMediaSourceMaxDepth || urls.count >= limit) return;
    (*remaining)--;
    @try {
        if ([value isKindOfClass:NSArray.class]) {
            if (depth == DYYYMediaSourceMaxDepth) return;
            for (id item in value) {
                if (!*remaining || urls.count >= limit) break;
                DYYYMediaSourceCollect(item, urls, seen, limit, depth + 1, remaining);
            }
        } else if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSURL.class]) {
            NSURL *url = DYYYMediaSourceCleanURL(value);
            if (url) DYYYMediaSourceAdd(url, urls, seen);
        } else if (depth < DYYYMediaSourceMaxDepth && value != NSNull.null && ![value isKindOfClass:NSNumber.class]) {
            for (NSString *key in @[@"originURLList", @"URLList"]) {
                if (!*remaining || urls.count >= limit) break;
                DYYYMediaSourceCollect(DYYYMediaSourceGet(value, key), urls, seen, limit, depth + 1, remaining);
            }
        }
    } @catch (__unused NSException *exception) {
        // A malformed leaf or container must not abort other candidates.
    }
}

static void DYYYMediaSourceAppend(id value, NSMutableArray<NSURL *> *urls,
                                  NSMutableSet<NSString *> *seen, NSUInteger limit) {
    NSUInteger remaining = DYYYMediaSourceMaxVisited;
    DYYYMediaSourceCollect(value, urls, seen, limit, 0, &remaining);
}

NSArray<NSURL *> *DYYYMediaSourceURLs(id value) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    DYYYMediaSourceAppend(value, urls, [NSMutableSet set], DYYYMediaSourceURLLimit);
    return [urls copy];
}

static NSNumber *DYYYMediaSourceBitrate(id row) {
    for (NSString *key in @[@"bitrate", @"realBitrate", @"videoBitrate"]) {
        id value = DYYYMediaSourceGet(row, key);
        if ([value isKindOfClass:NSNumber.class]) {
            double rate = [value doubleValue];
            if (isfinite(rate) && rate > 0) return value;
        }
    }
    return nil;
}

static NSArray<NSURL *> *DYYYMediaSourceVideoURLs(id video, BOOL live) {
    NSMutableDictionary<NSNumber *, NSMutableArray<NSURL *> *> *tiers = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"bitrateModels_origin", @"bitrateModels"]) {
        id rows = DYYYMediaSourceGet(video, key);
        if (![rows isKindOfClass:NSArray.class]) continue;
        for (id row in rows) {
            NSArray<NSURL *> *candidates = DYYYMediaSourceURLs(DYYYMediaSourceGet(row, @"playAddr"));
            NSNumber *rate = DYYYMediaSourceBitrate(row);
            if (!candidates.count || !rate) continue;
            if (!tiers[rate]) tiers[rate] = [NSMutableArray array];
            [tiers[rate] addObjectsFromArray:candidates];
        }
    }
    NSMutableArray<NSURL *> *fallbacks = [NSMutableArray array];
    NSMutableSet<NSString *> *fallbackSeen = [NSMutableSet set];
    // Reserve one usable URL per trusted fallback field, without starving bitrate tiers.
    if (live || !tiers.count) {
        for (NSString *key in @[@"h264URL", @"playURL"]) {
            DYYYMediaSourceAppend(DYYYMediaSourceGet(video, key), fallbacks, fallbackSeen,
                                  live ? fallbacks.count + 1 : DYYYMediaSourceURLLimit);
        }
    }
    NSUInteger limit = live ? 12 - fallbacks.count : DYYYMediaSourceURLLimit;
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSArray<NSNumber *> *rates = [tiers.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [b compare:a];
    }];
    for (NSNumber *rate in rates) {
        NSUInteger tierStart = urls.count;
        for (NSURL *url in tiers[rate]) {
            if (urls.count >= limit || urls.count - tierStart >= (live ? 4 : DYYYMediaSourceURLLimit)) break;
            DYYYMediaSourceAdd(url, urls, seen);
        }
        if (!live || urls.count >= limit) break;
    }
    for (NSURL *url in fallbacks) DYYYMediaSourceAdd(url, urls, seen);
    return [urls copy];
}

NSArray<NSURL *> *DYYYMediaSourceHighestVideoURLs(id video) {
    return DYYYMediaSourceVideoURLs(video, NO);
}

NSArray<NSURL *> *DYYYMediaSourceLiveVideoURLs(id video) {
    return DYYYMediaSourceVideoURLs(video, YES);
}

NSArray<NSURL *> *DYYYMediaSourceCoverURLs(id video) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *key in @[@"originCover", @"coverURL"]) {
        if (urls.count >= DYYYMediaSourceURLLimit) break;
        DYYYMediaSourceAppend(DYYYMediaSourceGet(video, key), urls, seen, DYYYMediaSourceURLLimit);
    }
    return [urls copy];
}

NSArray<NSURL *> *DYYYMediaSourceImageURLs(id image, id matchedOriginal) {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *key in @[@"watermarkFreeUrlList", @"urlList"]) {
        DYYYMediaSourceAppend(DYYYMediaSourceGet(matchedOriginal, key), urls, seen, DYYYMediaSourceImageLimit);
        if (urls.count >= DYYYMediaSourceImageLimit) break;
        DYYYMediaSourceAppend(DYYYMediaSourceGet(image, key), urls, seen, DYYYMediaSourceImageLimit);
        if (urls.count >= DYYYMediaSourceImageLimit) break;
    }
    return [urls copy];
}
