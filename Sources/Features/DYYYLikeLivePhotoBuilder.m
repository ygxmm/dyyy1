#import "DYYYLikeLivePhotoBuilder.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>
#include <string.h>

static NSString *const DYYYLPErrorDomain = @"DYYYLikeLivePhotoBuilder";
static NSString *const DYYYLPStillKey = @"com.apple.quicktime.still-image-time";
static NSString *const DYYYLPContentKey = @"com.apple.quicktime.content.identifier";

typedef NS_ENUM(NSInteger, DYYYLPErrorCode) {
    DYYYLPInvalidInput = 1, DYYYLPImageCopy, DYYYLPMakerNote, DYYYLPMovie, DYYYLPTimeout,
};

typedef void (^DYYYLPCompletion)(NSURL * _Nullable, NSURL * _Nullable, NSError * _Nullable);

static NSError *DYYYLPError(DYYYLPErrorCode code, NSString *message, NSError *underlying) {
    NSMutableDictionary *info = [@{NSLocalizedDescriptionKey: message} mutableCopy];
    if (underlying) info[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:DYYYLPErrorDomain code:code userInfo:info];
}

BOOL DYYYLikeLivePhotoHasVideoError(NSError *error) {
    return [error.domain isEqualToString:DYYYLPErrorDomain] && error.code == DYYYLPMovie;
}

static AVMutableMetadataItem *DYYYLPItem(NSString *key, NSString *type, id value) {
    AVMutableMetadataItem *item = [AVMutableMetadataItem metadataItem];
    item.keySpace = AVMetadataKeySpaceQuickTimeMetadata;
    item.key = key;
    item.dataType = type;
    item.value = value;
    return item;
}

static BOOL DYYYLPIsDescriptionItem(AVMetadataItem *item) {
    if ([item.keySpace isEqualToString:AVMetadataKeySpaceQuickTimeMetadata] &&
        [item.key isEqual:AVMetadataQuickTimeMetadataKeyDescription]) return YES;
    return [item.keySpace isEqualToString:AVMetadataKeySpaceCommon] &&
        [item.key isEqual:AVMetadataCommonKeyDescription];
}

static NSURL *DYYYLPTempURL(NSString *uuid, NSString *extension) {
    return [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:[NSString stringWithFormat:@"DYYYLikeLivePhoto-%@.%@", uuid, extension]
                        isDirectory:NO];
}

static BOOL DYYYLPWritePhoto(NSURL *sourceURL, NSString *identifier, NSURL * __strong *outputURL, NSError **error);

// All mutable state and AVFoundation calls belong to a single job's serial queue.
@interface DYYYLikeLivePhotoJob : NSObject {
    dispatch_queue_t _queue;
    dispatch_source_t _watchdog;
    dispatch_time_t _deadline;
    DYYYLPCompletion _completion;
    AVURLAsset *_asset;
    AVAssetReader *_reader;
    AVAssetWriter *_writer;
    NSURL *_photoOutput, *_movieOutput;
    NSString *_identifier;
    NSString *_albumDescription;
    CMTime _duration;
    NSUInteger _pendingInputs;
    BOOL _done;
}
- (void)dyyy_startWithPhoto:(NSURL *)photo video:(NSURL *)video albumDescription:(NSString * _Nullable)albumDescription completion:(DYYYLPCompletion)completion;
@end

@implementation DYYYLikeLivePhotoJob

- (void)dyyy_finish:(NSError *)error {
    if (_done) return;
    _done = YES;
    dispatch_source_cancel(_watchdog);
    _watchdog = nil;
    if (error) {
        [_asset cancelLoading];
        if (_reader.status == AVAssetReaderStatusReading) [_reader cancelReading];
        if (_writer.status == AVAssetWriterStatusWriting) [_writer cancelWriting];
        if (_photoOutput) [[NSFileManager defaultManager] removeItemAtURL:_photoOutput error:NULL];
        if (_movieOutput) [[NSFileManager defaultManager] removeItemAtURL:_movieOutput error:NULL];
    }
    DYYYLPCompletion completion = _completion;
    NSURL *photo = error ? nil : _photoOutput;
    NSURL *movie = error ? nil : _movieOutput;
    _completion = nil;
    _asset = nil;
    _reader = nil;
    _writer = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ completion(photo, movie, error); });
}

- (void)dyyy_failMovie:(NSString *)message cause:(NSError *)cause {
    [self dyyy_finish:DYYYLPError(DYYYLPMovie, message, cause)];
}

- (void)dyyy_failException:(NSException *)exception {
    [self dyyy_failMovie:exception.reason ?: @"AVFoundation 无法透传此视频。" cause:nil];
}

- (BOOL)dyyy_checkProgress {
    if (_done) return NO;
    if (dispatch_time(DISPATCH_TIME_NOW, 0) >= _deadline) {
        [self dyyy_finish:DYYYLPError(DYYYLPTimeout, @"构建实况照片超时。", nil)];
    } else if (_reader.status == AVAssetReaderStatusFailed || _reader.status == AVAssetReaderStatusCancelled) {
        [self dyyy_failMovie:@"读取原视频失败。" cause:_reader.error];
    } else if (_writer.status == AVAssetWriterStatusFailed || _writer.status == AVAssetWriterStatusCancelled) {
        [self dyyy_failMovie:@"写入 MOV 失败。" cause:_writer.error];
    }
    return !_done;
}

- (void)dyyy_finishInput:(AVAssetWriterInput *)input {
    [input markAsFinished];
    if (--_pendingInputs) return;
    if (_reader.status != AVAssetReaderStatusCompleted) {
        [self dyyy_failMovie:@"未完整读完全部音视频轨道。" cause:_reader.error];
        return;
    }
    [_writer endSessionAtSourceTime:_duration];
    __weak typeof(self) weakSelf = self;
    dispatch_queue_t queue = _queue;
    [_writer finishWritingWithCompletionHandler:^{
        dispatch_async(queue, ^{
            typeof(self) job = weakSelf;
            if (![job dyyy_checkProgress]) return;
            if (job->_writer.status != AVAssetWriterStatusCompleted) {
                [job dyyy_failMovie:@"MOV 未能完成写入。" cause:job->_writer.error];
            } else {
                [job dyyy_finish:nil];
            }
        });
    }];
}

- (void)dyyy_pumpOutput:(AVAssetReaderTrackOutput *)output into:(AVAssetWriterInput *)input {
    __weak typeof(self) weakSelf = self;
    __weak AVAssetWriterInput *weakInput = input;
    __block BOOL hasSamples = NO;
    [input requestMediaDataWhenReadyOnQueue:_queue usingBlock:^{
        typeof(self) job = weakSelf;
        AVAssetWriterInput *target = weakInput;
        @try {
            while (target.readyForMoreMediaData && [job dyyy_checkProgress]) {
                id sample = CFBridgingRelease([output copyNextSampleBuffer]);
                if (!sample) {
                    if (![job dyyy_checkProgress]) return;
                    if (!hasSamples) {
                        [job dyyy_failMovie:@"原视频含有无法复制的空音视频轨道。" cause:nil];
                    } else {
                        [job dyyy_finishInput:target];
                    }
                    return;
                }
                if (![target appendSampleBuffer:(__bridge CMSampleBufferRef)sample]) {
                    [job dyyy_failMovie:@"写入原始音视频样本失败。" cause:job->_writer.error];
                    return;
                }
                hasSamples = YES;
            }
        } @catch (NSException *exception) {
            [job dyyy_failException:exception];
        }
    }];
}

- (void)dyyy_beginMovie {
    NSError *error = nil;
    _duration = _asset.duration;
    if (!CMTIME_IS_NUMERIC(_duration) || CMTimeCompare(_duration, kCMTimeZero) <= 0) {
        [self dyyy_failMovie:@"原视频的时长无效。" cause:nil];
        return;
    }
    _reader = [[AVAssetReader alloc] initWithAsset:_asset error:&error];
    if (!_reader) { [self dyyy_failMovie:@"无法打开原视频。" cause:error]; return; }
    _movieOutput = DYYYLPTempURL(_identifier, @"mov");
    _writer = [[AVAssetWriter alloc] initWithURL:_movieOutput fileType:AVFileTypeQuickTimeMovie error:&error];
    if (!_writer) { [self dyyy_failMovie:@"无法创建临时 MOV。" cause:error]; return; }
    NSMutableArray<AVMetadataItem *> *metadata = [NSMutableArray array];
    for (AVMetadataItem *item in _asset.metadata) {
        BOOL replaceDescription = _albumDescription.length > 0 && DYYYLPIsDescriptionItem(item);
        if (!replaceDescription &&
            ![item.identifier isEqualToString:AVMetadataIdentifierQuickTimeMetadataContentIdentifier]) {
            [metadata addObject:item];
        }
    }
    [metadata addObject:DYYYLPItem(DYYYLPContentKey, (__bridge NSString *)kCMMetadataBaseDataType_UTF8, _identifier)];
    if (_albumDescription.length > 0) {
        [metadata addObject:DYYYLPItem(AVMetadataQuickTimeMetadataKeyDescription,
            (__bridge NSString *)kCMMetadataBaseDataType_UTF8, _albumDescription)];
    }
    _writer.metadata = metadata;

    NSMutableArray<AVAssetReaderTrackOutput *> *outputs = [NSMutableArray array];
    NSMutableArray<AVAssetWriterInput *> *inputs = [NSMutableArray array];
    AVAssetTrack *primaryVideo = nil;
    for (AVAssetTrack *track in _asset.tracks) {
        BOOL video = [track.mediaType isEqualToString:AVMediaTypeVideo];
        if (!video && ![track.mediaType isEqualToString:AVMediaTypeAudio]) continue;
        CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
        if (!format) { [self dyyy_failMovie:@"原视频轨道缺少格式描述。" cause:nil]; return; }
        AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:track outputSettings:nil];
        output.alwaysCopiesSampleData = NO;
        AVAssetWriterInput *input = [[AVAssetWriterInput alloc] initWithMediaType:track.mediaType outputSettings:nil sourceFormatHint:format];
        input.metadata = track.metadata;
        input.languageCode = track.languageCode;
        input.extendedLanguageTag = track.extendedLanguageTag;
        input.marksOutputTrackAsEnabled = track.enabled;
        if (video) {
            input.transform = track.preferredTransform;
            if (track.naturalTimeScale > 0) input.mediaTimeScale = track.naturalTimeScale;
            if (!primaryVideo || (!primaryVideo.enabled && track.enabled)) primaryVideo = track;
        } else {
            input.preferredVolume = track.preferredVolume;
        }
        if (![_reader canAddOutput:output] || ![_writer canAddInput:input]) {
            [self dyyy_failMovie:@"原视频含有不能原样写入 MOV 的音视频轨道。" cause:nil];
            return;
        }
        [_reader addOutput:output];
        [_writer addInput:input];
        [outputs addObject:output];
        [inputs addObject:input];
    }
    CMTime start = primaryVideo ? primaryVideo.timeRange.start : kCMTimeInvalid;
    if (!CMTIME_IS_NUMERIC(start) || CMTimeCompare(start, _duration) >= 0) {
        [self dyyy_failMovie:@"原视频没有有效的画面轨道。" cause:nil];
        return;
    }
    // With no supplied still-frame offset, mark the start of the primary video track.
    start = CMTimeMaximum(kCMTimeZero, start);
    CMTime length = CMTimeMinimum(CMTimeMake(1, 600), CMTimeSubtract(_duration, start));
    AVMetadataItem *stillItem = DYYYLPItem(DYYYLPStillKey, (__bridge NSString *)kCMMetadataBaseDataType_SInt8, @(-1));
    AVTimedMetadataGroup *group = [[AVTimedMetadataGroup alloc] initWithItems:@[stillItem] timeRange:CMTimeRangeMake(start, length)];
    NSArray *specs = @[@{
        (__bridge NSString *)kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier : [@"mdta/" stringByAppendingString:DYYYLPStillKey],
        (__bridge NSString *)kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType : (__bridge NSString *)kCMMetadataBaseDataType_SInt8,
    }];
    CMFormatDescriptionRef description = NULL;
    OSStatus status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(kCFAllocatorDefault,
        kCMMetadataFormatType_Boxed, (__bridge CFArrayRef)specs, &description);
    id format = CFBridgingRelease(description);
    if (status != noErr || !format) {
        [self dyyy_failMovie:@"无法建立实况照片时间标记格式。"
                       cause:[NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil]];
        return;
    }
    AVAssetWriterInput *marker = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeMetadata
        outputSettings:nil sourceFormatHint:(__bridge CMFormatDescriptionRef)format];
    AVAssetWriterInputMetadataAdaptor *adaptor = [[AVAssetWriterInputMetadataAdaptor alloc] initWithAssetWriterInput:marker];
    if (![_writer canAddInput:marker]) { [self dyyy_failMovie:@"无法添加 MOV 的实况时间轨道。" cause:nil]; return; }
    [_writer addInput:marker];
    if (![_writer startWriting]) { [self dyyy_failMovie:@"无法开始写入 MOV。" cause:_writer.error]; return; }
    [_writer startSessionAtSourceTime:kCMTimeZero];
    if (![_reader startReading]) { [self dyyy_failMovie:@"无法开始读取原视频。" cause:_reader.error]; return; }

    _pendingInputs = inputs.count + 1;
    __weak typeof(self) weakSelf = self;
    __weak AVAssetWriterInput *weakMarker = marker;
    [marker requestMediaDataWhenReadyOnQueue:_queue usingBlock:^{
        typeof(self) job = weakSelf;
        AVAssetWriterInput *target = weakMarker;
        if (![job dyyy_checkProgress] || !target.readyForMoreMediaData) return;
        @try {
            if ([adaptor appendTimedMetadataGroup:group]) [job dyyy_finishInput:target];
            else [job dyyy_failMovie:@"无法写入实况时间标记。" cause:job->_writer.error];
        } @catch (NSException *exception) {
            [job dyyy_failException:exception];
        }
    }];
    for (NSUInteger i = 0; i < inputs.count; i++) [self dyyy_pumpOutput:outputs[i] into:inputs[i]];
}

- (void)dyyy_startWithPhoto:(NSURL *)photo video:(NSURL *)video albumDescription:(NSString *)albumDescription completion:(DYYYLPCompletion)completion {
    _queue = dispatch_queue_create("DYYYLikeLivePhotoBuilder", DISPATCH_QUEUE_SERIAL);
    _completion = [completion copy];
    _albumDescription = [albumDescription copy];
    _deadline = dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC);
    dispatch_async(_queue, ^{
        self->_watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
        dispatch_source_set_timer(self->_watchdog, dispatch_time(DISPATCH_TIME_NOW, 0),
                                  250 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
        // Own the job until the one terminal path cancels the source.
        dispatch_source_set_event_handler(self->_watchdog, ^{ [self dyyy_checkProgress]; });
        dispatch_resume(self->_watchdog);
        if (![self dyyy_checkProgress]) return;
        if (!photo.isFileURL || !video.isFileURL) {
            [self dyyy_finish:DYYYLPError(DYYYLPInvalidInput, @"需要本地图片和视频文件。", nil)];
            return;
        }
        @try {
            self->_identifier = NSUUID.UUID.UUIDString;
            NSError *error = nil;
            if (!DYYYLPWritePhoto(photo, self->_identifier, &self->_photoOutput, &error)) {
                [self dyyy_finish:error];
                return;
            }
            if (![self dyyy_checkProgress]) return;
            self->_asset = [AVURLAsset URLAssetWithURL:video options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @YES}];
            NSArray<NSString *> *keys = @[@"tracks", @"duration", @"metadata"];
            __weak typeof(self) weakSelf = self;
            dispatch_queue_t queue = self->_queue;
            [self->_asset loadValuesAsynchronouslyForKeys:keys completionHandler:^{
                dispatch_async(queue, ^{
                    typeof(self) job = weakSelf;
                    if (![job dyyy_checkProgress]) return;
                    @try {
                        for (NSString *key in keys) {
                            NSError *loadError = nil;
                            if ([job->_asset statusOfValueForKey:key error:&loadError] != AVKeyValueStatusLoaded) {
                                [job dyyy_failMovie:@"无法载入原视频的轨道与元数据。" cause:loadError];
                                return;
                            }
                        }
                        [job dyyy_beginMovie];
                    } @catch (NSException *exception) {
                        [job dyyy_failException:exception];
                    }
                });
            }];
        } @catch (NSException *exception) {
            [self dyyy_failException:exception];
        }
    });
}

@end

static BOOL DYYYLPPhotoHasIdentifier(NSURL *url, CFStringRef type, size_t count, NSString *identifier) {
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return NO;
    NSDictionary *props = nil;
    if (CGImageSourceGetStatus(source) == kCGImageStatusComplete && CGImageSourceGetCount(source) == count &&
        [(__bridge NSString *)type isEqual:(__bridge NSString *)CGImageSourceGetType(source)]) {
        props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), NULL));
    }
    CFRelease(source);
    return [identifier isEqual:props[(__bridge NSString *)kCGImagePropertyMakerAppleDictionary][@"17"]];
}

static uint32_t DYYYLPReadInt(const uint8_t *bytes, size_t width, BOOL little) {
    uint32_t value = 0;
    for (size_t i = 0; i < width; ++i) value = (value << 8) | bytes[little ? width - i - 1 : i];
    return value;
}

static void DYYYLPWriteInt(uint8_t *bytes, size_t width, uint32_t value, BOOL little) {
    for (size_t i = 0; i < width; ++i) {
        bytes[little ? i : width - i - 1] = (uint8_t)value;
        value >>= 8;
    }
}

// Append a replacement IFD; its predecessors, value offsets, and next-IFD pointer remain intact.
static uint32_t DYYYLPAppendIFD(NSMutableData *tiff, uint32_t old, BOOL little, uint16_t tag,
                                uint16_t type, uint32_t count, uint32_t value, BOOL replace,
                                uint32_t *oldValue, uint32_t *newField) {
    const uint8_t *b = tiff.bytes;
    size_t entries = 0, at = 0;
    BOOL found = NO;
    if (old) {
        if (old < 8 || old > tiff.length || tiff.length - old < 6) return 0;
        entries = DYYYLPReadInt(b + old, 2, little);
        if (entries > (tiff.length - old - 6) / 12) return 0;
        for (; at < entries && DYYYLPReadInt(b + old + 2 + 12 * at, 2, little) < tag; ++at) {}
        for (size_t i = at; i < entries; ++i) {
            const uint8_t *entry = b + old + 2 + 12 * i;
            if (DYYYLPReadInt(entry, 2, little) != tag) continue;
            if (!replace || found || i != at || DYYYLPReadInt(entry + 2, 2, little) != type ||
                DYYYLPReadInt(entry + 4, 4, little) != count) return 0;
            found = YES;
            if (oldValue) {
                *oldValue = DYYYLPReadInt(entry + 8, 4, little);
                if (*oldValue < 8 || *oldValue == old) return 0;
            }
        }
    }
    size_t total = entries + !found;
    size_t offset = (tiff.length + 1) & ~(size_t)1;
    if (offset + 6 + 12 * total > 65527) return 0; // JPEG segment length includes its length word and Exif signature.
    NSMutableData *ifd = [NSMutableData dataWithLength:6 + 12 * total];
    uint8_t *d = ifd.mutableBytes;
    DYYYLPWriteInt(d, 2, (uint32_t)total, little);
    if (old) {
        memcpy(d + 2, b + old + 2, at * 12);
        size_t rest = at + found;
        memcpy(d + 2 + 12 * (at + 1), b + old + 2 + 12 * rest, 4 + 12 * (entries - rest));
    }
    d += 2 + 12 * at;
    DYYYLPWriteInt(d, 2, tag, little);
    DYYYLPWriteInt(d + 2, 2, type, little);
    DYYYLPWriteInt(d + 4, 4, count, little);
    DYYYLPWriteInt(d + 8, 4, value, little);
    if (newField) *newField = (uint32_t)(offset + 2 + 12 * at + 8);
    [tiff setLength:offset];
    [tiff appendData:ifd];
    return (uint32_t)offset;
}

static NSData *DYYYLPPairedTIFF(const uint8_t *input, NSUInteger length, NSString *identifier) {
    NSMutableData *tiff;
    BOOL little = NO;
    uint32_t oldRoot = 0, oldExif = 0, exifPointer = 0;
    if (!input) {
        const uint8_t header[8] = {'M', 'M', 0, 42, 0, 0, 0, 0};
        tiff = [NSMutableData dataWithBytes:header length:sizeof(header)];
    } else {
        if (length < 8 || length > 65527) return nil;
        little = !memcmp(input, "II", 2);
        if ((!little && memcmp(input, "MM", 2)) || DYYYLPReadInt(input + 2, 2, little) != 42) return nil;
        oldRoot = DYYYLPReadInt(input + 4, 4, little);
        if (oldRoot < 8) return nil;
        tiff = [NSMutableData dataWithBytes:input length:length];
    }
    NSUInteger originalLength = tiff.length;
    uint32_t root = DYYYLPAppendIFD(tiff, oldRoot, little, 0x8769, 4, 1, 0, YES, &oldExif, &exifPointer);
    if (!root) return nil;
    if (oldExif) {
        if ((oldExif & 1) || oldExif >= originalLength || originalLength - oldExif < 6) return nil;
        const uint8_t *original = tiff.bytes;
        if (DYYYLPReadInt(original + oldExif, 2, little) > (originalLength - oldExif - 6) / 12) return nil;
    }
    // Apple MakerNote uses independent big-endian offsets relative to its own header.
    uint8_t maker[32] = {'A','p','p','l','e',' ','i','O','S',0, 0,1,'M','M', 0,1, 0,0x11,0,2};
    NSData *uuid = [identifier dataUsingEncoding:NSASCIIStringEncoding];
    if (uuid.length != 36) return nil;
    DYYYLPWriteInt(maker + 20, 4, 37, NO);
    DYYYLPWriteInt(maker + 24, 4, sizeof(maker), NO);
    uint32_t makerOffset = (uint32_t)tiff.length;
    uint8_t nul = 0;
    [tiff appendBytes:maker length:sizeof(maker)];
    [tiff appendData:uuid];
    [tiff appendBytes:&nul length:1];
    // Never discard or relocate an existing vendor MakerNote.
    uint32_t subIFD = DYYYLPAppendIFD(tiff, oldExif, little, 0x927c, 7, sizeof(maker) + 37, makerOffset, NO, NULL, NULL);
    if (!subIFD) return nil;
    uint8_t *rewritten = tiff.mutableBytes;
    DYYYLPWriteInt(rewritten + 4, 4, root, little);
    DYYYLPWriteInt(rewritten + exifPointer, 4, subIFD, little);
    return tiff;
}

static NSData *DYYYLPReadStillForMetadata(NSURL *input, NSError **error) {
    NSNumber *size = nil;
    const NSUInteger limit = 64 * 1024 * 1024;
    if (![input getResourceValue:&size forKey:NSURLFileSizeKey error:error] ||
        ![size isKindOfClass:NSNumber.class] || size.unsignedLongLongValue > limit) return nil;
    NSData *data = [NSData dataWithContentsOfURL:input options:NSDataReadingMappedIfSafe error:error];
    return data.length <= limit ? data : nil;
}

static BOOL DYYYLPWriteJPEG(NSURL *input, NSURL *output, NSString *identifier, NSError **error) {
    __attribute__((objc_precise_lifetime)) NSData *jpeg = DYYYLPReadStillForMetadata(input, error);
    const uint8_t *b = jpeg.bytes;
    NSUInteger n = jpeg.length, p = 2, insertion = 2, scan = 0;
    NSRange exif = NSMakeRange(NSNotFound, 0);
    if (n < 4 || b[0] != 0xff || b[1] != 0xd8) return NO;
    while (p < n) {
        if (b[p++] != 0xff) return NO;
        while (p < n && b[p] == 0xff) ++p;
        if (p >= n) return NO;
        NSUInteger marker = p - 1;
        uint8_t code = b[p++];
        if (code == 1) continue; // TEM marker has no length.
        if (code == 0 || (code >= 0xd0 && code <= 0xd9) || n - p < 2) return NO;
        NSUInteger length = DYYYLPReadInt(b + p, 2, NO);
        if (length < 2 || length > n - p) return NO;
        if (code == 0xda) { scan = marker; break; }
        if (code == 0xe0 && insertion == marker) insertion = p + length;
        if (code == 0xe2 && length >= 6 && !memcmp(b + p + 2, "MPF\0", 4)) return NO;
        if (code == 0xe1 && length >= 8 && !memcmp(b + p + 2, "Exif\0\0", 6)) {
            if (exif.location != NSNotFound) return NO;
            exif = NSMakeRange(marker, length + 2);
        }
        p += length;
    }
    if (!scan) return NO;

    NSData *tiff = exif.location == NSNotFound ? DYYYLPPairedTIFF(NULL, 0, identifier) :
        DYYYLPPairedTIFF(b + exif.location + 10, exif.length - 10, identifier);
    if (!tiff) return NO;
    if (exif.location == NSNotFound) exif = NSMakeRange(insertion, 0);

    uint8_t app1[10] = {0xff, 0xe1, 0, 0, 'E','x','i','f',0,0};
    DYYYLPWriteInt(app1 + 2, 2, (uint32_t)tiff.length + 8, NO);
    NSMutableData *result = [NSMutableData dataWithCapacity:n - exif.length + sizeof(app1) + tiff.length];
    [result appendBytes:b length:exif.location];
    [result appendBytes:app1 length:sizeof(app1)];
    [result appendData:tiff];
    // This tail includes every scan header and every compressed scan byte, unmodified.
    NSUInteger tail = NSMaxRange(exif);
    [result appendBytes:b + tail length:n - tail];
    return [result writeToURL:output options:NSDataWritingAtomic error:error];
}

static uint32_t DYYYLPChunkCRC(const uint8_t *bytes, NSUInteger length) {
    uint32_t crc = UINT32_MAX;
    for (NSUInteger i = 0; i < length; ++i) {
        crc ^= bytes[i];
        for (NSUInteger bit = 0; bit < 8; ++bit) {
            crc = (crc >> 1) ^ ((crc & 1) ? UINT32_C(0xedb88320) : 0);
        }
    }
    return crc ^ UINT32_MAX;
}

static BOOL DYYYLPWritePNG(NSURL *input, NSURL *output, NSString *identifier, NSError **error) {
    __attribute__((objc_precise_lifetime)) NSData *png = DYYYLPReadStillForMetadata(input, error);
    const uint8_t *bytes = png.bytes;
    const uint8_t signature[] = {137, 'P', 'N', 'G', 13, 10, 26, 10};
    NSUInteger size = png.length;
    if (size < 45 || memcmp(bytes, signature, sizeof(signature)) ||
        DYYYLPReadInt(bytes + 8, 4, NO) != 13 || memcmp(bytes + 12, "IHDR", 4)) return NO;

    NSRange exif = NSMakeRange(NSNotFound, 0);
    BOOL sawData = NO, sawEnd = NO;
    for (NSUInteger pos = 33; pos <= size && size - pos >= 12;) {
        NSUInteger length = DYYYLPReadInt(bytes + pos, 4, NO);
        if (length > size - pos - 12) return NO;
        const uint8_t *type = bytes + pos + 4;
        if (!memcmp(type, "eXIf", 4)) {
            if (exif.location != NSNotFound || length < 8 || length > 65527) return NO;
            if (DYYYLPChunkCRC(type, length + 4) != DYYYLPReadInt(type + length + 4, 4, NO)) return NO;
            exif = NSMakeRange(pos, length + 12);
        } else if (!memcmp(type, "IDAT", 4)) {
            sawData = YES;
        } else if (!memcmp(type, "IEND", 4)) {
            sawEnd = length == 0 && pos + 12 == size;
            break;
        } else if (!memcmp(type, "IHDR", 4) || !memcmp(type, "acTL", 4)) {
            return NO; // Invalid header or actually animated, not a Live Photo still.
        }
        pos += length + 12;
    }
    if (!sawData || !sawEnd) return NO;
    NSData *tiff = exif.location == NSNotFound ? DYYYLPPairedTIFF(NULL, 0, identifier) :
        DYYYLPPairedTIFF(bytes + exif.location + 8, exif.length - 12, identifier);
    if (!tiff) return NO;
    if (exif.location == NSNotFound) exif = NSMakeRange(33, 0); // Immediately after IHDR.

    NSMutableData *chunk = [NSMutableData dataWithLength:8];
    uint8_t *header = chunk.mutableBytes;
    DYYYLPWriteInt(header, 4, (uint32_t)tiff.length, NO);
    memcpy(header + 4, "eXIf", 4);
    [chunk appendData:tiff];
    uint8_t crc[4];
    DYYYLPWriteInt(crc, 4, DYYYLPChunkCRC((const uint8_t *)chunk.bytes + 4, chunk.length - 4), NO);
    [chunk appendBytes:crc length:sizeof(crc)];

    // Copy IDAT, color, XMP and all other chunks byte-for-byte.
    NSMutableData *result = [NSMutableData dataWithCapacity:size - exif.length + chunk.length];
    [result appendBytes:bytes length:exif.location];
    [result appendData:chunk];
    NSUInteger tail = NSMaxRange(exif);
    [result appendBytes:bytes + tail length:size - tail];
    return [result writeToURL:output options:NSDataWritingAtomic error:error];
}

static BOOL DYYYLPWritePhoto(NSURL *sourceURL, NSString *identifier, NSURL * __strong *outputURL, NSError **error) {
    __attribute__((objc_precise_lifetime)) id sourceObject = CFBridgingRelease(CGImageSourceCreateWithURL((__bridge CFURLRef)sourceURL, NULL));
    CGImageSourceRef source = (__bridge CGImageSourceRef)sourceObject;
    if (!source || CGImageSourceGetStatus(source) != kCGImageStatusComplete) {
        *error = DYYYLPError(DYYYLPInvalidInput, @"无法读取完整的原始图片。", nil);
        return NO;
    }
    NSString *type = (__bridge NSString *)CGImageSourceGetType(source);
    NSString *extension = (@{@"public.heic" : @"heic", @"public.heif" : @"heif", @"public.jpeg" : @"jpg", @"public.png" : @"png"})[type ?: @""];
    size_t count = CGImageSourceGetCount(source);
    if (!extension || count == 0 || ([extension isEqualToString:@"png"] && count != 1)) {
        *error = DYYYLPError(DYYYLPImageCopy, @"该图片格式不能作为实况照片的无损静帧。", nil);
        return NO;
    }
    *outputURL = DYYYLPTempURL(identifier, extension);
    if ([type isEqualToString:@"public.png"]) {
        NSError *pngError = nil;
        if (DYYYLPWritePNG(sourceURL, *outputURL, identifier, &pngError) &&
            DYYYLPPhotoHasIdentifier(*outputURL, (__bridge CFStringRef)type, count, identifier)) return YES;
        *error = DYYYLPError(DYYYLPMakerNote, @"无法无损写入或验证实况 PNG 配对标记。", pngError);
        return NO;
    }
    size_t index = CGImageSourceGetPrimaryImageIndex(source);
    NSString *makerKey = (__bridge NSString *)kCGImagePropertyMakerAppleDictionary;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, index, NULL));
    NSMutableDictionary *maker = [properties[makerKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    maker[@"17"] = identifier;
    NSMutableDictionary *options = [@{makerKey : maker} mutableCopy];
    id metadata = CFBridgingRelease(CGImageMetadataCreateMutable());
    if (metadata && CGImageMetadataSetValueMatchingImageProperty((__bridge CGMutableImageMetadataRef)metadata,
            kCGImagePropertyMakerAppleDictionary, CFSTR("17"), (__bridge CFStringRef)identifier)) {
        options[(__bridge NSString *)kCGImageDestinationMetadata] = metadata;
        options[(__bridge NSString *)kCGImageDestinationMergeMetadata] = @YES;
    }
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)*outputURL,
        (__bridge CFStringRef)type, count, NULL);
    CFErrorRef copyError = NULL;
    BOOL copied = NO;
    if (destination) {
        CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)@{makerKey : maker});
        // CopyImageSource completes the destination itself; a subsequent Finalize is invalid.
        copied = CGImageDestinationCopyImageSource(destination, source, (__bridge CFDictionaryRef)options, &copyError);
        CFRelease(destination);
    }
    NSError *underlying = CFBridgingRelease(copyError);
    if (copied && !underlying && DYYYLPPhotoHasIdentifier(*outputURL, (__bridge CFStringRef)type, count, identifier)) return YES;
    if ([type isEqualToString:@"public.jpeg"] && count == 1) {
        NSError *fallbackError = nil;
        if (!DYYYLPWriteJPEG(sourceURL, *outputURL, identifier, &fallbackError)) {
            *error = DYYYLPError(DYYYLPMakerNote, @"不能安全地在原 JPEG 中加入 Apple Maker 17（EXIF 已有 MakerNote、格式异常、超出限制或写入失败）。", fallbackError ?: underlying);
        } else if (!DYYYLPPhotoHasIdentifier(*outputURL, (__bridge CFStringRef)type, count, identifier)) {
            *error = DYYYLPError(DYYYLPMakerNote, @"ImageIO 无法从原样写入的 JPEG 中读回 Apple Maker 17。", nil);
        } else {
            return YES;
        }
        return NO;
    }
    *error = DYYYLPError(copied && !underlying ? DYYYLPMakerNote : DYYYLPImageCopy,
        @"ImageIO 未能在原格式中无损写入并验证 Apple Maker 17，未进行转码。", underlying);
    return NO;
}

void DYYYLikeBuildLivePhoto(NSURL *photoURL, NSURL *videoURL, NSString *albumDescription, DYYYLPCompletion completion) {
    if (!completion) return;
    [[DYYYLikeLivePhotoJob new] dyyy_startWithPhoto:photoURL video:videoURL albumDescription:albumDescription completion:completion];
}
