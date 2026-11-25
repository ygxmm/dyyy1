#import "DYYYVideoQualityPolicy.h"
#import "DYYYMediaSourceSelection.h"
#import "../Core/DYYYConstants.h"
#include <math.h>

@protocol DYYYPlaybackVideoTierSource <NSObject>
- (NSArray *)bitrateModels;
@end

NSString *DYYYNormalizedPlaybackQualityPolicy(id preference) {
    if ([preference isEqual:DYYY_VIDEO_QUALITY_OFF]) return DYYY_VIDEO_QUALITY_OFF;
    if ([preference isEqual:DYYY_VIDEO_QUALITY_PREFER_HDR]) return DYYY_VIDEO_QUALITY_PREFER_HDR;
    return DYYY_VIDEO_QUALITY_HIGHEST;
}

DYYYPlaybackQualityMode DYYYPlaybackQualityModeForSettings(BOOL enabled, id preference) {
    if (!enabled || [preference isEqual:DYYY_VIDEO_QUALITY_OFF]) return DYYYPlaybackQualityOriginal;
    return [preference isEqual:DYYY_VIDEO_QUALITY_PREFER_HDR] ? DYYYPlaybackQualityPreferHDR : DYYYPlaybackQualityHighest;
}

NSString *DYYYVideoQualitySettingDisplayValue(BOOL enabled, id preference) {
    if (!enabled) return DYYY_VIDEO_QUALITY_OFF;
    return DYYYNormalizedPlaybackQualityPolicy(preference);
}

NSString *DYYYPrepareVideoQualitySettingPicker(NSUserDefaults *defaults) {
    if (![defaults isKindOfClass:NSUserDefaults.class]) return DYYY_VIDEO_QUALITY_OFF;
    BOOL enabled = [defaults boolForKey:DYYY_ENABLE_HIGHEST_VIDEO_QUALITY_KEY];
    id preference = [defaults objectForKey:DYYY_VIDEO_QUALITY_POLICY_KEY];
    NSString *displayValue = DYYYVideoQualitySettingDisplayValue(enabled, preference);
    BOOL shouldEnable = ![displayValue isEqual:DYYY_VIDEO_QUALITY_OFF];
    // 仅修正不一致的旧配置，确保选择器高亮与实际播放状态一致，避免无谓地刷新缓存。
    if (enabled != shouldEnable || ![preference isEqual:displayValue]) {
        DYYYStoreVideoQualitySelection(defaults, displayValue);
    }
    return displayValue;
}

BOOL DYYYStoreVideoQualitySelection(NSUserDefaults *defaults, id selection) {
    if (![defaults isKindOfClass:NSUserDefaults.class] || ![selection isKindOfClass:NSString.class]) return NO;
    BOOL enabled = YES;
    if ([selection isEqual:DYYY_VIDEO_QUALITY_OFF]) {
        enabled = NO;
    } else if (![selection isEqual:DYYY_VIDEO_QUALITY_HIGHEST] &&
        ![selection isEqual:DYYY_VIDEO_QUALITY_PREFER_HDR]) {
        return NO;
    }
    // 先写策略：启用时，在策略准备就绪前保持总开关关闭；关闭时先让 Off 生效。
    [defaults setObject:selection forKey:DYYY_VIDEO_QUALITY_POLICY_KEY];
    [defaults setBool:enabled forKey:DYYY_ENABLE_HIGHEST_VIDEO_QUALITY_KEY];
    return YES;
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

static NSInteger DYYYHDRMetadataType(id tag) {
    // 仅接受完整的原生数值标记；10 位深、档位名称和任意嵌套字段都不能单独证明 HDR。
    if ([tag isKindOfClass:NSNumber.class]) return [tag integerValue];
    if (![tag isKindOfClass:NSString.class]) return 0;
    NSScanner *scanner = [NSScanner scannerWithString:tag];
    NSInteger type = 0;
    return [scanner scanInteger:&type] && scanner.isAtEnd ? type : 0;
}

static NSInteger DYYYPlaybackTierHDRType(id tier) {
    return DYYYHDRMetadataType(DYYYPlaybackTierValue(tier, @"hdrType"));
}

BOOL DYYYPlaybackTierHasHDRMetadata(id tier) {
    return DYYYPlaybackTierHDRType(tier) > 0;
}

BOOL DYYYAwemeRawVideoHasHDRMetadata(id rawAweme) {
    if (![rawAweme isKindOfClass:NSDictionary.class]) return NO;
    id video = rawAweme[@"video"];
    if (![video isKindOfClass:NSDictionary.class]) return NO;
    if (DYYYHDRMetadataType(video[@"is_source_hdr"]) > 0 ||
        DYYYHDRMetadataType(video[@"has_filter_hdr"]) > 0) return YES;
    id tiers = video[@"bit_rate"];
    if (![tiers isKindOfClass:NSArray.class]) return NO;
    // 只读当前作品视频的码流元数据，不扫描图片、相关推荐、广告或编辑信息。
    for (id tier in tiers) {
        if (![tier isKindOfClass:NSDictionary.class]) continue;
        if (DYYYHDRMetadataType(tier[@"HDR_type"]) > 0 ||
            DYYYHDRMetadataType(tier[@"hdr_type"]) > 0) return YES;
    }
    return NO;
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

typedef struct { double shortEdge, pixels; } DYYYPlaybackTierDimensions;

static DYYYPlaybackTierDimensions DYYYPlaybackTierSize(id tier) {
    id address = DYYYPlaybackTierValue(tier, @"playAddr");
    id width = DYYYPlaybackTierValue(address, @"imageWidth");
    id height = DYYYPlaybackTierValue(address, @"imageHeight");
    if ([width respondsToSelector:@selector(doubleValue)] && [height respondsToSelector:@selector(doubleValue)]) {
        double w = [width doubleValue], h = [height doubleValue], pixels = w * h;
        if (isfinite(w) && isfinite(h) && w > 0 && h > 0 && isfinite(pixels) && pixels > 0)
            return (DYYYPlaybackTierDimensions){ fmin(w, h), pixels };
    }
    return (DYYYPlaybackTierDimensions){ DYYYPlaybackTierResolution(tier), 0 };
}

static BOOL DYYYPlaybackTierRanksHigher(id candidate, id best) {
    NSInteger bitrate = DYYYPlaybackTierBitrate(candidate), bestBitrate = DYYYPlaybackTierBitrate(best);
    if (bitrate != bestBitrate) return bitrate > bestBitrate;
    DYYYPlaybackTierDimensions a = DYYYPlaybackTierSize(candidate), b = DYYYPlaybackTierSize(best);
    // A fixed per-tier key stays transitive with mixed known/unknown dimensions.
    if (a.shortEdge != b.shortEdge) return a.shortEdge > b.shortEdge;
    return a.pixels > b.pixels;
}

static id DYYYSelectHighestAllowedPlaybackTier(NSArray *tiers, BOOL allowHDR) {
    if (![tiers isKindOfClass:NSArray.class]) return nil;
    id best = nil;
    for (id tier in tiers) {
        if (!DYYYPlaybackTierHasUsableSource(tier) || (!allowHDR && DYYYPlaybackTierHDRType(tier) > 0)) continue;
        if (DYYYPlaybackTierRanksHigher(tier, best)) best = tier;
    }
    return best;
}

id DYYYSelectHighestPlaybackTier(NSArray *tiers) {
    return DYYYSelectHighestAllowedPlaybackTier(tiers, YES);
}

id DYYYSelectHDRPlaybackTier(NSArray *tiers) {
    if (![tiers isKindOfClass:NSArray.class]) return nil;
    id best = nil;
    for (id tier in tiers) {
        if (DYYYPlaybackTierIsUsableHDR(tier) && DYYYPlaybackTierRanksHigher(tier, best)) best = tier;
    }
    return best;
}

id DYYYSelectPlaybackTier(NSArray *tiers, DYYYPlaybackQualityMode mode, BOOL nativeHDRAllowed) {
    if (mode == DYYYPlaybackQualityOriginal) return nil;
    if (mode == DYYYPlaybackQualityPreferHDR && nativeHDRAllowed) {
        id hdrTier = DYYYSelectHDRPlaybackTier(tiers);
        if (hdrTier) return hdrTier;
    }
    // Denied HDR is not a playable fallback, even when it has the highest rate.
    return DYYYSelectHighestAllowedPlaybackTier(tiers, nativeHDRAllowed);
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
    if (mode == DYYYPlaybackQualityOriginal || !DYYYPlaybackTierHasUsableSource(nativeTier) ||
        ![tiers isKindOfClass:NSArray.class]) return nativeTier;
    id preferredTier = DYYYSelectPlaybackTier(tiers, mode, nativeHDRAllowed);
    if (!preferredTier || preferredTier == nativeTier) return nativeTier;
    for (id tier in tiers) {
        if (DYYYPlaybackSameSource(nativeTier, tier)) return preferredTier;
    }
    // A detached DASH model, stale URL or unrelated source stays native.
    return nativeTier;
}

id DYYYResolveNativePlaybackTierForVideo(id nativeTier, id video, DYYYPlaybackQualityMode mode, BOOL nativeHDRAllowed) {
    // Off/nil paths do not even read candidates; both enabled policies use this video.
    if (!nativeTier || !video || mode == DYYYPlaybackQualityOriginal) return nativeTier;
    @try {
        if (![video respondsToSelector:@selector(bitrateModels)]) return nativeTier;
        NSArray *tiers = [(id<DYYYPlaybackVideoTierSource>)video bitrateModels];
        return DYYYResolveNativePlaybackTier(nativeTier, tiers, mode, nativeHDRAllowed);
    } @catch (__unused NSException *exception) {
        return nativeTier;
    }
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
