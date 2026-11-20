#import "DYYYVideoQualityPolicy.h"
#import "DYYYMediaSourceSelection.h"
#import "../Core/DYYYConstants.h"

NSString *DYYYNormalizedPlaybackQualityPolicy(id preference) {
    if ([preference isEqual:DYYY_VIDEO_QUALITY_OFF]) return DYYY_VIDEO_QUALITY_OFF;
    if ([preference isEqual:DYYY_VIDEO_QUALITY_PREFER_HDR]) return DYYY_VIDEO_QUALITY_PREFER_HDR;
    return DYYY_VIDEO_QUALITY_HIGHEST;
}

DYYYPlaybackQualityMode DYYYPlaybackQualityModeForSettings(BOOL enabled, id preference) {
    if (!enabled || [preference isEqual:DYYY_VIDEO_QUALITY_OFF]) return DYYYPlaybackQualityOriginal;
    return [preference isEqual:DYYY_VIDEO_QUALITY_PREFER_HDR] ? DYYYPlaybackQualityPreferHDR : DYYYPlaybackQualityHighest;
}

static id DYYYPlaybackTierValue(id tier, NSString *key) {
    @try { return [tier valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static NSInteger DYYYPlaybackTierBitrate(id tier) {
    id value = DYYYPlaybackTierValue(tier, @"bitrate");
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
}

static NSInteger DYYYPlaybackTierResolution(id tier) {
    id value = DYYYPlaybackTierValue(tier, @"gearName");
    if (![value isKindOfClass:NSString.class]) return 0;
    NSString *name = value;
    NSUInteger leading = 0;
    while (leading < name.length) {
        unichar c = [name characterAtIndex:leading];
        if (c < '0' || c > '9') break;
        ++leading;
    }
    if (leading > 0) {
        NSInteger res = [[name substringToIndex:leading] integerValue];
        if (res >= 240 && res <= 4320) return res;
    }
    for (NSString *part in [name componentsSeparatedByString:@"_"]) {
        if (part.length < 3 || part.length > 4) continue;
        BOOL digits = YES;
        for (NSUInteger i = 0; i < part.length; ++i) {
            unichar c = [part characterAtIndex:i];
            if (c < '0' || c > '9') { digits = NO; break; }
        }
        if (!digits) continue;
        NSInteger res = part.integerValue;
        if (res >= 240 && res <= 4320) return res;
    }
    return 0;
}

static NSInteger DYYYPlaybackTierHDRType(id tier) {
    id tag = DYYYPlaybackTierValue(tier, @"hdrType");
    // Only positive native HDR metadata is evidence, not a gear name or 10 bit alone.
    if ([tag isKindOfClass:NSNumber.class]) return [tag integerValue];
    if (![tag isKindOfClass:NSString.class]) return 0;
    NSScanner *scanner = [NSScanner scannerWithString:tag];
    NSInteger type = 0;
    return [scanner scanInteger:&type] && scanner.isAtEnd ? type : 0;
}

static BOOL DYYYPlaybackTierHasUsableSource(id tier) {
    if (DYYYPlaybackTierBitrate(tier) <= 0) return NO;
    id address = DYYYPlaybackTierValue(tier, @"playAddr");
    Class addressClass = NSClassFromString(@"AWEURLModel");
    if (addressClass && ![address isKindOfClass:addressClass]) return NO;
    id key = DYYYPlaybackTierValue(tier, @"gearName");
    return [key isKindOfClass:NSString.class] && [key length] > 0 && DYYYMediaSourceURLs(address).count > 0;
}

static BOOL DYYYPlaybackTierIsUsableHDR(id tier) {
    return DYYYPlaybackTierHDRType(tier) > 0 && DYYYPlaybackTierHasUsableSource(tier);
}

static BOOL DYYYPlaybackTierRanksHigher(id candidate, id best) {
    NSInteger bitrate = DYYYPlaybackTierBitrate(candidate), bestBitrate = DYYYPlaybackTierBitrate(best);
    return bitrate > bestBitrate || (bitrate == bestBitrate && DYYYPlaybackTierResolution(candidate) > DYYYPlaybackTierResolution(best));
}

id DYYYSelectHighestPlaybackTier(NSArray *tiers) {
    if (![tiers isKindOfClass:NSArray.class]) return nil;
    id best = nil;
    for (id tier in tiers) if (DYYYPlaybackTierRanksHigher(tier, best)) best = tier;
    return best;
}

id DYYYSelectHDRPlaybackTier(NSArray *tiers) {
    if (![tiers isKindOfClass:NSArray.class]) return nil;
    id best = nil;
    for (id tier in tiers) {
        if (DYYYPlaybackTierIsUsableHDR(tier) && DYYYPlaybackTierRanksHigher(tier, best)) best = tier;
    }
    return best;
}

static BOOL DYYYPlaybackSameSource(id a, id b) {
    if (a == b) return YES;
    if (DYYYPlaybackTierBitrate(a) != DYYYPlaybackTierBitrate(b) || DYYYPlaybackTierHDRType(a) != DYYYPlaybackTierHDRType(b) ||
        ![DYYYPlaybackTierValue(a, @"gearName") isEqual:DYYYPlaybackTierValue(b, @"gearName")]) return NO;
    NSSet *originURLs = [NSSet setWithArray:DYYYMediaSourceURLs(DYYYPlaybackTierValue(a, @"playAddr"))];
    for (NSURL *url in DYYYMediaSourceURLs(DYYYPlaybackTierValue(b, @"playAddr"))) {
        if ([originURLs containsObject:url]) return YES;
    }
    return NO;
}

id DYYYResolveNativePlaybackTier(id nativeTier, NSArray *tiers, DYYYPlaybackQualityMode mode, BOOL nativeHDRAllowed) {
    // Never turn a native nil / unsupported model into a playable source.
    // Keep the host's stored cache untouched: Off immediately exposes it again.
    if (mode != DYYYPlaybackQualityPreferHDR || !nativeHDRAllowed ||
        !DYYYPlaybackTierHasUsableSource(nativeTier) || ![tiers isKindOfClass:NSArray.class]) return nativeTier;
    id hdrTier = DYYYSelectHDRPlaybackTier(tiers);
    if (!hdrTier || hdrTier == nativeTier) return nativeTier;
    for (id tier in tiers) {
        if (DYYYPlaybackSameSource(nativeTier, tier)) return hdrTier;
    }
    // A detached DASH model, stale URL or unrelated source stays native.
    return nativeTier;
}

NSArray *DYYYPlaybackTiersWithPreferredHDR(NSArray *effective, NSArray *manual, NSArray *original) {
    if (![effective isKindOfClass:NSArray.class] || ![manual isKindOfClass:NSArray.class] ||
        ![original isKindOfClass:NSArray.class] || !manual.count || !original.count) return effective;
    id current = DYYYSelectHDRPlaybackTier(effective), add = nil;
    for (id candidate in manual) {
        if (!DYYYPlaybackTierIsUsableHDR(candidate) || !DYYYPlaybackTierRanksHigher(candidate, add ?: current)) continue;
        // Gear names can be shared by SDR and HDR variants. Treat only the same
        // HDR representation (including its source URL) as already restored.
        BOOL tierExists = NO;
        for (id tier in effective) {
            if (DYYYPlaybackSameSource(tier, candidate)) { tierExists = YES; break; }
        }
        if (tierExists) continue;
        for (id tier in original) {
            if (DYYYPlaybackSameSource(tier, candidate)) { add = tier; break; }
        }
    }
    return add ? [effective arrayByAddingObject:add] : effective;
}
