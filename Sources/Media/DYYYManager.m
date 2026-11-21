#import "DYYYManager.h"
#import "DYYYDownloadLifecycle.h"
#import <CoreAudioTypes/CoreAudioTypes.h>
#import <CoreMedia/CMMetadata.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <MobileCoreServices/UTCoreTypes.h>
#import <Photos/Photos.h>

#import "DYYYMediaChooserSheet.h"
#import "DYYYConstants.h"
#import "DYYYToast.h"
#import "DYYYUtils.h"

static void DYYYDownloadOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) block(); else dispatch_async(dispatch_get_main_queue(), block);
}

static NSString *DYYYAuthorProfileURL(AWEUserModel *author) {
    if (!author) {
        return nil;
    }

    if ([author respondsToSelector:@selector(secUserID)]) {
        NSString *secUserID = author.secUserID;
        if ([secUserID isKindOfClass:[NSString class]] && secUserID.length > 0) {
            return [NSString stringWithFormat:@"https://www.douyin.com/user/%@", secUserID];
        }
    }

    return nil;
}

static NSString *DYYYCompactAlbumURL(NSString *rawURL) {
    if (![rawURL isKindOfClass:[NSString class]] || rawURL.length == 0) {
        return nil;
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:rawURL];
    NSString *scheme = components.scheme.lowercaseString;
    NSString *host = components.host.lowercaseString;
    NSString *path = components.percentEncodedPath.length > 0 ? components.percentEncodedPath : components.path;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) {
        return nil;
    }
    if (host.length == 0 || path.length == 0 || ![path hasPrefix:@"/"]) {
        return nil;
    }

    // 只保留协议、域名和路径，明确丢弃 query 与 fragment，避免把分享追踪参数写入相册。
    return [NSString stringWithFormat:@"%@://%@%@", scheme, host, path];
}

static NSString *DYYYAlbumDescriptionForAwemeModel(AWEAwemeModel *awemeModel, NSString *authorProfileURL, NSString *workURL) {
    if (!awemeModel) {
        return nil;
    }

    NSMutableArray<NSString *> *fields = [NSMutableArray array];
    AWEUserModel *author = awemeModel.author;
    NSString *nickname = author.nickname;
    if ([nickname isKindOfClass:[NSString class]] && nickname.length > 0) {
        [fields addObject:[NSString stringWithFormat:@"抖音作者：%@", nickname]];
    }

    NSString *displayID = nil;
    if ([author respondsToSelector:@selector(uniqueIDForShow)]) {
        displayID = [author uniqueIDForShow];
    }
    if (![displayID isKindOfClass:[NSString class]] || displayID.length == 0) {
        if ([author respondsToSelector:@selector(tiktokDisplayID)]) {
            displayID = [author tiktokDisplayID];
        }
    }
    if (![displayID isKindOfClass:[NSString class]] || displayID.length == 0) {
        displayID = author.shortID;
    }
    if ([displayID isKindOfClass:[NSString class]] && displayID.length > 0) {
        [fields addObject:[NSString stringWithFormat:@"作者 ID：%@", displayID]];
    }

    NSString *resolvedAuthorProfileURL = authorProfileURL.length > 0 ? authorProfileURL : DYYYAuthorProfileURL(author);
    if ([resolvedAuthorProfileURL isKindOfClass:[NSString class]] && resolvedAuthorProfileURL.length > 0) {
        [fields addObject:[NSString stringWithFormat:@"作者主页：%@", resolvedAuthorProfileURL]];
    }

    NSString *caption = nil;
    if ([awemeModel respondsToSelector:@selector(caption)]) {
        caption = awemeModel.caption;
    }
    if (![caption isKindOfClass:[NSString class]] || caption.length == 0) {
        caption = awemeModel.descriptionString;
    }
    if ([caption isKindOfClass:[NSString class]] && caption.length > 0) {
        [fields addObject:[NSString stringWithFormat:@"作品文案：%@", caption]];
    }

    NSString *resolvedWorkURL = DYYYCompactAlbumURL(workURL.length > 0 ? workURL : awemeModel.shareURL);
    if ([resolvedWorkURL isKindOfClass:[NSString class]] && resolvedWorkURL.length > 0) {
        [fields addObject:[NSString stringWithFormat:@"作品链接：%@", resolvedWorkURL]];
    }

    NSNumber *createTime = awemeModel.createTime;
    if ([createTime isKindOfClass:[NSNumber class]] && createTime.doubleValue > 0) {
        static NSDateFormatter *formatter = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
          formatter = [[NSDateFormatter alloc] init];
          formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
          formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        });
        NSDate *date = [NSDate dateWithTimeIntervalSince1970:createTime.doubleValue];
        @synchronized (formatter) {
            [fields addObject:[NSString stringWithFormat:@"发布时间：%@", [formatter stringFromDate:date]]];
        }
    }

    if (fields.count == 0) {
        return nil;
    }
    return [fields componentsJoinedByString:@"\n"];
}

@interface DYYYManager () {
    AVAssetExportSession *session;
    AVURLAsset *asset;
    AVAssetReader *reader;
    AVAssetWriter *writer;
    dispatch_queue_t queue;
    dispatch_group_t group;
}

/** 图集「保存全部」的落地：静图走批量图片，实况走批量实况，两者都有则依次跑。 */
+ (void)saveGalleryImages:(NSArray<NSString *> *)imageURLs livePhotos:(NSArray<NSDictionary *> *)livePhotos albumDescription:(NSString *)albumDescription;

/** 把说明文字嵌进图片副本，返回临时文件；失败返回 nil。 */
+ (NSURL *)temporaryImageURLByEmbeddingDescription:(NSString *)albumDescription intoImageAtURL:(NSURL *)imageURL;

/** 把说明文字嵌进视频副本（直通封装、不转码），失败时回调 nil。 */
+ (void)writeDescription:(NSString *)albumDescription toVideoAtURL:(NSURL *)videoURL completion:(void (^)(NSURL *outputURL))completion;

/** 在原有条目基础上追加说明文字条目。 */
+ (NSArray<AVMetadataItem *> *)metadataItemsByAppendingDescription:(NSString *)albumDescription toItems:(NSArray<AVMetadataItem *> *)items;

/** 替换视频资源中的原始创建日期，避免相册继续读取相同的容器时间。 */
+ (NSArray<AVMetadataItem *> *)metadataItemsBySettingCreationDate:(NSDate *)creationDate toItems:(NSArray<AVMetadataItem *> *)items;

+ (NSUInteger)downloadCancellationGeneration;
- (void)cancelDownloadWithID:(NSString *)downloadID;
- (void)deliverDownload:(NSString *)downloadID success:(BOOL)success fileURL:(NSURL *)fileURL;
- (void)completeBatchDownload:(NSString *)downloadID success:(BOOL)success fileURL:(NSURL *)fileURL;
+ (void)downloadMediaWithProgress:(NSURL *)url mediaType:(MediaType)mediaType audio:(NSURL *)audioURL progress:(void (^)(float))progressBlock keepLifecycle:(BOOL)keepLifecycle completion:(void (^)(BOOL, NSURL *))completion;
+ (void)downloadMediaWithProgress:(NSURL *)url mediaType:(MediaType)mediaType audio:(NSURL *)audioURL progress:(void (^)(float))progressBlock keepLifecycle:(BOOL)keepLifecycle showProgress:(BOOL)showProgress ownerID:(NSString *)ownerID completion:(void (^)(BOOL, NSURL *))completion;
+ (void)downloadAudioAndMergeVideo:(NSURL *)videoURL audioURL:(NSURL *)audioURL ownerID:(NSString *)ownerID state:(NSMutableDictionary *)state completion:(void (^)(BOOL, NSURL *))completion;
+ (void)downloadAllImagesWithProgress:(NSMutableArray *)imageURLs albumDescription:(NSString *)albumDescription progress:(void (^)(NSInteger, NSInteger))progressBlock completion:(void (^)(NSInteger, NSInteger))completion;
+ (void)downloadAllLivePhotosWithProgress:(NSArray<NSDictionary *> *)livePhotos albumDescription:(NSString *)albumDescription progress:(void (^)(NSInteger, NSInteger))progressBlock completion:(void (^)(NSInteger, NSInteger))completion;
+ (void)downloadAllLivePhotosWithProgress:(NSArray<NSDictionary *> *)livePhotos albumDescription:(NSString *)albumDescription scopedCancellation:(BOOL)scopedCancellation progress:(void (^)(NSInteger, NSInteger))progressBlock completion:(void (^)(NSInteger, NSInteger))completion;
+ (void)downloadLivePhoto:(NSURL *)imageURL videoURL:(NSURL *)videoURL albumDescription:(NSString *)albumDescription completion:(void (^)(void))completion;
+ (void)downloadParsedVideos:(NSArray *)videos images:(NSArray *)images albumDescription:(NSString *)albumDescription;

/** 存实况照片，并把说明文字写进配对的图片与视频。 */
- (void)saveLivePhoto:(NSString *)imageSourcePath videoUrl:(NSString *)videoSourcePath albumDescription:(NSString *)albumDescription;

/** 由文件建相册资产，保留文件里已嵌好的元数据。 */
+ (void)createAssetAtURL:(NSURL *)assetURL
               mediaType:(MediaType)mediaType
             originalURL:(NSURL *)originalURL
            temporaryURL:(NSURL *)temporaryURL
               lifecycle:(NSMutableDictionary *)state
            reportResult:(void (^)(BOOL success))reportResult;

@end

@interface DYYYManager () <NSURLSessionDownloadDelegate>
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSURLSessionTask *> *downloadTasks;
@property(nonatomic, strong) NSMutableDictionary<NSString *, DYYYToast *> *progressViews;
@property(nonatomic, strong) NSOperationQueue *downloadQueue;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *taskProgressMap;
@property(nonatomic, strong) NSMutableDictionary<NSString *, void (^)(BOOL success, NSURL *fileURL)> *completionBlocks;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *mediaTypeMap;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *filePathToDownloadID;

// 任务状态跨越网络、授权和保存阶段，不再借用单例说明上下文。
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *downloadStates;
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *progressBlocks;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *downloadOwnerMap;
@property(nonatomic, assign) NSUInteger cancellationGeneration;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *albumDescriptionMap;

// 批量下载相关属性
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *downloadToBatchMap;                                                 // 下载ID到批量ID的映射
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *batchCompletedCountMap;                                             // 批量ID到已完成数量的映射
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *batchSuccessCountMap;                                               // 批量ID到成功数量的映射
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *batchTotalCountMap;                                                 // 批量ID到总数量的映射
@property(nonatomic, strong) NSMutableDictionary<NSString *, void (^)(NSInteger current, NSInteger total)> *batchProgressBlocks;              // 批量进度回调
@property(nonatomic, strong) NSMutableDictionary<NSString *, void (^)(NSInteger successCount, NSInteger totalCount)> *batchCompletionBlocks;  // 批量完成回调
@end

@implementation DYYYManager

+ (instancetype)shared {
    static DYYYManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _fileLinks = [NSMutableDictionary dictionary];
        _downloadTasks = [NSMutableDictionary dictionary];
        _progressViews = [NSMutableDictionary dictionary];
        _downloadQueue = [[NSOperationQueue alloc] init];
        _downloadQueue.maxConcurrentOperationCount = 3;
        _taskProgressMap = [NSMutableDictionary dictionary];
        _completionBlocks = [NSMutableDictionary dictionary];
        _mediaTypeMap = [NSMutableDictionary dictionary];
        _filePathToDownloadID = [NSMutableDictionary dictionary];
        _albumDescriptionMap = [NSMutableDictionary dictionary];
        _downloadStates = [NSMutableDictionary dictionary];
        _progressBlocks = [NSMutableDictionary dictionary];
        _downloadOwnerMap = [NSMutableDictionary dictionary];

        // 初始化批量下载相关字典
        _downloadToBatchMap = [NSMutableDictionary dictionary];
        _batchCompletedCountMap = [NSMutableDictionary dictionary];
        _batchSuccessCountMap = [NSMutableDictionary dictionary];
        _batchTotalCountMap = [NSMutableDictionary dictionary];
        _batchProgressBlocks = [NSMutableDictionary dictionary];
        _batchCompletionBlocks = [NSMutableDictionary dictionary];
    }
    return self;
}

+ (NSString *)albumDescriptionForAwemeModel:(AWEAwemeModel *)awemeModel {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:DYYY_ALBUM_MEDIA_DESCRIPTION_KEY]) return nil;
    if (!awemeModel) {
        return nil;
    }

    return DYYYAlbumDescriptionForAwemeModel(awemeModel,
                                             DYYYAuthorProfileURL(awemeModel.author),
                                             DYYYCompactAlbumURL(awemeModel.shareURL));
}

+ (void)setAlbumDescriptionContextWithAwemeModel:(AWEAwemeModel *)awemeModel {
    // 仅兼容旧调用；说明必须由作品入口显式传入，禁止跨入口串源。
    (void)awemeModel;
}

+ (void)saveMedia:(NSURL *)mediaURL mediaType:(MediaType)mediaType completion:(void (^)(BOOL success))completion {
    [self saveMedia:mediaURL mediaType:mediaType albumDescription:nil completion:completion];
}

+ (void)saveMedia:(NSURL *)mediaURL mediaType:(MediaType)mediaType albumDescription:(NSString *)albumDescription completion:(void (^)(BOOL success))completion {
    if (![NSThread isMainThread]) {
        NSString *description = [albumDescription copy];
        dispatch_async(dispatch_get_main_queue(), ^{ [self saveMedia:mediaURL mediaType:mediaType albumDescription:description completion:completion]; });
        return;
    }
    DYYYManager *manager = [DYYYManager shared];
    NSString *downloadID = [manager downloadIDForFileURL:mediaURL];
    NSMutableDictionary *state = downloadID ? manager.downloadStates[downloadID] : nil;
    BOOL isBatchDownload = downloadID && manager.downloadToBatchMap[downloadID] != nil;
    NSMutableDictionary *resultState = DYYYDownloadCreateState();
    void (^reportResult)(BOOL) = ^(BOOL success) {
        DYYYDownloadOnMain(^{
            if (!DYYYDownloadTakeCallback(resultState)) return;
            BOOL result = success && DYYYDownloadStateIsActive(state);
            if (!isBatchDownload && downloadID) [manager finalizeDownloadWithID:downloadID success:result fileURL:mediaURL];
            if (completion) completion(result);
        });
    };
    if (!mediaURL || mediaType == MediaTypeAudio) { reportResult(NO); return; }
    albumDescription = [albumDescription copy];
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        if (!DYYYDownloadStateIsActive(state) || status != PHAuthorizationStatusAuthorized) {
            [[NSFileManager defaultManager] removeItemAtURL:mediaURL error:nil];
            DYYYDownloadOnMain(^{
                if (DYYYDownloadStateIsActive(state)) [DYYYUtils showToast:@"请允许访问相册权限后重试"];
                reportResult(NO);
            });
            return;
        }
        if (mediaType == MediaTypeHeic) {
            NSString *format = [DYYYUtils detectFileFormat:mediaURL];
            // 转换只改变编码；进入相册事务前仍须检查本次任务状态。
            void (^saveGIF)(NSURL *, BOOL) = ^(NSURL *gifURL, BOOL converted) {
                if (!converted || !gifURL || !DYYYDownloadStateIsActive(state)) {
                    if (gifURL) [[NSFileManager defaultManager] removeItemAtURL:gifURL error:nil];
                    [[NSFileManager defaultManager] removeItemAtURL:mediaURL error:nil];
                    reportResult(NO);
                    return;
                }
                __block BOOL resourceAdded = NO;
                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                    NSData *gifData = [NSData dataWithContentsOfURL:gifURL];
                    if (!gifData) return;
                    DYYYDownloadPerformIfActive(state, ^{
                        PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
                        PHAssetResourceCreationOptions *options = [[PHAssetResourceCreationOptions alloc] init];
                        options.uniformTypeIdentifier = @"com.compuserve.gif";
                        [request addResourceWithType:PHAssetResourceTypePhoto data:gifData options:options];
                        resourceAdded = YES;
                    });
                } completionHandler:^(BOOL success, NSError *error) {
                    [[NSFileManager defaultManager] removeItemAtURL:gifURL error:nil];
                    [[NSFileManager defaultManager] removeItemAtURL:mediaURL error:nil];
                    if (!success && DYYYDownloadStateIsActive(state)) DYYYDownloadOnMain(^{ [DYYYUtils showToast:@"保存失败"]; });
                    reportResult(success && resourceAdded);
                }];
            };
            if ([format isEqualToString:@"webp"]) { [DYYYUtils convertWebpToGifSafely:mediaURL completion:saveGIF]; return; }
            if ([format isEqualToString:@"heic"] || [format isEqualToString:@"heif"]) { [DYYYUtils convertHeicToGif:mediaURL completion:saveGIF]; return; }
            if ([format isEqualToString:@"gif"]) { saveGIF(mediaURL, YES); return; }
            if (!DYYYDownloadStateIsActive(state)) { [[NSFileManager defaultManager] removeItemAtURL:mediaURL error:nil]; reportResult(NO); return; }
            __block BOOL imageAdded = NO;
            [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                UIImage *image = [UIImage imageWithContentsOfFile:mediaURL.path];
                if (image) imageAdded = DYYYDownloadPerformIfActive(state, ^{ [PHAssetChangeRequest creationRequestForAssetFromImage:image]; });
            } completionHandler:^(BOOL success, NSError *error) {
                [[NSFileManager defaultManager] removeItemAtURL:mediaURL error:nil];
                reportResult(success && imageAdded);
            }];
            return;
        }
        if (!albumDescription.length) {
            [self createAssetAtURL:mediaURL mediaType:mediaType originalURL:mediaURL temporaryURL:nil lifecycle:state reportResult:reportResult];
        } else if (mediaType == MediaTypeVideo) {
            [self writeDescription:albumDescription toVideoAtURL:mediaURL completion:^(NSURL *decoratedURL) {
                [self createAssetAtURL:decoratedURL ?: mediaURL mediaType:mediaType originalURL:mediaURL temporaryURL:decoratedURL lifecycle:state reportResult:reportResult];
            }];
        } else {
            NSURL *decoratedURL = [self temporaryImageURLByEmbeddingDescription:albumDescription intoImageAtURL:mediaURL];
            [self createAssetAtURL:decoratedURL ?: mediaURL mediaType:mediaType originalURL:mediaURL temporaryURL:decoratedURL lifecycle:state reportResult:reportResult];
        }
    }];
}

+ (void)createAssetAtURL:(NSURL *)assetURL
               mediaType:(MediaType)mediaType
             originalURL:(NSURL *)originalURL
            temporaryURL:(NSURL *)temporaryURL
               lifecycle:(NSMutableDictionary *)state
            reportResult:(void (^)(BOOL success))reportResult {
    if (!DYYYDownloadStateIsActive(state)) {
        if (temporaryURL) [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:originalURL error:nil];
        reportResult(NO);
        return;
    }
    [[PHPhotoLibrary sharedPhotoLibrary]
        performChanges:^{
          // 创建请求与取消采用原子交接；已经创建的 PhotoKit 请求无法撤回。
          DYYYDownloadPerformIfActive(state, ^{
              // 按文件原样入库，保留说明元数据。
              PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
              PHAssetResourceType resourceType = (mediaType == MediaTypeVideo) ? PHAssetResourceTypeVideo : PHAssetResourceTypePhoto;
              [request addResourceWithType:resourceType fileURL:assetURL options:nil];
          });
        }
        completionHandler:^(BOOL success, NSError *_Nullable error) {
          if (!success && mediaType != MediaTypeVideo && DYYYDownloadStateIsActive(state)) {
              // 少数图片的实际编码与扩展名不符，按文件入库会被 PhotoKit 拒；退回解码后再存。
              UIImage *image = [UIImage imageWithContentsOfFile:assetURL.path];
              if (image) {
                  [[PHPhotoLibrary sharedPhotoLibrary]
                      performChanges:^{
                        DYYYDownloadPerformIfActive(state, ^{ [PHAssetChangeRequest creationRequestForAssetFromImage:image]; });
                      }
                      completionHandler:^(BOOL retrySuccess, NSError *_Nullable retryError) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                          if (!retrySuccess && DYYYDownloadStateIsActive(state)) {
                              [DYYYUtils showToast:@"保存失败"];
                          }
                          if (temporaryURL) {
                              [[NSFileManager defaultManager] removeItemAtPath:temporaryURL.path error:nil];
                          }
                          [[NSFileManager defaultManager] removeItemAtPath:originalURL.path error:nil];
                          reportResult(retrySuccess);
                        });
                      }];
                  return;
              }
          }

          dispatch_async(dispatch_get_main_queue(), ^{
            if (!success && DYYYDownloadStateIsActive(state)) {
                [DYYYUtils showToast:@"保存失败"];
            }
            if (temporaryURL) {
                [[NSFileManager defaultManager] removeItemAtPath:temporaryURL.path error:nil];
            }
            [[NSFileManager defaultManager] removeItemAtPath:originalURL.path error:nil];
            reportResult(success);
          });
        }];
}

+ (NSURL *)temporaryImageURLByEmbeddingDescription:(NSString *)albumDescription intoImageAtURL:(NSURL *)imageURL {
    if (albumDescription.length == 0 || !imageURL) {
        return nil;
    }

    CGImageSourceRef source = CGImageSourceCreateWithURL((CFURLRef)imageURL, NULL);
    if (!source) {
        return nil;
    }

    CFStringRef sourceType = CGImageSourceGetType(source);
    NSString *outputName = [NSString stringWithFormat:@"dyyy_desc_%@.%@", [NSUUID UUID].UUIDString, imageURL.pathExtension.length > 0 ? imageURL.pathExtension : @"jpg"];
    NSURL *outputURL = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:outputName];

    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((CFURLRef)outputURL, sourceType ?: kUTTypeJPEG, 1, NULL);
    if (!destination) {
        CFRelease(source);
        return nil;
    }

    NSDictionary *existingProperties = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    NSMutableDictionary *properties = existingProperties ? [existingProperties mutableCopy] : [NSMutableDictionary dictionary];

    NSMutableDictionary *tiff = [properties[(NSString *)kCGImagePropertyTIFFDictionary] mutableCopy] ?: [NSMutableDictionary dictionary];
    tiff[(NSString *)kCGImagePropertyTIFFImageDescription] = albumDescription;
    properties[(NSString *)kCGImagePropertyTIFFDictionary] = tiff;

    NSMutableDictionary *iptc = [properties[(NSString *)kCGImagePropertyIPTCDictionary] mutableCopy] ?: [NSMutableDictionary dictionary];
    iptc[(NSString *)kCGImagePropertyIPTCCaptionAbstract] = albumDescription;
    properties[(NSString *)kCGImagePropertyIPTCDictionary] = iptc;

    NSMutableDictionary *exif = [properties[(NSString *)kCGImagePropertyExifDictionary] mutableCopy] ?: [NSMutableDictionary dictionary];
    exif[(NSString *)kCGImagePropertyExifUserComment] = albumDescription;
    properties[(NSString *)kCGImagePropertyExifDictionary] = exif;

    CGImageDestinationAddImageFromSource(destination, source, 0, (CFDictionaryRef)properties);
    BOOL finalized = CGImageDestinationFinalize(destination);

    CFRelease(destination);
    CFRelease(source);

    if (!finalized) {
        [[NSFileManager defaultManager] removeItemAtPath:outputURL.path error:nil];
        return nil;
    }
    return outputURL;
}

+ (NSArray<AVMetadataItem *> *)metadataItemsByAppendingDescription:(NSString *)albumDescription toItems:(NSArray<AVMetadataItem *> *)items {
    NSMutableArray<AVMetadataItem *> *result = items ? [items mutableCopy] : [NSMutableArray array];
    if (albumDescription.length == 0) {
        return result;
    }

    AVMutableMetadataItem *quickTimeItem = [AVMutableMetadataItem metadataItem];
    quickTimeItem.keySpace = AVMetadataKeySpaceQuickTimeMetadata;
    quickTimeItem.key = AVMetadataQuickTimeMetadataKeyDescription;
    quickTimeItem.value = albumDescription;
    [result addObject:quickTimeItem];

    AVMutableMetadataItem *commonItem = [AVMutableMetadataItem metadataItem];
    commonItem.keySpace = AVMetadataKeySpaceCommon;
    commonItem.key = AVMetadataCommonKeyDescription;
    commonItem.value = albumDescription;
    [result addObject:commonItem];

    return result;
}

+ (NSArray<AVMetadataItem *> *)metadataItemsBySettingCreationDate:(NSDate *)creationDate toItems:(NSArray<AVMetadataItem *> *)items {
    if (!creationDate) {
        return items ?: @[];
    }

    NSMutableArray<AVMetadataItem *> *result = [NSMutableArray array];
    for (AVMetadataItem *item in items) {
        BOOL isCommonCreationDate = [item.keySpace isEqualToString:AVMetadataKeySpaceCommon] && [item.key isEqual:AVMetadataCommonKeyCreationDate];
        BOOL isQuickTimeCreationDate = [item.keySpace isEqualToString:AVMetadataKeySpaceQuickTimeMetadata] && [item.key isEqual:@"com.apple.quicktime.creationdate"];
        if (!isCommonCreationDate && !isQuickTimeCreationDate) {
            [result addObject:item];
        }
    }

    AVMutableMetadataItem *commonItem = [AVMutableMetadataItem metadataItem];
    commonItem.keySpace = AVMetadataKeySpaceCommon;
    commonItem.key = AVMetadataCommonKeyCreationDate;
    commonItem.value = creationDate;
    [result addObject:commonItem];

    NSDateFormatter *quickTimeDateFormatter = [[NSDateFormatter alloc] init];
    quickTimeDateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    quickTimeDateFormatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";

    AVMutableMetadataItem *quickTimeItem = [AVMutableMetadataItem metadataItem];
    quickTimeItem.keySpace = AVMetadataKeySpaceQuickTimeMetadata;
    quickTimeItem.key = @"com.apple.quicktime.creationdate";
    quickTimeItem.value = [quickTimeDateFormatter stringFromDate:creationDate];
    [result addObject:quickTimeItem];

    return result;
}

+ (void)writeDescription:(NSString *)albumDescription toVideoAtURL:(NSURL *)videoURL completion:(void (^)(NSURL *outputURL))completion {
    void (^report)(NSURL *) = ^(NSURL *outputURL) {
        if (completion) {
            completion(outputURL);
        }
    };

    if (albumDescription.length == 0 || !videoURL) {
        report(nil);
        return;
    }

    AVURLAsset *sourceAsset = [AVURLAsset URLAssetWithURL:videoURL options:nil];
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:sourceAsset presetName:AVAssetExportPresetPassthrough];
    if (!export || ![export.supportedFileTypes containsObject:AVFileTypeQuickTimeMovie]) {
        report(nil);
        return;
    }

    NSString *outputName = [NSString stringWithFormat:@"dyyy_desc_%@.mov", [NSUUID UUID].UUIDString];
    NSURL *outputURL = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:outputName];
    [[NSFileManager defaultManager] removeItemAtPath:outputURL.path error:nil];

    // 直通封装：只重写容器和元数据，不重新编码，画质与体积都不变。
    export.outputURL = outputURL;
    export.outputFileType = AVFileTypeQuickTimeMovie;
    export.metadata = [self metadataItemsByAppendingDescription:albumDescription toItems:sourceAsset.metadata];

    [export exportAsynchronouslyWithCompletionHandler:^{
      if (export.status == AVAssetExportSessionStatusCompleted) {
          report(outputURL);
          return;
      }
      [[NSFileManager defaultManager] removeItemAtPath:outputURL.path error:nil];
      report(nil);
    }];
}

+ (void)downloadLivePhoto:(NSURL *)imageURL videoURL:(NSURL *)videoURL completion:(void (^)(void))completion {
    [self downloadLivePhoto:imageURL videoURL:videoURL albumDescription:nil completion:completion];
}

+ (void)downloadLivePhoto:(NSURL *)imageURL videoURL:(NSURL *)videoURL albumDescription:(NSString *)albumDescription completion:(void (^)(void))completion {
    if (!imageURL || !videoURL) { if (completion) completion(); return; }
    [self downloadAllLivePhotosWithProgress:@[@{@"imageURL":imageURL.absoluteString, @"videoURL":videoURL.absoluteString}]
                            albumDescription:[albumDescription copy] scopedCancellation:YES progress:nil
                                  completion:^(NSInteger successCount, NSInteger totalCount) { if (completion) completion(); }];
}

+ (void)downloadMedia:(NSURL *)url mediaType:(MediaType)mediaType audio:(NSURL *)audioURL completion:(void (^)(BOOL success))completion {
    [self downloadMedia:url mediaType:mediaType audio:audioURL albumDescription:nil completion:completion];
}

+ (void)downloadMedia:(NSURL *)url mediaType:(MediaType)mediaType audio:(NSURL *)audioURL albumDescription:(NSString *)albumDescription completion:(void (^)(BOOL success))completion {
    albumDescription = [albumDescription copy];
    NSMutableDictionary *notificationState = DYYYDownloadCreateState();
    [self downloadMediaWithProgress:url
                          mediaType:mediaType
                              audio:audioURL
                           progress:nil
                       keepLifecycle:YES
                         completion:^(BOOL success, NSURL *fileURL) {
                           void (^notifyCompletion)(BOOL) = ^(BOOL result) {
                               if (DYYYDownloadTakeCallback(notificationState) && completion) completion(result);
                           };

                           if (success) {
                               DYYYManager *manager = [DYYYManager shared];
                               NSString *downloadID = [manager downloadIDForFileURL:fileURL];
                               NSMutableDictionary *state = downloadID ? manager.downloadStates[downloadID] : nil;
                               if (!state) { [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil]; notifyCompletion(NO); return; }
                               state[@"cancelCompletion"] = [^{ notifyCompletion(NO); } copy];
                               if (!DYYYDownloadStateIsActive(state)) { notifyCompletion(NO); return; }
                               if (mediaType == MediaTypeAudio) {
                                   DYYYDownloadOnMain(^{
                                     if (!DYYYDownloadStateIsActive(state)) { [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil]; notifyCompletion(NO); return; }
                                     UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
                                     if (!rootVC) {
                                         [[DYYYManager shared] finalizeDownloadWithFileURL:fileURL success:NO];
                                         [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
                                         notifyCompletion(NO);
                                         return;
                                     }
                                     [[DYYYManager shared] finalizeDownloadWithFileURL:fileURL success:YES];
                                     UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[ fileURL ] applicationActivities:nil];

                                     [activityVC setCompletionWithItemsHandler:^(UIActivityType _Nullable activityType, BOOL completed, NSArray *_Nullable returnedItems, NSError *_Nullable error) {
                                       dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                         [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
                                       });
                                     }];
                                     [rootVC presentViewController:activityVC animated:YES completion:nil];
                                     notifyCompletion(YES);
                                   });
                               } else {
                                   if (mediaType == MediaTypeVideo && audioURL) {
                                       if (![DYYYUtils videoHasAudio:fileURL]) {
                                           [self downloadAudioAndMergeVideo:fileURL
                                                                            audioURL:audioURL
                                                                             ownerID:downloadID
                                                                               state:state
                                                                          completion:^(BOOL mergeSuccess, NSURL *mergedURL) {
                                                                       if (!DYYYDownloadStateIsActive(state)) {
                                                                           [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
                                                                           if (mergedURL) [[NSFileManager defaultManager] removeItemAtURL:mergedURL error:nil];
                                                                           notifyCompletion(NO);
                                                                           return;
                                                                       }
                                                                       if (mergeSuccess) {
                                                                           [[DYYYManager shared] replaceFileURL:fileURL withFileURL:mergedURL];
                                                                           [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
                                                                           [self saveMedia:mergedURL
                                                                                 mediaType:mediaType
                                                                          albumDescription:albumDescription
                                                                                completion:^(BOOL saveSuccess) {
                                                                                  notifyCompletion(saveSuccess);
                                                                                }];
                                                                       } else {
                                                                           [self saveMedia:fileURL
                                                                                 mediaType:mediaType
                                                                          albumDescription:albumDescription
                                                                                completion:^(BOOL saveSuccess) {
                                                                                  notifyCompletion(saveSuccess);
                                                                                }];
                                                                       }
                                                                     }];
                                           return;
                                       }
                                   }
                                   [self saveMedia:fileURL
                                         mediaType:mediaType
                                  albumDescription:albumDescription
                                        completion:^(BOOL saveSuccess) {
                                          notifyCompletion(saveSuccess);
                                        }];
                               }
                           } else {
                               notifyCompletion(NO);
                               if (fileURL) {
                                   [[DYYYManager shared] finalizeDownloadWithFileURL:fileURL success:NO];
                               }
                           }
                         }];
}

+ (void)downloadMediaWithProgress:(NSURL *)url
                        mediaType:(MediaType)mediaType
                            audio:(NSURL *)audioURL
                         progress:(void (^)(float progress))progressBlock
                       completion:(void (^)(BOOL success, NSURL *fileURL))completion {
    [self downloadMediaWithProgress:url mediaType:mediaType audio:audioURL progress:progressBlock keepLifecycle:NO completion:completion];
}

+ (void)downloadMediaWithProgress:(NSURL *)url mediaType:(MediaType)mediaType audio:(NSURL *)audioURL progress:(void (^)(float))progressBlock keepLifecycle:(BOOL)keepLifecycle completion:(void (^)(BOOL, NSURL *))completion {
    [self downloadMediaWithProgress:url mediaType:mediaType audio:audioURL progress:progressBlock keepLifecycle:keepLifecycle showProgress:YES ownerID:nil completion:completion];
}

+ (void)downloadMediaWithProgress:(NSURL *)url mediaType:(MediaType)mediaType audio:(NSURL *)audioURL progress:(void (^)(float))progressBlock keepLifecycle:(BOOL)keepLifecycle showProgress:(BOOL)showProgress ownerID:(NSString *)ownerID completion:(void (^)(BOOL, NSURL *))completion {
    NSUInteger generation = [self downloadCancellationGeneration];
    DYYYDownloadOnMain(^{
      DYYYManager *manager = [DYYYManager shared];
      if (generation != [self downloadCancellationGeneration] || (ownerID && !DYYYDownloadStateIsActive(manager.downloadStates[ownerID])) || (ownerID && !manager.downloadStates[ownerID])) {
          if (completion) completion(NO, nil);
          return;
      }
      // 创建进度视图
      CGRect screenBounds = [UIScreen mainScreen].bounds;
      DYYYToast *progressView = showProgress ? [[DYYYToast alloc] initWithFrame:screenBounds] : nil;

      // 生成下载ID并保存进度视图
      NSString *downloadID = [NSUUID UUID].UUIDString;
      if (progressView) manager.progressViews[downloadID] = progressView;

      [progressView show];
      manager.downloadStates[downloadID] = DYYYDownloadCreateState();
      manager.downloadStates[downloadID][@"keepLifecycle"] = @(keepLifecycle);
      if (progressBlock) manager.progressBlocks[downloadID] = [progressBlock copy];
      progressView.cancelBlock = ^{ [[DYYYManager shared] cancelDownloadWithID:downloadID]; };

      // 保存回调
      [[DYYYManager shared] setCompletionBlock:completion forDownloadID:downloadID];
      [[DYYYManager shared] setMediaType:mediaType forDownloadID:downloadID];

      if (!url) { [manager deliverDownload:downloadID success:NO fileURL:nil]; return; }

      // 配置下载会话 - 使用带委托的会话以获取进度更新
      NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
      NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:[DYYYManager shared] delegateQueue:[NSOperationQueue mainQueue]];

      // 创建下载任务 - 不使用completionHandler，使用代理方法
      NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:url];
      downloadTask.taskDescription = downloadID;

      // 存储下载任务
      manager.downloadOwnerMap[downloadID] = ownerID ?: downloadID;
      [[DYYYManager shared].downloadTasks setObject:downloadTask forKey:downloadID];
      [[DYYYManager shared].taskProgressMap setObject:@0.0 forKey:downloadID];  // 初始化进度为0

      // 开始下载
      [downloadTask resume];
    });
}

// 任务注册及取消都串行到主队列，避免取消发生在任务尚未登记的空窗中。
+ (NSUInteger)downloadCancellationGeneration {
    DYYYManager *manager = [DYYYManager shared];
    @synchronized (manager) { return manager.cancellationGeneration; }
}

- (void)cancelDownloadWithID:(NSString *)downloadID {
    if (!downloadID.length) return;
    DYYYDownloadOnMain(^{
        NSMutableDictionary *state = self.downloadStates[downloadID];
        if (!state) return;
        BOOL requested = DYYYDownloadCancelState(state);
        NSString *batchID = self.downloadToBatchMap[downloadID];
        DYYYToast *view = self.progressViews[batchID ?: downloadID];
        view.isCancelled = YES;
        view.allowSuccessAnimation = NO;
        [view dismiss];
        NSMutableArray<NSURLSessionTask *> *tasks = [NSMutableArray array];
        for (NSString *taskID in DYYYDownloadTaskIDsForOwner(downloadID, self.downloadOwnerMap)) {
            DYYYDownloadCancelState(self.downloadStates[taskID]);
            NSURLSessionTask *task = self.downloadTasks[taskID];
            if (task) [tasks addObject:task];
        }
        if (self.downloadTasks[downloadID] && ![tasks containsObject:self.downloadTasks[downloadID]]) [tasks addObject:self.downloadTasks[downloadID]];
        DYYYDownloadCancelTasks(tasks);
        void (^notify)(void) = state[@"cancelCompletion"];
        if (requested && notify) notify();
        // 网络已交接给合并或保存时，仍立即回报取消；后续回调持有原状态并只做清理。
        if ([state[@"keepLifecycle"] boolValue] && !self.downloadTasks[downloadID]) {
            NSString *path = nil;
            @synchronized (self.filePathToDownloadID) { path = [self.filePathToDownloadID allKeysForObject:downloadID].firstObject; }
            [self finalizeDownloadWithID:downloadID success:NO fileURL:path ? [NSURL fileURLWithPath:path] : nil];
        }
    });
}

+ (void)cancelAllDownloads {
    void (^cancel)(void) = ^{
        DYYYManager *manager = [DYYYManager shared];
        @synchronized (manager) { manager.cancellationGeneration++; }
        for (NSString *downloadID in manager.downloadStates.allKeys) [manager cancelDownloadWithID:downloadID];
    };
    if ([NSThread isMainThread]) cancel(); else dispatch_sync(dispatch_get_main_queue(), cancel);
}

+ (void)downloadAudioAndMergeVideo:(NSURL *)videoURL audioURL:(NSURL *)audioURL ownerID:(NSString *)ownerID state:(NSMutableDictionary *)state completion:(void (^)(BOOL, NSURL *))completion {
    [self downloadMediaWithProgress:audioURL mediaType:MediaTypeAudio audio:nil progress:nil keepLifecycle:NO showProgress:NO ownerID:ownerID completion:^(BOOL success, NSURL *audioFile) {
        if (!success || !DYYYDownloadStateIsActive(state)) {
            if (audioFile) [[NSFileManager defaultManager] removeItemAtURL:audioFile error:nil];
            if (completion) completion(NO, nil);
            return;
        }
        [DYYYUtils mergeVideo:videoURL withAudio:audioFile completion:^(BOOL merged, NSURL *mergedURL) {
            [[NSFileManager defaultManager] removeItemAtURL:audioFile error:nil];
            if (!merged) [[NSFileManager defaultManager] removeItemAtPath:[DYYYUtils cachePathForFilename:[@"merged_" stringByAppendingString:videoURL.lastPathComponent]] error:nil];
            if (!DYYYDownloadStateIsActive(state)) {
                if (mergedURL) [[NSFileManager defaultManager] removeItemAtURL:mergedURL error:nil];
                merged = NO;
            }
            if (completion) completion(merged, merged ? mergedURL : nil);
        }];
    }];
}

+ (void)downloadAllImages:(NSMutableArray *)imageURLs {
    if (imageURLs.count == 0) {
        return;
    }

    [self downloadAllImagesWithProgress:imageURLs
                               progress:nil
                             completion:^(NSInteger successCount, NSInteger totalCount){
                             }];
}

+ (void)downloadAllImagesWithProgress:(NSMutableArray *)imageURLs
                             progress:(void (^)(NSInteger current, NSInteger total))progressBlock
                           completion:(void (^)(NSInteger successCount, NSInteger totalCount))completion {
    [self downloadAllImagesWithProgress:imageURLs albumDescription:nil progress:progressBlock completion:completion];
}

+ (void)downloadAllImagesWithProgress:(NSMutableArray *)imageURLs albumDescription:(NSString *)albumDescription progress:(void (^)(NSInteger current, NSInteger total))progressBlock completion:(void (^)(NSInteger successCount, NSInteger totalCount))completion {
    imageURLs = [imageURLs mutableCopy];
    if (imageURLs.count == 0) {
        if (completion) {
            completion(0, 0);
        }
        return;
    }

    NSString *batchAlbumDescription = [albumDescription copy];
    NSUInteger generation = [self downloadCancellationGeneration];
    DYYYDownloadOnMain(^{
      if (generation != [self downloadCancellationGeneration]) { if (completion) completion(0, imageURLs.count); return; }
      DYYYManager *manager = [DYYYManager shared];
      CGRect screenBounds = [UIScreen mainScreen].bounds;
      DYYYToast *progressView = [[DYYYToast alloc] initWithFrame:screenBounds];
      NSString *batchID = [NSUUID UUID].UUIDString;
      [[DYYYManager shared].progressViews setObject:progressView forKey:batchID];

      [progressView show];

      NSInteger totalCount = imageURLs.count;

      progressView.cancelBlock = ^{
        [self cancelAllDownloads];
      };

      // 存储批量下载的相关信息
      [[DYYYManager shared] setBatchInfo:batchID totalCount:totalCount progressBlock:progressBlock completionBlock:completion];

      // 为每个URL创建下载任务
      for (id urlString in imageURLs) {
          if (generation != [self downloadCancellationGeneration]) { [manager incrementCompletedAndUpdateProgressForBatch:batchID success:NO]; continue; }
          NSURL *url = [urlString isKindOfClass:[NSString class]] ? [NSURL URLWithString:urlString] : nil;
          if (!url) {
              [[DYYYManager shared] incrementCompletedAndUpdateProgressForBatch:batchID success:NO];
              continue;
          }

          // 创建单个下载任务ID
          NSString *downloadID = [NSUUID UUID].UUIDString;
          [[DYYYManager shared] associateDownload:downloadID withBatchID:batchID];
          [DYYYManager shared].downloadStates[downloadID] = DYYYDownloadCreateState();
          NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
          NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:[DYYYManager shared] delegateQueue:[NSOperationQueue mainQueue]];

          // 创建下载任务 - 使用代理方法
          NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:url];
          downloadTask.taskDescription = downloadID;
          manager.downloadOwnerMap[downloadID] = downloadID;
          [[DYYYManager shared].downloadTasks setObject:downloadTask forKey:downloadID];
          [[DYYYManager shared].taskProgressMap setObject:@0.0 forKey:downloadID];
          [[DYYYManager shared] setMediaType:MediaTypeImage forDownloadID:downloadID];
          if (batchAlbumDescription.length > 0) {
              [[DYYYManager shared].albumDescriptionMap setObject:batchAlbumDescription forKey:downloadID];
          }
          [downloadTask resume];
      }
    });
}

// 设置批量下载信息
- (void)setBatchInfo:(NSString *)batchID
          totalCount:(NSInteger)totalCount
       progressBlock:(void (^)(NSInteger current, NSInteger total))progressBlock
     completionBlock:(void (^)(NSInteger successCount, NSInteger totalCount))completionBlock {
    [self.batchTotalCountMap setObject:@(totalCount) forKey:batchID];
    [self.batchCompletedCountMap setObject:@(0) forKey:batchID];
    [self.batchSuccessCountMap setObject:@(0) forKey:batchID];

    if (progressBlock) {
        [self.batchProgressBlocks setObject:[progressBlock copy] forKey:batchID];
    }

    if (completionBlock) {
        [self.batchCompletionBlocks setObject:[completionBlock copy] forKey:batchID];
    }
}

// 关联单个下载到批量下载
- (void)associateDownload:(NSString *)downloadID withBatchID:(NSString *)batchID {
    [self.downloadToBatchMap setObject:batchID forKey:downloadID];
}

// 批量下载完成计数并更新进度
- (void)incrementCompletedAndUpdateProgressForBatch:(NSString *)batchID success:(BOOL)success {
    @synchronized(self) {
        if (!self.batchTotalCountMap[batchID]) return;
        NSNumber *completedCountNum = self.batchCompletedCountMap[batchID];
        NSInteger completedCount = completedCountNum ? [completedCountNum integerValue] + 1 : 1;
        [self.batchCompletedCountMap setObject:@(completedCount) forKey:batchID];

        if (success) {
            NSNumber *successCountNum = self.batchSuccessCountMap[batchID];
            NSInteger successCount = successCountNum ? [successCountNum integerValue] + 1 : 1;
            [self.batchSuccessCountMap setObject:@(successCount) forKey:batchID];
        }

        NSNumber *totalCountNum = self.batchTotalCountMap[batchID];
        NSInteger totalCount = totalCountNum ? [totalCountNum integerValue] : 0;

        DYYYToast *progressView = self.progressViews[batchID];
        if (progressView && !progressView.isCancelled) {
            float progress = totalCount > 0 ? (float)completedCount / totalCount : 0;
            [progressView setProgress:progress];
        }

        void (^progressBlock)(NSInteger current, NSInteger total) = self.batchProgressBlocks[batchID];
        if (progressBlock) {
            progressBlock(completedCount, totalCount);
        }

        if (completedCount >= totalCount) {
            NSInteger successCount = [self.batchSuccessCountMap[batchID] integerValue];

            void (^completionBlock)(NSInteger successCount, NSInteger totalCount) = self.batchCompletionBlocks[batchID];
            [self.batchCompletionBlocks removeObjectForKey:batchID];

            if (progressView) {
                progressView.allowSuccessAnimation = !progressView.isCancelled && (successCount == totalCount);
                [progressView dismiss];
            }
            [self.progressViews removeObjectForKey:batchID];

            // 清理批量下载相关信息
            [self.batchCompletedCountMap removeObjectForKey:batchID];
            [self.batchSuccessCountMap removeObjectForKey:batchID];
            [self.batchTotalCountMap removeObjectForKey:batchID];
            [self.batchProgressBlocks removeObjectForKey:batchID];
            [self.batchCompletionBlocks removeObjectForKey:batchID];

            // 移除关联的下载ID
            NSArray *downloadIDs = [self.downloadToBatchMap allKeysForObject:batchID];
            for (NSString *downloadID in downloadIDs) {
                [self.downloadToBatchMap removeObjectForKey:downloadID];
            }
            if (completionBlock) completionBlock(successCount, totalCount);
        }
    }
}

// 保存完成回调
- (void)setCompletionBlock:(void (^)(BOOL success, NSURL *fileURL))completion forDownloadID:(NSString *)downloadID {
    if (completion) {
        [self.completionBlocks setObject:[completion copy] forKey:downloadID];
    }
}

// 保存媒体类型
- (void)setMediaType:(MediaType)mediaType forDownloadID:(NSString *)downloadID {
    [self.mediaTypeMap setObject:@(mediaType) forKey:downloadID];
}

- (void)associateFileURL:(NSURL *)fileURL withDownloadID:(NSString *)downloadID {
    if (!fileURL || downloadID.length == 0) {
        return;
    }
    NSString *filePath = fileURL.path;
    if (filePath.length == 0) {
        return;
    }
    @synchronized(self.filePathToDownloadID) {
        self.filePathToDownloadID[filePath] = downloadID;
    }
}

- (NSString *)downloadIDForFileURL:(NSURL *)fileURL {
    if (!fileURL) {
        return nil;
    }
    NSString *filePath = fileURL.path;
    if (filePath.length == 0) {
        return nil;
    }
    @synchronized(self.filePathToDownloadID) {
        return self.filePathToDownloadID[filePath];
    }
}

- (void)replaceFileURL:(NSURL *)oldURL withFileURL:(NSURL *)newURL {
    if (!newURL) {
        return;
    }
    NSString *downloadID = [self downloadIDForFileURL:oldURL];
    if (downloadID.length == 0) {
        return;
    }
    NSString *newPath = newURL.path;
    if (newPath.length == 0) {
        return;
    }
    @synchronized(self.filePathToDownloadID) {
        if (oldURL.path.length > 0) {
            [self.filePathToDownloadID removeObjectForKey:oldURL.path];
        }
        self.filePathToDownloadID[newPath] = downloadID;
    }
}

- (void)removeMappingsForDownloadID:(NSString *)downloadID {
    if (downloadID.length == 0) {
        return;
    }
    @synchronized(self.filePathToDownloadID) {
        NSArray *keys = [self.filePathToDownloadID allKeysForObject:downloadID];
        for (NSString *key in keys) {
            [self.filePathToDownloadID removeObjectForKey:key];
        }
    }
}

- (void)finalizeDownloadWithFileURL:(NSURL *)fileURL success:(BOOL)success {
    NSString *downloadID = [self downloadIDForFileURL:fileURL];
    if (downloadID.length == 0) return;
    [self finalizeDownloadWithID:downloadID success:success fileURL:fileURL];
}

- (void)finalizeDownloadWithID:(NSString *)downloadID success:(BOOL)success fileURL:(NSURL *)fileURL {
    if (!downloadID.length) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self finalizeDownloadWithID:downloadID success:success fileURL:fileURL]; });
        return;
    }
    NSMutableDictionary *state = self.downloadStates[downloadID];
    BOOL cancelled = state && !DYYYDownloadStateIsActive(state);
    if (state && !DYYYDownloadFinishState(state)) return;
    DYYYToast *view = self.progressViews[downloadID];
    view.allowSuccessAnimation = success && !cancelled;
    if (success && !cancelled) [view setProgress:1.0f];
    [view dismiss];
    [self removeMappingsForDownloadID:downloadID];
    [self.progressViews removeObjectForKey:downloadID];
    [self.taskProgressMap removeObjectForKey:downloadID];
    [self.progressBlocks removeObjectForKey:downloadID];
    [self.completionBlocks removeObjectForKey:downloadID];
    [self.mediaTypeMap removeObjectForKey:downloadID];
    [self.albumDescriptionMap removeObjectForKey:downloadID];
    [self.downloadTasks removeObjectForKey:downloadID];
    [self.downloadOwnerMap removeObjectForKey:downloadID];
    [self.downloadToBatchMap removeObjectForKey:downloadID];
    [self.downloadStates removeObjectForKey:downloadID];
    if (cancelled && fileURL) [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
}

// 网络回调只消费一次，保存完成后才关闭需要继续保存的任务生命周期。
- (void)deliverDownload:(NSString *)downloadID success:(BOOL)success fileURL:(NSURL *)fileURL {
    NSMutableDictionary *state = self.downloadStates[downloadID];
    if (!state || !DYYYDownloadTakeCallback(state)) return;
    success = success && DYYYDownloadStateIsActive(state);
    void (^callback)(BOOL, NSURL *) = self.completionBlocks[downloadID];
    [self.completionBlocks removeObjectForKey:downloadID];
    if (!success || ![state[@"keepLifecycle"] boolValue] || !callback) {
        [self finalizeDownloadWithID:downloadID success:success fileURL:fileURL];
    }
    if (!success && fileURL) [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
    if (callback) callback(success, success ? fileURL : nil);
    else if (success && fileURL) [[NSFileManager defaultManager] removeItemAtURL:fileURL error:nil];
}

- (void)completeBatchDownload:(NSString *)downloadID success:(BOOL)success fileURL:(NSURL *)fileURL {
    NSMutableDictionary *state = self.downloadStates[downloadID];
    if (!state || !DYYYDownloadTakeCallback(state)) return;
    NSString *batchID = self.downloadToBatchMap[downloadID];
    success = success && DYYYDownloadStateIsActive(state);
    [self finalizeDownloadWithID:downloadID success:success fileURL:fileURL];
    if (batchID) [self incrementCompletedAndUpdateProgressForBatch:batchID success:success];
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    NSString *downloadID = task.taskDescription;
    if (!downloadID || !self.downloadStates[downloadID] || totalBytesExpectedToWrite <= 0 || !DYYYDownloadStateIsActive(self.downloadStates[downloadID])) return;
    float progress = (float)totalBytesWritten / totalBytesExpectedToWrite;
    self.taskProgressMap[downloadID] = @(progress);
    [self.progressViews[downloadID] setProgress:progress];
    void (^callback)(float) = self.progressBlocks[downloadID];
    if (callback) callback(progress);
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
    NSString *downloadID = task.taskDescription;
    if (!downloadID.length) return;
    NSMutableDictionary *state = self.downloadStates[downloadID];
    if (!state) return;
    BOOL batch = self.downloadToBatchMap[downloadID] != nil;
    MediaType mediaType = [self.mediaTypeMap[downloadID] integerValue];
    NSString *extension = @"jpg";
    switch (mediaType) {
        case MediaTypeVideo: extension = @"mp4"; break;
        case MediaTypeAudio: extension = @"mp3"; break;
        case MediaTypeHeic: extension = @"heic"; break;
        default: break;
    }
    NSURL *destination = DYYYDownloadTemporaryURL([NSURL fileURLWithPath:NSTemporaryDirectory()], task.originalRequest.URL, extension);
    NSError *error = nil;
    BOOL success = DYYYDownloadStateIsActive(state) && [[NSFileManager defaultManager] moveItemAtURL:location toURL:destination error:&error];
    if (success) [self associateFileURL:destination withDownloadID:downloadID];
    else [[NSFileManager defaultManager] removeItemAtURL:destination error:nil];
    [self.downloadTasks removeObjectForKey:downloadID];
    if (batch) {
        if (!success) { [self completeBatchDownload:downloadID success:NO fileURL:nil]; return; }
        [DYYYManager saveMedia:destination mediaType:mediaType albumDescription:self.albumDescriptionMap[downloadID] completion:^(BOOL saved) {
            [self completeBatchDownload:downloadID success:saved fileURL:destination];
        }];
    } else {
        [self deliverDownload:downloadID success:success fileURL:success ? destination : nil];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [session finishTasksAndInvalidate];
    NSString *downloadID = task.taskDescription;
    if (!error || !downloadID || !self.downloadStates[downloadID]) return;
    if (error.code != NSURLErrorCancelled && self.progressViews[downloadID] && DYYYDownloadStateIsActive(self.downloadStates[downloadID])) [DYYYUtils showToast:@"下载失败"];
    if (self.downloadToBatchMap[downloadID]) [self completeBatchDownload:downloadID success:NO fileURL:nil];
    else [self deliverDownload:downloadID success:NO fileURL:nil];
}

// MARK: 以下都是创建保存实况的调用方法
- (void)saveLivePhoto:(NSString *)imageSourcePath videoUrl:(NSString *)videoSourcePath {
    [self saveLivePhoto:imageSourcePath videoUrl:videoSourcePath albumDescription:nil];
}

- (void)saveLivePhoto:(NSString *)imageSourcePath videoUrl:(NSString *)videoSourcePath albumDescription:(NSString *)albumDescription {
    // 首先检查iOS版本
    if (@available(iOS 15.0, *)) {
        // iOS 15及更高版本使用原有的实现
        NSURL *photoURL = [NSURL fileURLWithPath:imageSourcePath];
        NSURL *videoURL = [NSURL fileURLWithPath:videoSourcePath];
        BOOL available = [PHAssetCreationRequest supportsAssetResourceTypes:@[ @(PHAssetResourceTypePhoto), @(PHAssetResourceTypePairedVideo) ]];
        if (!available) {
            return;
        }
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
          if (status != PHAuthorizationStatusAuthorized) {
              return;
          }
          NSString *identifier = [NSUUID UUID].UUIDString;
          [self useAssetWriter:photoURL
                         video:videoURL
                    identifier:identifier
              albumDescription:albumDescription
                      complete:^(BOOL success, NSString *photoFile, NSString *videoFile, NSError *error) {
                        NSURL *photo = [NSURL fileURLWithPath:photoFile];
                        NSURL *video = [NSURL fileURLWithPath:videoFile];
                        [[PHPhotoLibrary sharedPhotoLibrary]
                            performChanges:^{
                              PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
                              [request addResourceWithType:PHAssetResourceTypePhoto fileURL:photo options:nil];
                              [request addResourceWithType:PHAssetResourceTypePairedVideo fileURL:video options:nil];
                            }
                            completionHandler:^(BOOL success, NSError *_Nullable error) {
                              dispatch_async(dispatch_get_main_queue(), ^{
                                if (success) {
                                    // 删除临时文件
                                    [[NSFileManager defaultManager] removeItemAtPath:imageSourcePath error:nil];
                                    [[NSFileManager defaultManager] removeItemAtPath:videoSourcePath error:nil];
                                    [[NSFileManager defaultManager] removeItemAtPath:photoFile error:nil];
                                    [[NSFileManager defaultManager] removeItemAtPath:videoFile error:nil];
                                }
                              });
                            }];
                      }];
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
          [DYYYUtils showToast:@"当前iOS版本不支持实况照片，将分别保存图片和视频"];
        });
    }
}

- (void)useAssetWriter:(NSURL *)photoURL
                 video:(NSURL *)videoURL
            identifier:(NSString *)identifier
      albumDescription:(NSString *)albumDescription
              complete:(void (^)(BOOL success, NSString *photoFile, NSString *videoFile, NSError *error))complete {
    NSString *photoName = [photoURL lastPathComponent];
    NSString *photoFile = [self filePathFromTmp:photoName];
    [self addMetadataToPhoto:photoURL outputFile:photoFile identifier:identifier albumDescription:albumDescription creationDate:nil];
    NSString *videoName = [videoURL lastPathComponent];
    NSString *videoFile = [self filePathFromTmp:videoName];
    [self addMetadataToVideo:videoURL outputFile:videoFile identifier:identifier albumDescription:albumDescription];
    if (!DYYYManager.shared->group)
        return;
    dispatch_group_notify(DYYYManager.shared->group, dispatch_get_main_queue(), ^{
      [self finishWritingTracksWithPhoto:photoFile video:videoFile complete:complete];
    });
}
- (void)finishWritingTracksWithPhoto:(NSString *)photoFile video:(NSString *)videoFile complete:(void (^)(BOOL success, NSString *photoFile, NSString *videoFile, NSError *error))complete {
    [DYYYManager.shared->reader cancelReading];
    [DYYYManager.shared->writer finishWritingWithCompletionHandler:^{
      if (complete)
          complete(YES, photoFile, videoFile, nil);
    }];
}
- (void)addMetadataToPhoto:(NSURL *)photoURL outputFile:(NSString *)outputFile identifier:(NSString *)identifier albumDescription:(NSString *)albumDescription creationDate:(NSDate *)creationDate {
    NSMutableData *data = [NSData dataWithContentsOfURL:photoURL].mutableCopy;
    UIImage *image = [UIImage imageWithData:data];
    CGImageRef imageRef = image.CGImage;
    NSMutableDictionary *imageMetadata = [NSMutableDictionary dictionaryWithObject:@{@"17" : identifier} forKey:(NSString *)kCGImagePropertyMakerAppleDictionary];
    if (albumDescription.length > 0) {
        imageMetadata[(NSString *)kCGImagePropertyTIFFDictionary] = @{(NSString *)kCGImagePropertyTIFFImageDescription : albumDescription};
        imageMetadata[(NSString *)kCGImagePropertyIPTCDictionary] = @{(NSString *)kCGImagePropertyIPTCCaptionAbstract : albumDescription};
    }
    if (creationDate) {
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
        dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        dateFormatter.dateFormat = @"yyyy:MM:dd HH:mm:ss";
        NSString *dateString = [dateFormatter stringFromDate:creationDate];

        NSMutableDictionary *tiffMetadata = [imageMetadata[(NSString *)kCGImagePropertyTIFFDictionary] mutableCopy] ?: [NSMutableDictionary dictionary];
        tiffMetadata[(NSString *)kCGImagePropertyTIFFDateTime] = dateString;
        imageMetadata[(NSString *)kCGImagePropertyTIFFDictionary] = tiffMetadata;

        NSMutableDictionary *exifMetadata = [imageMetadata[(NSString *)kCGImagePropertyExifDictionary] mutableCopy] ?: [NSMutableDictionary dictionary];
        exifMetadata[(NSString *)kCGImagePropertyExifDateTimeOriginal] = dateString;
        exifMetadata[(NSString *)kCGImagePropertyExifDateTimeDigitized] = dateString;
        exifMetadata[(NSString *)kCGImagePropertyExifSubsecTimeOriginal] = @"000";
        imageMetadata[(NSString *)kCGImagePropertyExifDictionary] = exifMetadata;
    }
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((CFMutableDataRef)data, kUTTypeJPEG, 1, nil);
    CGImageDestinationAddImage(dest, imageRef, (CFDictionaryRef)imageMetadata);
    CGImageDestinationFinalize(dest);
    [data writeToFile:outputFile atomically:YES];
}

- (void)addMetadataToVideo:(NSURL *)videoURL
                outputFile:(NSString *)outputFile
                identifier:(NSString *)identifier
          albumDescription:(NSString *)albumDescription {
    NSError *error = nil;
    AVAsset *asset = [AVAsset assetWithURL:videoURL];
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (error) {
        return;
    }
    NSMutableArray<AVMetadataItem *> *metadata = asset.metadata.mutableCopy;
    AVMetadataItem *item = [self createContentIdentifierMetadataItem:identifier];
    [metadata addObject:item];
    metadata = [[DYYYManager metadataItemsByAppendingDescription:albumDescription toItems:metadata] mutableCopy];
    NSURL *videoFileURL = [NSURL fileURLWithPath:outputFile];
    [self deleteFile:outputFile];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:videoFileURL fileType:AVFileTypeQuickTimeMovie error:&error];
    if (error) {
        return;
    }
    [writer setMetadata:metadata];
    NSArray<AVAssetTrack *> *tracks = [asset tracks];
    for (AVAssetTrack *track in tracks) {
        NSDictionary *readerOutputSettings = nil;
        NSDictionary *writerOuputSettings = nil;
        if ([track.mediaType isEqualToString:AVMediaTypeAudio]) {
            readerOutputSettings = @{AVFormatIDKey : @(kAudioFormatLinearPCM)};
            writerOuputSettings = @{AVFormatIDKey : @(kAudioFormatMPEG4AAC), AVSampleRateKey : @(44100), AVNumberOfChannelsKey : @(2), AVEncoderBitRateKey : @(128000)};
        }
        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:readerOutputSettings];
        AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:track.mediaType outputSettings:writerOuputSettings];
        if ([reader canAddOutput:output] && [writer canAddInput:input]) {
            [reader addOutput:output];
            [writer addInput:input];
        }
    }
    AVAssetWriterInput *input = [self createStillImageTimeAssetWriterInput];
    AVAssetWriterInputMetadataAdaptor *adaptor = [AVAssetWriterInputMetadataAdaptor assetWriterInputMetadataAdaptorWithAssetWriterInput:input];
    if ([writer canAddInput:input]) {
        [writer addInput:input];
    }
    [writer startWriting];
    [writer startSessionAtSourceTime:kCMTimeZero];
    [reader startReading];
    AVMetadataItem *timedItem = [self createStillImageTimeMetadataItem];
    CMTimeRange timedRange = CMTimeRangeMake(kCMTimeZero, CMTimeMake(1, 100));
    AVTimedMetadataGroup *timedMetadataGroup = [[AVTimedMetadataGroup alloc] initWithItems:@[ timedItem ] timeRange:timedRange];
    [adaptor appendTimedMetadataGroup:timedMetadataGroup];
    DYYYManager.shared->reader = reader;
    DYYYManager.shared->writer = writer;
    DYYYManager.shared->queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    DYYYManager.shared->group = dispatch_group_create();
    for (NSInteger i = 0; i < reader.outputs.count; ++i) {
        dispatch_group_enter(DYYYManager.shared->group);
        [self writeTrack:i];
    }
}

- (void)writeTrack:(NSInteger)trackIndex {
    AVAssetReaderOutput *output = DYYYManager.shared->reader.outputs[trackIndex];
    AVAssetWriterInput *input = DYYYManager.shared->writer.inputs[trackIndex];

    [input requestMediaDataWhenReadyOnQueue:DYYYManager.shared->queue
                                 usingBlock:^{
                                   while (input.readyForMoreMediaData) {
                                       AVAssetReaderStatus status = DYYYManager.shared->reader.status;
                                       CMSampleBufferRef buffer = NULL;
                                       if ((status == AVAssetReaderStatusReading) && (buffer = [output copyNextSampleBuffer])) {
                                           BOOL success = [input appendSampleBuffer:buffer];
                                           CFRelease(buffer);
                                           if (!success) {
                                               [input markAsFinished];
                                               dispatch_group_leave(DYYYManager.shared->group);
                                               return;
                                           }
                                       } else {
                                           if (status == AVAssetReaderStatusReading) {
                                           } else if (status == AVAssetReaderStatusCompleted) {
                                           } else if (status == AVAssetReaderStatusCancelled) {
                                           } else if (status == AVAssetReaderStatusFailed) {
                                           }
                                           [input markAsFinished];
                                           dispatch_group_leave(DYYYManager.shared->group);
                                           return;
                                       }
                                   }
                                 }];
}
- (AVMetadataItem *)createContentIdentifierMetadataItem:(NSString *)identifier {
    AVMutableMetadataItem *item = [AVMutableMetadataItem metadataItem];
    item.keySpace = AVMetadataKeySpaceQuickTimeMetadata;
    item.key = AVMetadataQuickTimeMetadataKeyContentIdentifier;
    item.value = identifier;
    return item;
}

- (AVAssetWriterInput *)createStillImageTimeAssetWriterInput {
    NSArray *spec = @[ @{
        (NSString *)kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier : @"mdta/com.apple.quicktime.still-image-time",
        (NSString *)kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType : (NSString *)kCMMetadataBaseDataType_SInt8
    } ];
    CMFormatDescriptionRef desc = NULL;
    CMMetadataFormatDescriptionCreateWithMetadataSpecifications(kCFAllocatorDefault, kCMMetadataFormatType_Boxed, (__bridge CFArrayRef)spec, &desc);
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeMetadata outputSettings:nil sourceFormatHint:desc];
    return input;
}

- (AVMetadataItem *)createStillImageTimeMetadataItem {
    AVMutableMetadataItem *item = [AVMutableMetadataItem metadataItem];
    item.keySpace = AVMetadataKeySpaceQuickTimeMetadata;
    item.key = @"com.apple.quicktime.still-image-time";
    item.value = @(-1);
    item.dataType = (NSString *)kCMMetadataBaseDataType_SInt8;
    return item;
}
- (NSString *)filePathFromTmp:(NSString *)filename {
    NSString *tempPath = NSTemporaryDirectory();
    NSString *filePath = [tempPath stringByAppendingPathComponent:filename];
    return filePath;
}

- (void)deleteFile:(NSString *)file {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:file]) {
        [fm removeItemAtPath:file error:nil];
    }
}

#pragma mark - 评论区图片保存

+ (void)saveCommentImages:(NSArray *)imageModels
             currentIndex:(NSInteger)currentIndex
               completion:(void (^)(NSInteger successCount, NSInteger livePhotoCount, NSInteger failedCount))completion {
    if (!imageModels || imageModels.count == 0) {
        if (completion) completion(0, 0, 0);
        return;
    }

    // 确定要保存的图片
    NSArray *imagesToSave = nil;
    if (currentIndex >= 0 && currentIndex < (NSInteger)imageModels.count) {
        imagesToSave = @[imageModels[currentIndex]];
    } else {
        imagesToSave = imageModels;
    }

    // 分离普通图片和实况照片
    NSMutableArray *normalImages = [NSMutableArray array];
    NSMutableArray *livePhotos = [NSMutableArray array];

    for (id imageModel in imagesToSave) {
        @try {
            // 获取图片 URL - originUrl 和 mediumUrl 都是 AWEURLModel 类型
            NSString *imageUrlStr = nil;

            // 首先尝试 originUrl
            AWEURLModel *originUrlModel = [imageModel valueForKey:@"originUrl"];
            if (originUrlModel) {
                NSArray *urlList = [originUrlModel originURLList];
                if (urlList && urlList.count > 0) {
                    imageUrlStr = urlList.firstObject;
                }
            }

            // 如果 originUrl 没有获取到，尝试 mediumUrl
            if (!imageUrlStr) {
                AWEURLModel *mediumUrlModel = [imageModel valueForKey:@"mediumUrl"];
                if (mediumUrlModel) {
                    NSArray *urlList = [mediumUrlModel originURLList];
                    if (urlList && urlList.count > 0) {
                        imageUrlStr = urlList.firstObject;
                    }
                }
            }

            NSLog(@"[DYYY] 评论图片URL: %@", imageUrlStr);

            if (!imageUrlStr || imageUrlStr.length == 0) {
                NSLog(@"[DYYY] 无法获取图片URL，imageModel: %@", imageModel);
                continue;
            }

            // 检查是否是实况照片
            id livePhotoModel = [imageModel valueForKey:@"livePhotoModel"];
            if (livePhotoModel) {
                NSArray *videoUrls = [livePhotoModel valueForKey:@"videoUrl"];
                if (videoUrls && videoUrls.count > 0) {
                    NSString *videoUrlStr = videoUrls.firstObject;
                    if (videoUrlStr && videoUrlStr.length > 0) {
                        // 传入字符串而不是 NSURL，与 downloadAllLivePhotosWithProgress 期望的格式一致
                        [livePhotos addObject:@{
                            @"imageURL": imageUrlStr,
                            @"videoURL": videoUrlStr
                        }];
                        continue;
                    }
                }
            }

            // 普通图片 - 存储字符串而不是 NSURL
            [normalImages addObject:imageUrlStr];
        } @catch (NSException *e) {
            NSLog(@"[DYYY] 解析评论图片失败: %@", e);
        }
    }

    NSLog(@"[DYYY] 解析完成: 普通图片=%lu, 实况照片=%lu", (unsigned long)normalImages.count, (unsigned long)livePhotos.count);

    // 如果都没有解析到有效URL，直接返回失败
    if (normalImages.count == 0 && livePhotos.count == 0) {
        if (completion) completion(0, 0, (NSInteger)imagesToSave.count);
        return;
    }

    __block NSInteger successCount = 0;
    __block NSInteger livePhotoCount = 0;
    __block NSInteger failedCount = 0;

    dispatch_group_t group = dispatch_group_create();

    // 保存普通图片
    if (normalImages.count > 0) {
        dispatch_group_enter(group);
        [self downloadAllImagesWithProgress:[normalImages mutableCopy]
                                   progress:nil
                                 completion:^(NSInteger imgSuccess, NSInteger imgTotal) {
            successCount += imgSuccess;
            failedCount += (imgTotal - imgSuccess);
            dispatch_group_leave(group);
        }];
    }

    // 保存实况照片
    if (livePhotos.count > 0) {
        dispatch_group_enter(group);
        [self downloadAllLivePhotosWithProgress:livePhotos
                                       progress:nil
                                     completion:^(NSInteger lpSuccess, NSInteger lpTotal) {
            successCount += lpSuccess;
            livePhotoCount = lpSuccess;
            failedCount += (lpTotal - lpSuccess);
            dispatch_group_leave(group);
        }];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (completion) {
            completion(successCount, livePhotoCount, failedCount);
        }
    });
}

+ (void)downloadAllLivePhotos:(NSArray<NSDictionary *> *)livePhotos {
    if (livePhotos.count == 0) {
        return;
    }

    [self downloadAllLivePhotosWithProgress:livePhotos
                                   progress:nil
                                 completion:^(NSInteger successCount, NSInteger totalCount){
                                 }];
}
+ (void)downloadAllLivePhotosWithProgress:(NSArray<NSDictionary *> *)livePhotos
                                 progress:(void (^)(NSInteger current, NSInteger total))progressBlock
                               completion:(void (^)(NSInteger successCount, NSInteger totalCount))completion {
    [self downloadAllLivePhotosWithProgress:livePhotos albumDescription:nil progress:progressBlock completion:completion];
}

+ (void)downloadAllLivePhotosWithProgress:(NSArray<NSDictionary *> *)livePhotos albumDescription:(NSString *)albumDescription progress:(void (^)(NSInteger current, NSInteger total))progressBlock completion:(void (^)(NSInteger successCount, NSInteger totalCount))completion {
    [self downloadAllLivePhotosWithProgress:livePhotos albumDescription:albumDescription scopedCancellation:NO progress:progressBlock completion:completion];
}

+ (void)downloadAllLivePhotosWithProgress:(NSArray<NSDictionary *> *)livePhotos albumDescription:(NSString *)albumDescription scopedCancellation:(BOOL)scopedCancellation progress:(void (^)(NSInteger current, NSInteger total))progressBlock completion:(void (^)(NSInteger successCount, NSInteger totalCount))completion {
    livePhotos = [livePhotos copy];
    if (livePhotos.count == 0) {
        if (completion) {
            completion(0, 0);
        }
        return;
    }

    albumDescription = [albumDescription copy];

    // 检查iOS版本是否支持实况照片
    BOOL supportsLivePhoto = NO;
    if (@available(iOS 15.0, *)) {
        supportsLivePhoto = YES;
    }

    if (!supportsLivePhoto) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [DYYYUtils showToast:@"当前iOS版本不支持实况照片"];
          if (completion) {
              completion(0, livePhotos.count);
          }
        });
        return;
    }

    NSUInteger generation = [self downloadCancellationGeneration];
    // 创建进度显示UI
    DYYYDownloadOnMain(^{
      if (generation != [self downloadCancellationGeneration]) { if (completion) completion(0, livePhotos.count); return; }
      CGRect screenBounds = [UIScreen mainScreen].bounds;
      DYYYToast *progressView = [[DYYYToast alloc] initWithFrame:screenBounds];
      [progressView show];
      DYYYManager *manager = [DYYYManager shared];
      NSString *batchID = NSUUID.UUID.UUIDString;
      NSMutableDictionary *state = DYYYDownloadCreateState();
      manager.downloadStates[batchID] = state;
      manager.progressViews[batchID] = progressView;
      void (^finish)(NSInteger, NSInteger) = ^(NSInteger successCount, NSInteger totalCount) {
          DYYYDownloadOnMain(^{
              BOOL active = DYYYDownloadStateIsActive(state);
              if (!DYYYDownloadFinishState(state)) return;
              progressView.allowSuccessAnimation = active && successCount > 0 && successCount == totalCount;
              [progressView dismiss];

              [manager.downloadStates removeObjectForKey:batchID];
              [manager.progressViews removeObjectForKey:batchID];
              if (completion) completion(active ? successCount : 0, totalCount);
          });
      };

      progressView.cancelBlock = ^{
        if (scopedCancellation) [manager cancelDownloadWithID:batchID]; else [self cancelAllDownloads];
      };

      NSMutableArray<NSDictionary *> *downloadedFiles = [NSMutableArray arrayWithCapacity:livePhotos.count];
      for (int i = 0; i < livePhotos.count; i++) {
          NSDictionary *pair = [livePhotos[i] isKindOfClass:[NSDictionary class]] ? livePhotos[i] : @{};
          NSString *image = [pair[@"imageURL"] isKindOfClass:[NSString class]] ? pair[@"imageURL"] : @"";
          NSString *video = [pair[@"videoURL"] isKindOfClass:[NSString class]] ? pair[@"videoURL"] : @"";
          [downloadedFiles addObject:@{@"imageURL":image, @"videoURL":video, @"imagePath":NSNull.null, @"videoPath":NSNull.null}];
      }

      // 进度计算 - 为三个阶段分配权重
      NSInteger totalSteps = livePhotos.count * 10;  // 每个实况照片总共10步(4+4+2)
      __block NSInteger completedSteps = 0;

      // 创建临时目录
      NSString *livePhotoPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"LivePhotoBatch"] stringByAppendingPathComponent:batchID];
      NSFileManager *fileManager = [NSFileManager defaultManager];
      [fileManager createDirectoryAtPath:livePhotoPath withIntermediateDirectories:YES attributes:nil error:nil];

      // 更新进度的block
      void (^updateProgress)(NSString *) = ^(NSString *statusText) {
        NSInteger current = 0;
        @synchronized (state) { current = completedSteps; }
        float progress = (float)current / totalSteps;

        dispatch_async(dispatch_get_main_queue(), ^{
          if (!DYYYDownloadStateIsActive(state)) return;
          [progressView setProgress:progress];
          if (progressBlock) {
              progressBlock(current, totalSteps);
          }
        });
      };

      // 下载完成后的处理
      void (^finishProcess)(void) = ^{
        if (!DYYYDownloadStateIsActive(state)) {
            [fileManager removeItemAtPath:livePhotoPath error:nil];
            finish(0, livePhotos.count);
            return;
        }
        __block NSInteger successCount = 0;

        // 请求相册权限
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
          if (status == PHAuthorizationStatusAuthorized && DYYYDownloadStateIsActive(state)) {
              dispatch_queue_t processQueue = dispatch_queue_create("com.dyyy.livephoto.process", DISPATCH_QUEUE_SERIAL);
              dispatch_group_t saveGroup = dispatch_group_create();

              NSInteger validFileCount = 0;
              for (NSDictionary *fileInfo in downloadedFiles) {
                  NSString *imagePath = fileInfo[@"imagePath"];
                  NSString *videoPath = fileInfo[@"videoPath"];

                  if (![imagePath isKindOfClass:[NSNull class]] && ![videoPath isKindOfClass:[NSNull class]] && [fileManager fileExistsAtPath:imagePath] && [fileManager fileExistsAtPath:videoPath]) {
                      validFileCount++;
                  }
              }

              if (validFileCount == 0) {
                  dispatch_async(dispatch_get_main_queue(), ^{
                    progressView.allowSuccessAnimation = NO;

                    [fileManager removeItemAtPath:livePhotoPath error:nil];
                    finish(0, livePhotos.count);
                  });
                  return;
              }

              __block NSInteger processedCount = 0;
              NSDate *batchCreationDate = [NSDate date];
              NSTimeInterval creationDateOffset = 0;

              for (NSDictionary *fileInfo in downloadedFiles) {
                  NSString *imagePath = fileInfo[@"imagePath"];
                  NSString *videoPath = fileInfo[@"videoPath"];

                  if (![imagePath isKindOfClass:[NSNull class]] && ![videoPath isKindOfClass:[NSNull class]] && [fileManager fileExistsAtPath:imagePath] && [fileManager fileExistsAtPath:videoPath]) {
                      // iOS 相册对间隔小于4秒的实况照片仍可能连续播放，因此按4秒递增。
                      NSDate *assetCreationDate = [batchCreationDate dateByAddingTimeInterval:creationDateOffset];
                      creationDateOffset += 4.0;
                      dispatch_group_enter(saveGroup);

                      dispatch_async(processQueue, ^{
                        if (!DYYYDownloadStateIsActive(state)) { dispatch_group_leave(saveGroup); return; }
                        // 生成唯一标识符
                        NSString *identifier = [NSUUID UUID].UUIDString;

                        // 创建每个任务的专属实例变量，避免共享变量冲突
                        AVAssetReader *localReader = nil;
                        AVAssetWriter *localWriter = nil;
                        dispatch_queue_t localQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
                        dispatch_group_t localGroup = dispatch_group_create();

                        // 处理照片和元数据
                        NSString *photoName = [imagePath lastPathComponent];
                        NSString *photoFile = [[DYYYManager shared] filePathFromTmp:photoName];
                        [[DYYYManager shared] addMetadataToPhoto:[NSURL fileURLWithPath:imagePath] outputFile:photoFile identifier:identifier albumDescription:albumDescription creationDate:assetCreationDate];

                        // 处理视频和元数据
                        NSString *videoName = [videoPath lastPathComponent];
                        NSString *videoFile = [[DYYYManager shared] filePathFromTmp:videoName];

                        NSString *metadataPhotoFile = photoFile;
                        NSString *metadataVideoFile = videoFile;

                        // 使用本地变量而非全局共享变量
                        [[DYYYManager shared] addMetadataToVideoWithLocalVars:[NSURL fileURLWithPath:videoPath]
                                                                   outputFile:videoFile
                                                                   identifier:identifier
                                                             albumDescription:albumDescription
                                                                 creationDate:assetCreationDate
                                                                       reader:&localReader
                                                                       writer:&localWriter
                                                                        queue:localQueue
                                                                        group:localGroup
                                                                     complete:^(BOOL success, NSString *photoFile, NSString *videoFile, NSError *error) {
                                                                       if (success && DYYYDownloadStateIsActive(state)) {
                                                                           NSURL *photo = [NSURL fileURLWithPath:photoFile];
                                                                           NSURL *video = [NSURL fileURLWithPath:videoFile];

                                                                           [[PHPhotoLibrary sharedPhotoLibrary]
                                                                               performChanges:^{
                                                                                 DYYYDownloadPerformIfActive(state, ^{
                                                                                     PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
                                                                                     request.creationDate = assetCreationDate;
                                                                                     [request addResourceWithType:PHAssetResourceTypePhoto fileURL:photo options:nil];
                                                                                     [request addResourceWithType:PHAssetResourceTypePairedVideo fileURL:video options:nil];
                                                                                 });
                                                                               }
                                                                               completionHandler:^(BOOL success, NSError *_Nullable error) {
                                                                                 if (success && DYYYDownloadStateIsActive(state)) {
                                                                                     @synchronized (state) { successCount++; }
                                                                                 }

                                                                                 NSArray *filesToDelete = @[ imagePath, videoPath, metadataPhotoFile, metadataVideoFile ];
                                                                                 for (NSString *path in filesToDelete) {
                                                                                     [fileManager removeItemAtPath:path error:nil];
                                                                                 }

                                                                                 // 增加进度步数
                                                                                 @synchronized (state) { processedCount++; completedSteps += 2; }  // 每完成一个合成任务增加2步
                                                                                 updateProgress([NSString stringWithFormat:@"已合成 %ld/%ld", (long)processedCount, (long)validFileCount]);

                                                                                 dispatch_group_leave(saveGroup);
                                                                               }];
                                                                       } else {
                                                                           [fileManager removeItemAtPath:imagePath error:nil];
                                                                           [fileManager removeItemAtPath:videoPath error:nil];
                                                                           [fileManager removeItemAtPath:metadataPhotoFile error:nil];
                                                                           [fileManager removeItemAtPath:metadataVideoFile error:nil];

                                                                           // 增加进度步数（即使失败也增加）
                                                                           @synchronized (state) { processedCount++; completedSteps += 2; }
                                                                           updateProgress([NSString stringWithFormat:@"已合成 %ld/%ld", (long)processedCount, (long)validFileCount]);

                                                                           dispatch_group_leave(saveGroup);
                                                                       }
                                                                     }];
                      });
                  }
              }

              dispatch_group_notify(saveGroup, dispatch_get_main_queue(), ^{
                progressView.allowSuccessAnimation = DYYYDownloadStateIsActive(state) && (successCount > 0 && successCount == validFileCount);


                [fileManager removeItemAtPath:livePhotoPath error:nil];

                finish(successCount, livePhotos.count);
              });
          } else {
              // 没有相册权限
              dispatch_async(dispatch_get_main_queue(), ^{
                progressView.allowSuccessAnimation = NO;

                if (DYYYDownloadStateIsActive(state)) [DYYYUtils showToast:@"没有相册权限，无法保存实况照片"];

                [fileManager removeItemAtPath:livePhotoPath error:nil];

                finish(0, livePhotos.count);
              });
          }
        }];
      };

      // 第一阶段：批量下载所有图片
      dispatch_group_t imageDownloadGroup = dispatch_group_create();
      updateProgress(@"正在下载图片...");

      for (NSInteger i = 0; i < livePhotos.count; i++) {
          NSDictionary *livePhoto = downloadedFiles[i];
          NSString *imageURLString = livePhoto[@"imageURL"];
          NSURL *imageURL = [NSURL URLWithString:imageURLString];

          if (!imageURL) {
              completedSteps += 4;  // 图片下载占4步
              continue;
          }

          dispatch_group_enter(imageDownloadGroup);

          // 创建文件路径
          NSString *uniqueID = [NSUUID UUID].UUIDString;
          NSString *imagePath = [livePhotoPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.heic", uniqueID]];

          // 配置下载会话
          NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
          configuration.timeoutIntervalForRequest = 60.0;
          NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:nil delegateQueue:[NSOperationQueue mainQueue]];

          NSString *taskID = NSUUID.UUID.UUIDString;
          NSURLSessionDataTask *imageTask = [session dataTaskWithURL:imageURL
                                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                                     if (!error && data && DYYYDownloadStateIsActive(state)) {
                                                         if ([data writeToFile:imagePath atomically:YES]) {
                                                             NSMutableDictionary *updatedInfo = [downloadedFiles[i] mutableCopy];
                                                             updatedInfo[@"imagePath"] = imagePath;
                                                             downloadedFiles[i] = updatedInfo;
                                                         }
                                                     }

                                                     [manager.downloadTasks removeObjectForKey:taskID];
                                                     [manager.downloadOwnerMap removeObjectForKey:taskID];
                                                     [session finishTasksAndInvalidate];
                                                     completedSteps += 4;  // 图片下载占4步
                                                     updateProgress([NSString stringWithFormat:@"已下载图片 %ld/%ld", (long)(i + 1), (long)livePhotos.count]);
                                                     dispatch_group_leave(imageDownloadGroup);
                                                   }];

          manager.downloadOwnerMap[taskID] = batchID;
          manager.downloadTasks[taskID] = imageTask;
          [imageTask resume];
      }

      // 所有图片下载完成后，开始下载视频
      dispatch_group_notify(imageDownloadGroup, dispatch_get_main_queue(), ^{
        if (!DYYYDownloadStateIsActive(state)) { [fileManager removeItemAtPath:livePhotoPath error:nil]; finish(0, livePhotos.count); return; }
        updateProgress(@"正在下载视频...");

        dispatch_group_t videoDownloadGroup = dispatch_group_create();

        for (NSInteger i = 0; i < livePhotos.count; i++) {
            NSDictionary *fileInfo = downloadedFiles[i];

            // 只处理图片下载成功的项
            if ([fileInfo[@"imagePath"] isKindOfClass:[NSNull class]]) {
                completedSteps += 4;  // 视频下载占4步
                continue;
            }

            NSString *videoURLString = fileInfo[@"videoURL"];
            NSURL *videoURL = [NSURL URLWithString:videoURLString];

            if (!videoURL) {
                completedSteps += 4;  // 视频下载占4步
                continue;
            }

            dispatch_group_enter(videoDownloadGroup);

            // 使用与图片相同的ID但不同的扩展名
            NSString *imagePath = fileInfo[@"imagePath"];
            NSString *baseName = [[imagePath lastPathComponent] stringByDeletingPathExtension];
            NSString *videoPath = [livePhotoPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.mp4", baseName]];

            // 配置下载会话
            NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
            configuration.timeoutIntervalForRequest = 60.0;
            NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:nil delegateQueue:[NSOperationQueue mainQueue]];

            NSString *taskID = NSUUID.UUID.UUIDString;
            NSURLSessionDataTask *videoTask = [session dataTaskWithURL:videoURL
                                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                                       if (!error && data && DYYYDownloadStateIsActive(state)) {
                                                           if ([data writeToFile:videoPath atomically:YES]) {
                                                               NSMutableDictionary *updatedInfo = [downloadedFiles[i] mutableCopy];
                                                               updatedInfo[@"videoPath"] = videoPath;
                                                               downloadedFiles[i] = updatedInfo;
                                                           }
                                                       }

                                                       [manager.downloadTasks removeObjectForKey:taskID];
                                                     [manager.downloadOwnerMap removeObjectForKey:taskID];
                                                     [session finishTasksAndInvalidate];
                                                     completedSteps += 4;  // 视频下载占4步
                                                       updateProgress([NSString stringWithFormat:@"已下载视频 %ld/%ld", (long)(i + 1), (long)livePhotos.count]);
                                                       dispatch_group_leave(videoDownloadGroup);
                                                     }];

            manager.downloadOwnerMap[taskID] = batchID;
            manager.downloadTasks[taskID] = videoTask;
            [videoTask resume];
        }

        // 所有视频下载完成后，开始合成实况照片
        dispatch_group_notify(videoDownloadGroup, dispatch_get_main_queue(), ^{
          if (!DYYYDownloadStateIsActive(state)) { [fileManager removeItemAtPath:livePhotoPath error:nil]; finish(0, livePhotos.count); return; }
          finishProcess();
        });
      });
    });
}

// 使用本地变量处理视频
- (void)addMetadataToVideoWithLocalVars:(NSURL *)videoURL
                             outputFile:(NSString *)outputFile
                             identifier:(NSString *)identifier
                       albumDescription:(NSString *)albumDescription
                           creationDate:(NSDate *)creationDate
                                 reader:(AVAssetReader **)readerPtr
                                 writer:(AVAssetWriter **)writerPtr
                                  queue:(dispatch_queue_t)queue
                                  group:(dispatch_group_t)group
                               complete:(void (^)(BOOL success, NSString *photoFile, NSString *videoFile, NSError *error))complete {
    NSError *error = nil;
    AVAsset *asset = [AVAsset assetWithURL:videoURL];
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
    if (error) {
        if (complete)
            complete(NO, nil, nil, error);
        return;
    }

    *readerPtr = reader;

    NSMutableArray<AVMetadataItem *> *metadata = asset.metadata.mutableCopy;
    AVMetadataItem *item = [self createContentIdentifierMetadataItem:identifier];
    [metadata addObject:item];
    metadata = [[DYYYManager metadataItemsBySettingCreationDate:creationDate toItems:metadata] mutableCopy];
    metadata = [[DYYYManager metadataItemsByAppendingDescription:albumDescription toItems:metadata] mutableCopy];
    NSURL *videoFileURL = [NSURL fileURLWithPath:outputFile];
    [self deleteFile:outputFile];

    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:videoFileURL fileType:AVFileTypeQuickTimeMovie error:&error];
    if (error) {
        if (complete)
            complete(NO, nil, nil, error);
        return;
    }

    *writerPtr = writer;
    [writer setMetadata:metadata];

    NSArray<AVAssetTrack *> *tracks = [asset tracks];
    for (AVAssetTrack *track in tracks) {
        NSDictionary *readerOutputSettings = nil;
        NSDictionary *writerOuputSettings = nil;
        if ([track.mediaType isEqualToString:AVMediaTypeAudio]) {
            readerOutputSettings = @{AVFormatIDKey : @(kAudioFormatLinearPCM)};
            writerOuputSettings = @{AVFormatIDKey : @(kAudioFormatMPEG4AAC), AVSampleRateKey : @(44100), AVNumberOfChannelsKey : @(2), AVEncoderBitRateKey : @(128000)};
        }

        AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:readerOutputSettings];
        AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:track.mediaType outputSettings:writerOuputSettings];

        if ([reader canAddOutput:output] && [writer canAddInput:input]) {
            [reader addOutput:output];
            [writer addInput:input];
        }
    }

    AVAssetWriterInput *input = [self createStillImageTimeAssetWriterInput];
    AVAssetWriterInputMetadataAdaptor *adaptor = [AVAssetWriterInputMetadataAdaptor assetWriterInputMetadataAdaptorWithAssetWriterInput:input];
    if ([writer canAddInput:input]) {
        [writer addInput:input];
    }

    [writer startWriting];
    [writer startSessionAtSourceTime:kCMTimeZero];
    [reader startReading];

    AVMetadataItem *timedItem = [self createStillImageTimeMetadataItem];
    CMTimeRange timedRange = CMTimeRangeMake(kCMTimeZero, CMTimeMake(1, 100));
    AVTimedMetadataGroup *timedMetadataGroup = [[AVTimedMetadataGroup alloc] initWithItems:@[ timedItem ] timeRange:timedRange];
    [adaptor appendTimedMetadataGroup:timedMetadataGroup];

    for (NSInteger i = 0; i < reader.outputs.count; ++i) {
        dispatch_group_enter(group);
        [self writeTrackWithLocalVars:i reader:reader writer:writer queue:queue group:group];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
      [reader cancelReading];
      [writer finishWritingWithCompletionHandler:^{
        AVAssetWriterStatus status = writer.status;
        if (status == AVAssetWriterStatusCompleted) {
            NSString *photoName = [[videoURL lastPathComponent] stringByDeletingPathExtension];
            NSString *photoFile = [self filePathFromTmp:[photoName stringByAppendingPathExtension:@"heic"]];
            if (complete)
                complete(YES, photoFile, outputFile, nil);
        } else {
            if (complete)
                complete(NO, nil, nil, writer.error);
        }
      }];
    });
}

// 处理视频曲目的写入
- (void)writeTrackWithLocalVars:(NSInteger)trackIndex reader:(AVAssetReader *)reader writer:(AVAssetWriter *)writer queue:(dispatch_queue_t)queue group:(dispatch_group_t)group {
    AVAssetReaderOutput *output = reader.outputs[trackIndex];
    AVAssetWriterInput *input = writer.inputs[trackIndex];

    [input requestMediaDataWhenReadyOnQueue:queue
                                 usingBlock:^{
                                   while (input.readyForMoreMediaData) {
                                       AVAssetReaderStatus status = reader.status;
                                       CMSampleBufferRef buffer = NULL;
                                       if ((status == AVAssetReaderStatusReading) && (buffer = [output copyNextSampleBuffer])) {
                                           BOOL success = [input appendSampleBuffer:buffer];
                                           CFRelease(buffer);
                                           if (!success) {
                                               [input markAsFinished];
                                               dispatch_group_leave(group);
                                               return;
                                           }
                                       } else {
                                           [input markAsFinished];
                                           dispatch_group_leave(group);
                                           return;
                                       }
                                   }
                                 }];
}

+ (void)parseAndDownloadVideoWithShareLink:(NSString *)shareLink apiKey:(NSString *)apiKey {
    [self parseAndDownloadVideoWithShareLink:shareLink apiKey:apiKey albumDescription:nil];
}

+ (void)parseAndDownloadVideoWithShareLink:(NSString *)shareLink apiKey:(NSString *)apiKey albumDescription:(NSString *)albumDescription {
    albumDescription = [albumDescription copy];
    if (shareLink.length == 0 || apiKey.length == 0) {
        [DYYYUtils showToast:@"分享链接或API密钥无效"];
        return;
    }

    NSString *apiUrl = [NSString stringWithFormat:@"%@%@", apiKey, [shareLink stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

    NSURL *url = [NSURL URLWithString:apiUrl];
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    NSURLSession *session = [NSURLSession sharedSession];

    NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request
                                                completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                                  dispatch_async(dispatch_get_main_queue(), ^{
                                                    if (error) {
                                                        [DYYYUtils showToast:[NSString stringWithFormat:@"接口请求失败: %@", error.localizedDescription]];
                                                        return;
                                                    }

                                                    NSError *jsonError;
                                                    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                                                    if (jsonError) {
                                                        [DYYYUtils showToast:@"解析接口返回数据失败"];
                                                        return;
                                                    }

                                                    NSInteger code = [json[@"code"] integerValue];
                                                    if (code != 0 && code != 200) {
                                                        [DYYYUtils showToast:[NSString stringWithFormat:@"接口返回错误: %@", json[@"msg"] ?: @"未知错误"]];
                                                        return;
                                                    }

                                                    NSDictionary *dataDict = json[@"data"];
                                                    if (!dataDict) {
                                                        [DYYYUtils showToast:@"接口返回数据为空"];
                                                        return;
                                                    }

                                                    // 交给handleVideoData处理数据
                                                    [self handleVideoData:dataDict albumDescription:albumDescription];
                                                  });
                                                }];

    [dataTask resume];
}

+ (void)saveGalleryImages:(NSArray<NSString *> *)imageURLs livePhotos:(NSArray<NSDictionary *> *)livePhotos albumDescription:(NSString *)albumDescription {
    BOOL hasImages = imageURLs.count > 0;
    BOOL hasLivePhotos = livePhotos.count > 0;

    if (!hasImages && !hasLivePhotos) {
        return;
    }

    if (!hasLivePhotos) {
        [self downloadAllImagesWithProgress:[imageURLs mutableCopy] albumDescription:albumDescription progress:nil completion:nil];
        return;
    }

    if (!hasImages) {
        [self downloadAllLivePhotosWithProgress:livePhotos albumDescription:albumDescription progress:nil completion:nil];
        return;
    }

    // 两类都有时先跑静图、完成后再跑实况。两批各自会起一个进度浮层，同时展示会叠在一起，
    // 这里等前一批的收起动画走完再启动后一批。
    NSUInteger generation = [self downloadCancellationGeneration];
    [self downloadAllImagesWithProgress:[imageURLs mutableCopy]
                       albumDescription:albumDescription
                               progress:nil
                             completion:^(NSInteger successCount, NSInteger totalCount) {
                               if (generation != [self downloadCancellationGeneration]) return;
                               dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                 if (generation != [self downloadCancellationGeneration]) return;
                                 [self downloadAllLivePhotosWithProgress:livePhotos albumDescription:albumDescription progress:nil completion:nil];
                               });
                             }];
}

+ (void)batchDownloadResources:(NSArray *)videos images:(NSArray *)images {
    [self downloadParsedVideos:videos images:images albumDescription:nil];
}

+ (void)downloadParsedVideos:(NSArray *)videos images:(NSArray *)images albumDescription:(NSString *)albumDescription {
    for (id value in videos) {
        NSString *url = [value isKindOfClass:NSString.class] ? value : ([value isKindOfClass:NSDictionary.class] ? value[@"url"] : nil);
        if (url.length) [self downloadMedia:[NSURL URLWithString:url] mediaType:MediaTypeVideo audio:nil albumDescription:albumDescription completion:nil];
    }
    if (images.count) [self downloadAllImagesWithProgress:[images mutableCopy] albumDescription:albumDescription progress:nil completion:nil];
}

+ (void)handleVideoData:(NSDictionary *)dataDict albumDescription:(NSString *)albumDescription {
    // 首先检查videos和images数组
    NSArray *videoList = dataDict[@"video_list"];
    NSArray *videos = dataDict[@"videos"];
    NSArray *images = dataDict[@"images"];
    NSArray *imgArray = dataDict[@"img"];

    // 获取封面URL
    NSString *coverURL = nil;
    if (dataDict[@"cover"] && [dataDict[@"cover"] length] > 0) {
        coverURL = dataDict[@"cover"];
    } else if (dataDict[@"pics"] && [dataDict[@"pics"] length] > 0) {
        coverURL = dataDict[@"pics"];
    }

    // 尝试获取音乐URL（供后续下载视频时合并音频使用）
    NSString *musicURL = nil;
    if (dataDict[@"music"] && [dataDict[@"music"] length] > 0) {
        musicURL = dataDict[@"music"];
    } else if (dataDict[@"music_url"] && [dataDict[@"music_url"] length] > 0) {
        musicURL = dataDict[@"music_url"];
    }

    // 检查是否有视频列表(优先处理)
    BOOL hasVideoList = [videoList isKindOfClass:[NSArray class]] && videoList.count > 0;
    if (hasVideoList) {
        // 图集帖的 video_list 里混着图片直链、实况 mp4 和画质行，按行 URL 落在哪个数组里判定类型：
        //   命中 images[]/img[]  -> 图片，落盘 .jpg
        //   命中 live_videos[]   -> 与同下标 images[i] 配对，存成 iOS 原生实况照片
        //   都不命中             -> 画质行，或服务端自定义的信息行，按视频处理
        // 判定依据是下标而不是 level 文案：文案是服务端可配的模板，下标才是结构。
        NSArray *rowImages = [dataDict[@"images"] isKindOfClass:[NSArray class]] ? dataDict[@"images"] : @[];
        NSArray *rowImgArray = [dataDict[@"img"] isKindOfClass:[NSArray class]] ? dataDict[@"img"] : @[];
        NSArray *rowLiveVideos = [dataDict[@"live_videos"] isKindOfClass:[NSArray class]] ? dataDict[@"live_videos"] : @[];

        // 一个下标同时给出静图行和实况行时只保留实况行：两行是同一张的两种形态，
        // 静图行留着会让人以为选它也能得到实况。先扫一遍记下出现过实况行的下标。
        NSMutableIndexSet *liveRowIndexes = [NSMutableIndexSet indexSet];
        for (NSDictionary *videoDict in videoList) {
            if (![videoDict isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSString *url = videoDict[@"url"];
            if (![url isKindOfClass:[NSString class]] || url.length == 0) {
                continue;
            }
            NSUInteger liveIndex = [rowLiveVideos indexOfObject:url];
            if (liveIndex != NSNotFound) {
                [liveRowIndexes addIndex:liveIndex];
            }
        }

        NSMutableArray<DYYYMediaChooserItem *> *items = [NSMutableArray array];

        for (NSDictionary *videoDict in videoList) {
            if (![videoDict isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            NSString *url = videoDict[@"url"];
            NSString *level = videoDict[@"level"];
            if (![url isKindOfClass:[NSString class]] || ![level isKindOfClass:[NSString class]]) {
                continue;
            }
            if (url.length == 0 || level.length == 0) {
                continue;
            }

            NSUInteger liveIndex = [rowLiveVideos indexOfObject:url];
            NSUInteger imageIndex = [rowImages indexOfObject:url];
            BOOL isLiveRow = (liveIndex != NSNotFound);
            BOOL isImageRow = (imageIndex != NSNotFound) || ([rowImgArray indexOfObject:url] != NSNotFound);

            if (!isLiveRow && imageIndex != NSNotFound && [liveRowIndexes containsIndex:imageIndex]) {
                continue;
            }

            NSString *pairedImageURL = nil;
            if (isLiveRow && liveIndex < rowImages.count) {
                NSString *candidate = rowImages[liveIndex];
                if ([candidate isKindOfClass:[NSString class]] && candidate.length > 0) {
                    pairedImageURL = candidate;
                }
            }

            MediaType rowMediaType = isImageRow ? MediaTypeImage : MediaTypeVideo;
            BOOL allowAudioMerge = (!isLiveRow && !isImageRow);

            DYYYMediaChooserItem *item = [DYYYMediaChooserItem
                itemWithTitle:level
                      handler:^{
                        if (pairedImageURL.length > 0) {
                            [self downloadLivePhoto:[NSURL URLWithString:pairedImageURL] videoURL:[NSURL URLWithString:url] albumDescription:albumDescription completion:nil];
                            return;
                        }

                        // 配不到静图的实况行退化成存 mp4；图片行存 .jpg；画质行与改动前一致
                        NSURL *optionalAudioURL = (allowAudioMerge && musicURL.length > 0) ? [NSURL URLWithString:musicURL] : nil;
                        [self downloadMedia:[NSURL URLWithString:url] mediaType:rowMediaType audio:optionalAudioURL albumDescription:albumDescription completion:nil];
                      }];
            [items addObject:item];
        }

        // 「保存全部」按帖子的实际构成走：纯静图存图片，纯实况存实况，混合则每张各存自己的形态。
        NSMutableArray<NSString *> *staticImages = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *livePhotoPairs = [NSMutableArray array];
        for (NSUInteger i = 0; i < rowImages.count; i++) {
            NSString *imageURLString = rowImages[i];
            if (![imageURLString isKindOfClass:[NSString class]] || imageURLString.length == 0) {
                continue;
            }
            NSString *liveURLString = (i < rowLiveVideos.count) ? rowLiveVideos[i] : nil;
            if ([liveURLString isKindOfClass:[NSString class]] && liveURLString.length > 0) {
                [livePhotoPairs addObject:@{@"imageURL" : imageURLString, @"videoURL" : liveURLString}];
            } else {
                [staticImages addObject:imageURLString];
            }
        }

        if (staticImages.count + livePhotoPairs.count > 1) {
            NSString *saveAllTitle = @"保存全部图片";
            if (staticImages.count == 0) {
                saveAllTitle = @"保存全部实况";
            } else if (livePhotoPairs.count > 0) {
                saveAllTitle = @"保存全部图片和实况";
            }

            DYYYMediaChooserItem *saveAllItem = [DYYYMediaChooserItem itemWithTitle:saveAllTitle
                                                                           handler:^{
                                                                             [self saveGalleryImages:staticImages livePhotos:livePhotoPairs albumDescription:albumDescription];
                                                                           }];
            [items addObject:saveAllItem];
        }

        if (items.count > 0) {
            [DYYYMediaChooserSheet showWithItems:items];
            return;
        }
    }

    // 尝试获取视频URL
    NSString *singleVideoURL = nil;
    if (dataDict[@"url"] && [dataDict[@"url"] length] > 0) {
        singleVideoURL = dataDict[@"url"];
    } else if (dataDict[@"video"] && [dataDict[@"video"] length] > 0) {
        singleVideoURL = dataDict[@"video"];
    } else if (dataDict[@"video_url"] && [dataDict[@"video_url"] length] > 0) {
        singleVideoURL = dataDict[@"video_url"];
    }

    // 确保处理空的videos数组
    BOOL hasVideos = [videos isKindOfClass:[NSArray class]] && videos.count > 0;
    BOOL hasImages = [images isKindOfClass:[NSArray class]] && images.count > 0;
    BOOL hasImgArray = [imgArray isKindOfClass:[NSArray class]] && imgArray.count > 0;

    BOOL shouldShowQualityOptions = [[NSUserDefaults standardUserDefaults] boolForKey:@"DYYYShowAllVideoQuality"];

    // 如果只有图片没有视频，直接处理图片下载
    if (!hasVideos && singleVideoURL == nil && (hasImages || hasImgArray || coverURL != nil)) {
        NSMutableArray *allImages = [NSMutableArray array];
        if (hasImages)
            [allImages addObjectsFromArray:images];
        if (hasImgArray)
            [allImages addObjectsFromArray:imgArray];
        if (coverURL && coverURL.length > 0 && ![allImages containsObject:coverURL]) {
            [allImages addObject:coverURL];
        }

        if (allImages.count > 0) {
            if (allImages.count == 1) {
                // 单张图片直接下载
                NSURL *imageDownloadUrl = [NSURL URLWithString:allImages[0]];
                [self downloadMedia:imageDownloadUrl
                          mediaType:MediaTypeImage
                              audio:nil albumDescription:albumDescription
                         completion:^(BOOL success) {
                           if (!success) {
                               [DYYYUtils showToast:@"图片下载失败"];
                           }
                         }];
            } else {
                // 多张图片批量下载
                [self downloadAllImagesWithProgress:allImages albumDescription:albumDescription progress:nil completion:nil];
            }
            return;
        }
    }

    // 单个视频情况下的处理
    if (shouldShowQualityOptions && singleVideoURL && singleVideoURL.length > 0) {
        NSMutableArray<DYYYMediaChooserItem *> *items = [NSMutableArray array];

        DYYYMediaChooserItem *videoItem = [DYYYMediaChooserItem
            itemWithTitle:@"下载视频"
                  handler:^{
                    NSURL *optionalAudioURL = (musicURL.length > 0) ? [NSURL URLWithString:musicURL] : nil;
                    [self downloadMedia:[NSURL URLWithString:singleVideoURL] mediaType:MediaTypeVideo audio:optionalAudioURL albumDescription:albumDescription completion:nil];
                  }];
        [items addObject:videoItem];

        if (coverURL && coverURL.length > 0) {
            DYYYMediaChooserItem *coverItem = [DYYYMediaChooserItem itemWithTitle:@"下载封面图"
                                                                         handler:^{
                                                                           [self downloadMedia:[NSURL URLWithString:coverURL] mediaType:MediaTypeImage audio:nil albumDescription:albumDescription completion:nil];
                                                                         }];
            [items addObject:coverItem];
        }

        if (musicURL && musicURL.length > 0) {
            DYYYMediaChooserItem *musicItem = [DYYYMediaChooserItem itemWithTitle:@"下载背景音乐"
                                                                         handler:^{
                                                                           [self downloadMedia:[NSURL URLWithString:musicURL] mediaType:MediaTypeAudio audio:nil albumDescription:albumDescription completion:nil];
                                                                         }];
            [items addObject:musicItem];
        }

        // 添加批量下载选项
        NSMutableArray *allImages = [NSMutableArray array];
        if (hasImages)
            [allImages addObjectsFromArray:images];
        if (hasImgArray)
            [allImages addObjectsFromArray:imgArray];
        if (coverURL && coverURL.length > 0 && ![allImages containsObject:coverURL]) {
            [allImages addObject:coverURL];
        }

        if (allImages.count > 0 || singleVideoURL.length > 0) {
            DYYYMediaChooserItem *batchItem = [DYYYMediaChooserItem
                itemWithTitle:@"批量下载所有资源"
                      handler:^{
                        NSMutableArray *singleVideoArray = nil;
                        if (singleVideoURL.length > 0) {
                            singleVideoArray = [NSMutableArray arrayWithObject:@{@"url" : singleVideoURL}];
                        }
                        [self downloadParsedVideos:singleVideoArray images:allImages albumDescription:albumDescription];
                      }];
            [items addObject:batchItem];
        }

        if (items.count > 0) {
            [DYYYMediaChooserSheet showWithItems:items];
            return;
        }
    }

    if (!shouldShowQualityOptions && singleVideoURL && singleVideoURL.length > 0) {
        NSURL *videoDownloadUrl = [NSURL URLWithString:singleVideoURL];
        NSURL *optionalAudioURL = nil;
        if (musicURL.length > 0) {
            optionalAudioURL = [NSURL URLWithString:musicURL];
        }
        [self downloadMedia:videoDownloadUrl
                  mediaType:MediaTypeVideo
                      audio:optionalAudioURL albumDescription:albumDescription
                 completion:^(BOOL success) {
                   if (!success) {
                   }
                 }];
        return;
    }

    // 如果前面的条件都不满足，尝试批量下载所有资源
    NSMutableArray *allImages = [NSMutableArray array];
    if (hasImages)
        [allImages addObjectsFromArray:images];
    if (hasImgArray)
        [allImages addObjectsFromArray:imgArray];
    if (coverURL && coverURL.length > 0 && ![allImages containsObject:coverURL]) {
        [allImages addObject:coverURL];
    }

    if (allImages.count > 0 || hasVideos) {
        [self downloadParsedVideos:videos images:allImages albumDescription:albumDescription];
    } else {
        [DYYYUtils showToast:@"没有找到可下载的资源"];
    }
}

#define DYYYLogVideo(format, ...) NSLog((@"[DYYY视频合成] " format), ##__VA_ARGS__)
// 创建视频合成器从多种媒体源
+ (void)createVideoFromMedia:(NSArray<NSString *> *)imageURLs
                  livePhotos:(NSArray<NSDictionary *> *)livePhotos
                      bgmURL:(NSString *)bgmURL
                    progress:(void (^)(NSInteger current, NSInteger total, NSString *status))progressBlock
                  completion:(void (^)(BOOL success, NSString *message))completion {
    DYYYLogVideo(@"开始创建视频 - 图片数量: %lu, 实况照片数量: %lu, 背景音乐: %@", (unsigned long)imageURLs.count, (unsigned long)livePhotos.count, bgmURL.length > 0 ? @"有" : @"无");

    if ((imageURLs.count == 0 && livePhotos.count == 0) || (imageURLs == nil && livePhotos == nil)) {
        DYYYLogVideo(@"错误: 没有提供媒体资源");
        if (completion) {
            completion(NO, @"没有提供媒体资源");
        }
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      CGRect screenBounds = [UIScreen mainScreen].bounds;
      DYYYToast *progressView = [[DYYYToast alloc] initWithFrame:screenBounds];
      [progressView show];

      progressView.cancelBlock = ^{
        DYYYLogVideo(@"用户取消了视频合成");
        [self cancelAllDownloads];
        if (completion) {
            completion(NO, @"用户取消了操作");
        }
      };

      // 创建临时目录
      NSString *mediaPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"VideoComposition"];
      NSFileManager *fileManager = [NSFileManager defaultManager];
      if ([fileManager fileExistsAtPath:mediaPath]) {
          DYYYLogVideo(@"正在清理旧的临时目录: %@", mediaPath);
          [fileManager removeItemAtPath:mediaPath error:nil];
      }

      NSError *dirError = nil;
      [fileManager createDirectoryAtPath:mediaPath withIntermediateDirectories:YES attributes:nil error:&dirError];
      if (dirError) {
          DYYYLogVideo(@"创建临时目录失败: %@", dirError);
          if (completion) {
              completion(NO, @"创建临时文件夹失败");
          }
          return;
      }
      DYYYLogVideo(@"成功创建临时目录: %@", mediaPath);

      // 计算总共需要下载的文件数和合成步骤
      NSInteger totalImages = imageURLs.count;
      NSInteger totalLivePhotos = livePhotos.count * 2;  // 每个实况照片有2个文件
      NSInteger hasBGM = (bgmURL.length > 0) ? 1 : 0;

      // 总步骤：下载所有媒体 + 合成视频 + 保存视频
      NSInteger totalSteps = totalImages + totalLivePhotos + hasBGM + 2;
      __block NSInteger completedSteps = 0;

      // 储存下载的媒体文件路径
      NSMutableArray *imageFilePaths = [NSMutableArray array];
      NSMutableArray<NSDictionary *> *livePhotoFilePaths = [NSMutableArray array];
      __block NSString *bgmFilePath = nil;

      void (^updateProgress)(NSString *) = ^(NSString *status) {
        float progress = (float)completedSteps / totalSteps;
        dispatch_async(dispatch_get_main_queue(), ^{
          [progressView setProgress:progress];
          DYYYLogVideo(@"进度更新: %.2f%% - %@", progress * 100, status);
          if (progressBlock) {
              progressBlock(completedSteps, totalSteps, status);
          }
        });
      };

      // 第一阶段：下载所有普通图片
      dispatch_group_t imageDownloadGroup = dispatch_group_create();
      updateProgress(@"正在下载图片...");

      for (NSInteger i = 0; i < imageURLs.count; i++) {
          NSString *imageURLString = imageURLs[i];
          NSURL *imageURL = [NSURL URLWithString:imageURLString];

          if (!imageURL) {
              DYYYLogVideo(@"图片URL无效: %@", imageURLString);
              completedSteps++;
              updateProgress(@"图片URL无效");
              continue;
          }

          dispatch_group_enter(imageDownloadGroup);

          // 创建文件路径
          NSString *uniqueID = [NSUUID UUID].UUIDString;
          NSString *imagePath = [mediaPath stringByAppendingPathComponent:[NSString stringWithFormat:@"image_%@.jpg", uniqueID]];
          DYYYLogVideo(@"开始下载图片 %ld/%ld: %@", (long)(i + 1), (long)imageURLs.count, imageURLString);

          // 配置下载会话
          NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
          NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];

          NSURLSessionDataTask *imageTask = [session dataTaskWithURL:imageURL
                                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                                     if (error) {
                                                         DYYYLogVideo(@"下载图片失败 %ld/%ld: %@", (long)(i + 1), (long)imageURLs.count, error);
                                                     } else if (!data) {
                                                         DYYYLogVideo(@"下载图片数据为空 %ld/%ld", (long)(i + 1), (long)imageURLs.count);
                                                     } else {
                                                         NSInteger dataSize = data.length;
                                                         if ([data writeToFile:imagePath atomically:YES]) {
                                                             DYYYLogVideo(@"成功下载并保存图片 %ld/%ld: %@ (大小: %.2f KB)", (long)(i + 1), (long)imageURLs.count, imagePath, dataSize / 1024.0);
                                                             [imageFilePaths addObject:imagePath];
                                                         } else {
                                                             DYYYLogVideo(@"保存图片文件失败 %ld/%ld: %@", (long)(i + 1), (long)imageURLs.count, imagePath);
                                                         }
                                                     }

                                                     completedSteps++;
                                                     updateProgress([NSString stringWithFormat:@"已下载图片 %ld/%ld", (long)(i + 1), (long)imageURLs.count]);
                                                     dispatch_group_leave(imageDownloadGroup);
                                                   }];

          [imageTask resume];
      }

      // 第二阶段：下载所有实况照片
      dispatch_group_t livePhotoDownloadGroup = dispatch_group_create();

      dispatch_group_notify(imageDownloadGroup, dispatch_get_main_queue(), ^{
        DYYYLogVideo(@"第一阶段完成，已下载 %ld 张图片", (long)imageFilePaths.count);
        updateProgress(@"正在下载实况照片...");
        DYYYLogVideo(@"开始第二阶段: 下载实况照片 (%ld 项)", (long)livePhotos.count);

        for (NSInteger i = 0; i < livePhotos.count; i++) {
            NSDictionary *livePhoto = livePhotos[i];
            NSString *imageURLString = livePhoto[@"imageURL"];
            NSString *videoURLString = livePhoto[@"videoURL"];
            NSURL *imageURL = [NSURL URLWithString:imageURLString];
            NSURL *videoURL = [NSURL URLWithString:videoURLString];

            if (!imageURL || !videoURL) {
                DYYYLogVideo(@"实况照片URL无效: 图片=%@, 视频=%@", imageURLString, videoURLString);
                completedSteps += 2;
                updateProgress(@"实况照片URL无效");
                continue;
            }

            NSString *uniqueID = [NSUUID UUID].UUIDString;
            NSString *imagePath = [mediaPath stringByAppendingPathComponent:[NSString stringWithFormat:@"livephoto_img_%@.jpg", uniqueID]];
            NSString *videoPath = [mediaPath stringByAppendingPathComponent:[NSString stringWithFormat:@"livephoto_vid_%@.mp4", uniqueID]];

            // 下载图片部分
            dispatch_group_enter(livePhotoDownloadGroup);
            NSURLSessionConfiguration *imgConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
            NSURLSession *imgSession = [NSURLSession sessionWithConfiguration:imgConfig];

            DYYYLogVideo(@"开始下载实况照片图片部分 %ld/%ld: %@", (long)(i + 1), (long)livePhotos.count, imageURLString);
            NSURLSessionDataTask *imageTask =
                [imgSession dataTaskWithURL:imageURL
                          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                            if (error) {
                                DYYYLogVideo(@"下载实况照片图片部分失败 %ld/%ld: %@", (long)(i + 1), (long)livePhotos.count, error);
                            } else if (!data) {
                                DYYYLogVideo(@"下载实况照片图片数据为空 %ld/%ld", (long)(i + 1), (long)livePhotos.count);
                            } else if ([data writeToFile:imagePath atomically:YES]) {
                                DYYYLogVideo(@"成功保存实况照片图片部分 %ld/%ld: %@ (大小: %.2f KB)", (long)(i + 1), (long)livePhotos.count, imagePath, data.length / 1024.0);
                            } else {
                                DYYYLogVideo(@"保存实况照片图片文件失败 %ld/%ld: %@", (long)(i + 1), (long)livePhotos.count, imagePath);
                            }

                            completedSteps++;
                            updateProgress([NSString stringWithFormat:@"已下载实况照片(图片) %ld/%ld", (long)(i + 1), (long)livePhotos.count]);
                            dispatch_group_leave(livePhotoDownloadGroup);
                          }];

            // 下载视频部分
            dispatch_group_enter(livePhotoDownloadGroup);
            NSURLSessionConfiguration *vidConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
            NSURLSession *vidSession = [NSURLSession sessionWithConfiguration:vidConfig];

            DYYYLogVideo(@"开始下载实况照片视频部分 %ld/%ld: %@", (long)(i + 1), (long)livePhotos.count, videoURLString);
            NSURLSessionDataTask *videoTask =
                [vidSession dataTaskWithURL:videoURL
                          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                            if (error) {
                                DYYYLogVideo(@"下载实况照片视频部分失败 %ld/%ld: %@", (long)(i + 1), (long)livePhotos.count, error);
                            } else if (!data) {
                                DYYYLogVideo(@"下载实况照片视频数据为空 %ld/%ld", (long)(i + 1), (long)livePhotos.count);
                            } else if ([data writeToFile:videoPath atomically:YES]) {
                                DYYYLogVideo(@"成功保存实况照片视频部分 %ld/%ld: %@ (大小: %.2f MB)", (long)(i + 1), (long)livePhotos.count, videoPath, data.length / (1024.0 * 1024.0));
                                @synchronized(livePhotoFilePaths) {
                                    [livePhotoFilePaths addObject:@{@"image" : imagePath, @"video" : videoPath}];
                                    DYYYLogVideo(@"成功记录实况照片对: 图片=%@, 视频=%@", imagePath, videoPath);
                                }
                            } else {
                                DYYYLogVideo(@"保存实况照片视频文件失败 %ld/%ld: %@", (long)(i + 1), (long)livePhotos.count, videoPath);
                            }

                            completedSteps++;
                            updateProgress([NSString stringWithFormat:@"已下载实况照片(视频) %ld/%ld", (long)(i + 1), (long)livePhotos.count]);
                            dispatch_group_leave(livePhotoDownloadGroup);
                          }];

            [imageTask resume];
            [videoTask resume];
        }

        // 第三阶段：下载背景音乐
        dispatch_group_t bgmDownloadGroup = dispatch_group_create();

        dispatch_group_notify(livePhotoDownloadGroup, dispatch_get_main_queue(), ^{
          DYYYLogVideo(@"第二阶段完成，已下载 %ld 组实况照片", (long)livePhotoFilePaths.count);

          if (bgmURL.length > 0) {
              DYYYLogVideo(@"开始第三阶段: 下载背景音乐 %@", bgmURL);
              updateProgress(@"正在下载背景音乐...");
              NSURL *bgmURL_obj = [NSURL URLWithString:bgmURL];

              if (!bgmURL_obj) {
                  DYYYLogVideo(@"背景音乐URL无效: %@", bgmURL);
                  completedSteps++;
                  updateProgress(@"背景音乐URL无效");
              } else {
                  dispatch_group_enter(bgmDownloadGroup);

                  // 创建文件路径
                  NSString *uniqueID = [NSUUID UUID].UUIDString;
                  NSString *audioPath = [mediaPath stringByAppendingPathComponent:[NSString stringWithFormat:@"bgm_%@.mp3", uniqueID]];

                  // 配置下载会话
                  NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
                  NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];

                  NSURLSessionDataTask *audioTask = [session dataTaskWithURL:bgmURL_obj
                                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                                             if (error) {
                                                                 DYYYLogVideo(@"下载背景音乐失败: %@", error);
                                                             } else if (!data) {
                                                                 DYYYLogVideo(@"下载背景音乐数据为空");
                                                             } else if ([data writeToFile:audioPath atomically:YES]) {
                                                                 DYYYLogVideo(@"成功保存背景音乐: %@ (大小: %.2f MB)", audioPath, data.length / (1024.0 * 1024.0));
                                                                 bgmFilePath = audioPath;
                                                             } else {
                                                                 DYYYLogVideo(@"保存背景音乐文件失败: %@", audioPath);
                                                             }

                                                             completedSteps++;
                                                             updateProgress(@"背景音乐下载完成");
                                                             dispatch_group_leave(bgmDownloadGroup);
                                                           }];

                  [audioTask resume];
              }
          }

          // 第四阶段：合成视频
          dispatch_group_notify(bgmDownloadGroup, dispatch_get_main_queue(), ^{
            DYYYLogVideo(@"第三阶段完成，背景音乐状态: %@", bgmFilePath ? @"已下载" : @"无或下载失败");
            DYYYLogVideo(@"开始第四阶段: 合成视频");
            updateProgress(@"正在合成视频...");

            // 如果没有成功下载任何媒体，则退出
            if (imageFilePaths.count == 0 && livePhotoFilePaths.count == 0) {
                DYYYLogVideo(@"错误: 没有成功下载任何媒体文件，取消合成");
                progressView.allowSuccessAnimation = NO;
                [progressView dismiss];
                if (completion) {
                    completion(NO, @"没有成功下载任何媒体文件");
                }
                [fileManager removeItemAtPath:mediaPath error:nil];
                return;
            }

            DYYYLogVideo(@"媒体文件统计: %ld张图片, %ld组实况照片, 背景音乐: %@", (long)imageFilePaths.count, (long)livePhotoFilePaths.count, bgmFilePath ? @"有" : @"无");

            NSString *outputPath = [mediaPath stringByAppendingPathComponent:[NSString stringWithFormat:@"final_%@.mp4", [NSUUID UUID].UUIDString]];
            DYYYLogVideo(@"视频输出路径: %@", outputPath);

            // 使用AVFoundation合成视频
            [self composeVideo:imageFilePaths
                    livePhotos:livePhotoFilePaths
                       bgmPath:bgmFilePath
                    outputPath:outputPath
                    completion:^(BOOL success) {
                      completedSteps++;
                      if (success) {
                          DYYYLogVideo(@"视频合成成功");
                      } else {
                          DYYYLogVideo(@"视频合成失败");
                      }
                      updateProgress(@"视频合成完成");

                      if (success) {
                          DYYYLogVideo(@"开始保存视频到相册");
                          [[PHPhotoLibrary sharedPhotoLibrary]
                              performChanges:^{
                                [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:outputPath]];
                              }
                              completionHandler:^(BOOL success, NSError *_Nullable error) {
                                completedSteps++;

                                dispatch_async(dispatch_get_main_queue(), ^{
                                  progressView.allowSuccessAnimation = success;
                                  [progressView dismiss];

                                  if (success) {
                                      DYYYLogVideo(@"视频已成功保存到相册");
                                      if (completion) {
                                          completion(YES, @"视频已成功保存到相册");
                                      }
                                  } else {
                                      DYYYLogVideo(@"保存视频到相册失败: %@", error);
                                      if (completion) {
                                          completion(NO, [NSString stringWithFormat:@"保存视频到相册失败: %@", error.localizedDescription]);
                                      }
                                  }

                                  DYYYLogVideo(@"清理临时文件: %@", mediaPath);
                                  [fileManager removeItemAtPath:mediaPath error:nil];
                                });
                              }];
                      } else {
                          dispatch_async(dispatch_get_main_queue(), ^{
                            progressView.allowSuccessAnimation = NO;
                            [progressView dismiss];
                            if (completion) {
                                completion(NO, @"视频合成失败");
                            }

                            DYYYLogVideo(@"清理临时文件: %@", mediaPath);
                            [fileManager removeItemAtPath:mediaPath error:nil];
                          });
                      }
                    }];
          });
        });
      });
    });
}

// 视频合成核心方法
+ (void)composeVideo:(NSArray<NSString *> *)imageFiles
          livePhotos:(NSArray<NSDictionary *> *)livePhotoFiles
             bgmPath:(NSString *)bgmPath
          outputPath:(NSString *)outputPath
          completion:(void (^)(BOOL success))completion {
    // 视频尺寸（标准1080p）
    CGSize videoSize = CGSizeMake(1080, 1920);
    DYYYLogVideo(@"开始合成视频 - 目标尺寸: %.0fx%.0f", videoSize.width, videoSize.height);
    DYYYLogVideo(@"媒体源: %ld张图片, %ld组实况照片, 背景音乐: %@", (long)imageFiles.count, (long)livePhotoFiles.count, bgmPath ? @"有" : @"无");

    dispatch_group_t processingGroup = dispatch_group_create();

    // 存储所有媒体片段信息
    NSMutableArray *mediaSegments = [NSMutableArray array];

    // 处理静态图片 - 先将所有图片转换为临时视频片段
    for (NSInteger i = 0; i < imageFiles.count; i++) {
        NSString *imagePath = imageFiles[i];
        if (![[NSFileManager defaultManager] fileExistsAtPath:imagePath]) {
            DYYYLogVideo(@"错误: 图片文件不存在: %@", imagePath);
            continue;
        }

        UIImage *image = [UIImage imageWithContentsOfFile:imagePath];
        if (!image) {
            DYYYLogVideo(@"错误: 无法加载图片: %@", imagePath);
            continue;
        }
        DYYYLogVideo(@"处理图片 %ld/%ld: 尺寸 %.0fx%.0f", (long)(i + 1), (long)imageFiles.count, image.size.width, image.size.height);

        // 创建临时视频文件路径
        NSString *tempVideoPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"temp_img_%@.mp4", [NSUUID UUID].UUIDString]];

        dispatch_group_enter(processingGroup);

        // 使用Core Animation创建静态图片视频
        [self createVideoFromImage:image
                          duration:5.0
                        outputPath:tempVideoPath
                        completion:^(BOOL success) {
                          if (success) {
                              @synchronized(mediaSegments) {
                                  [mediaSegments addObject:@{@"type" : @"image", @"path" : tempVideoPath, @"duration" : @5.0}];
                                  DYYYLogVideo(@"成功创建图片视频片段 %ld/%ld: %@", (long)(i + 1), (long)imageFiles.count, tempVideoPath);
                              }
                          } else {
                              DYYYLogVideo(@"错误: 创建图片视频片段失败 %ld/%ld", (long)(i + 1), (long)imageFiles.count);
                          }
                          dispatch_group_leave(processingGroup);
                        }];
    }

    // 处理实况照片 - 收集所有视频路径信息
    for (NSInteger i = 0; i < livePhotoFiles.count; i++) {
        NSDictionary *livePhoto = livePhotoFiles[i];
        NSString *imagePath = livePhoto[@"image"];
        NSString *videoPath = livePhoto[@"video"];

        DYYYLogVideo(@"处理实况照片 %ld/%ld: 图片=%@, 视频=%@", (long)(i + 1), (long)livePhotoFiles.count, imagePath, videoPath);

        if (![[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
            DYYYLogVideo(@"错误: 实况照片视频不存在: %@", videoPath);
            continue;
        }

        [mediaSegments addObject:@{@"type" : @"video", @"path" : videoPath}];
        DYYYLogVideo(@"成功添加实况照片视频片段 %ld/%ld", (long)(i + 1), (long)livePhotoFiles.count);
    }

    // 等待所有临时视频处理完成
    dispatch_group_notify(processingGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      DYYYLogVideo(@"所有媒体处理完成，共有 %ld 个可用片段", (long)mediaSegments.count);

      if (mediaSegments.count == 0) {
          DYYYLogVideo(@"错误: 没有有效的媒体片段可以合成");
          if (completion) {
              dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
              });
          }
          return;
      }

      // 创建AVMutableComposition作为容器
      DYYYLogVideo(@"开始创建视频合成容器");
      AVMutableComposition *composition = [AVMutableComposition composition];
      AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
      videoComposition.frameDuration = CMTimeMake(1, 30);  // 30fps
      videoComposition.renderSize = videoSize;

      // 创建视频轨道
      AVMutableCompositionTrack *videoTrack = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
      if (!videoTrack) {
          DYYYLogVideo(@"错误: 无法创建视频轨道");
          if (completion) {
              dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
              });
          }
          return;
      }

      // 创建音频轨道
      AVMutableCompositionTrack *audioTrack = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
      if (!audioTrack) {
          DYYYLogVideo(@"错误: 无法创建音频轨道");
          if (completion) {
              dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
              });
          }
          return;
      }

      // 添加背景音乐
      __block CMTime currentTime = kCMTimeZero;
      if (bgmPath && [[NSFileManager defaultManager] fileExistsAtPath:bgmPath]) {
          DYYYLogVideo(@"添加背景音乐: %@", bgmPath);
          AVAsset *audioAsset = [AVAsset assetWithURL:[NSURL fileURLWithPath:bgmPath]];
          AVAssetTrack *audioAssetTrack = [[audioAsset tracksWithMediaType:AVMediaTypeAudio] firstObject];

          if (audioAssetTrack) {
              // 先处理所有视频片段以确定总时长
              CMTime totalDuration = kCMTimeZero;
              for (NSDictionary *segment in mediaSegments) {
                  NSString *segmentPath = segment[@"path"];
                  AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:segmentPath]];
                  totalDuration = CMTimeAdd(totalDuration, asset.duration);
              }

              // 循环播放背景音乐直到覆盖整个视频时长
              CMTime audioDuration = audioAsset.duration;
              CMTime currentAudioTime = kCMTimeZero;

              if (CMTimeCompare(audioDuration, totalDuration) < 0) {
                  DYYYLogVideo(@"背景音乐时长(%.2f秒)小于视频时长(%.2f秒)，将循环播放", CMTimeGetSeconds(audioDuration), CMTimeGetSeconds(totalDuration));

                  while (CMTimeCompare(currentAudioTime, totalDuration) < 0) {
                      // 确定当前片段的时长（如果到达视频末尾则截断）
                      CMTime remainingTime = CMTimeSubtract(totalDuration, currentAudioTime);
                      CMTime segmentDuration = audioDuration;

                      if (CMTimeCompare(remainingTime, audioDuration) < 0) {
                          segmentDuration = remainingTime;
                      }

                      // 插入音频片段
                      NSError *audioError = nil;
                      [audioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, segmentDuration) ofTrack:audioAssetTrack atTime:currentAudioTime error:&audioError];

                      if (audioError) {
                          DYYYLogVideo(@"添加背景音乐循环片段失败: %@", audioError);
                          break;
                      }

                      DYYYLogVideo(@"添加背景音乐循环片段 - 位置: %.2f秒, 时长: %.2f秒", CMTimeGetSeconds(currentAudioTime), CMTimeGetSeconds(segmentDuration));

                      // 更新当前音频时间点
                      currentAudioTime = CMTimeAdd(currentAudioTime, segmentDuration);
                  }

                  DYYYLogVideo(@"成功添加循环背景音乐，总时长: %.2f秒", CMTimeGetSeconds(currentAudioTime));
              } else {
                  // 音乐长度足够，直接添加
                  NSError *audioError = nil;
                  [audioTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, totalDuration) ofTrack:audioAssetTrack atTime:kCMTimeZero error:&audioError];

                  if (audioError) {
                      DYYYLogVideo(@"添加背景音乐失败: %@", audioError);
                  } else {
                      DYYYLogVideo(@"成功添加背景音乐，时长: %.2f秒", CMTimeGetSeconds(totalDuration));
                  }
              }
          } else {
              DYYYLogVideo(@"错误: 背景音乐没有有效的音轨");
          }
      }

      NSMutableArray *instructions = [NSMutableArray array];

      // 处理所有媒体片段（按顺序）
      DYYYLogVideo(@"开始按顺序处理 %ld 个媒体片段", (long)mediaSegments.count);
      for (NSInteger i = 0; i < mediaSegments.count; i++) {
          NSDictionary *segment = mediaSegments[i];
          NSString *segmentType = segment[@"type"];
          NSString *segmentPath = segment[@"path"];

          DYYYLogVideo(@"处理片段 %ld/%ld: 类型=%@, 路径=%@", (long)(i + 1), (long)mediaSegments.count, segmentType, segmentPath);

          AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:segmentPath]];
          NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];

          if (videoTracks.count == 0) {
              DYYYLogVideo(@"错误: 媒体片段没有视频轨道: %@", segmentPath);
              continue;
          }

          AVAssetTrack *assetVideoTrack = videoTracks.firstObject;
          CMTime assetDuration = asset.duration;
          DYYYLogVideo(@"片段 %ld/%ld: 时长=%.2f秒, 尺寸=%.0fx%.0f", (long)(i + 1), (long)mediaSegments.count, CMTimeGetSeconds(assetDuration), assetVideoTrack.naturalSize.width,
                       assetVideoTrack.naturalSize.height);

          // 插入视频片段
          NSError *insertError = nil;
          [videoTrack insertTimeRange:CMTimeRangeMake(kCMTimeZero, assetDuration) ofTrack:assetVideoTrack atTime:currentTime error:&insertError];

          if (insertError) {
              DYYYLogVideo(@"插入视频片段失败: %@", insertError);
              continue;
          } else {
              DYYYLogVideo(@"成功插入视频片段 %ld/%ld 到位置 %.2f秒", (long)(i + 1), (long)mediaSegments.count, CMTimeGetSeconds(currentTime));
          }

          // 创建视频合成指令
          AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
          instruction.timeRange = CMTimeRangeMake(currentTime, assetDuration);

          AVMutableVideoCompositionLayerInstruction *layerInstruction = [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:videoTrack];

          // 计算适当的视频变换
          CGAffineTransform transform = [DYYYUtils transformForAssetTrack:assetVideoTrack targetSize:videoSize];
          [layerInstruction setTransform:transform atTime:currentTime];

          instruction.layerInstructions = @[ layerInstruction ];
          [instructions addObject:instruction];
          DYYYLogVideo(@"添加合成指令: 时间范围=%.2f到%.2f秒", CMTimeGetSeconds(currentTime), CMTimeGetSeconds(CMTimeAdd(currentTime, assetDuration)));

          // 更新时间点
          currentTime = CMTimeAdd(currentTime, assetDuration);
      }

      // 设置合成指令
      videoComposition.instructions = instructions;
      DYYYLogVideo(@"设置了 %ld 个视频合成指令，总时长: %.2f秒", (long)instructions.count, CMTimeGetSeconds(currentTime));

      // 检查是否有内容需要导出
      if (instructions.count == 0 || CMTimeGetSeconds(currentTime) < 0.1) {
          DYYYLogVideo(@"错误: 没有足够的内容可以导出");
          if (completion) {
              dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
              });
          }

          for (NSDictionary *segment in mediaSegments) {
              if ([segment[@"type"] isEqualToString:@"image"]) {
                  [[NSFileManager defaultManager] removeItemAtPath:segment[@"path"] error:nil];
                  DYYYLogVideo(@"清理临时图片视频文件: %@", segment[@"path"]);
              }
          }
          return;
      }

      // 设置导出会话
      DYYYLogVideo(@"创建视频导出会话，使用最高质量编码");
      AVAssetExportSession *exportSession = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetHighestQuality];
      if (!exportSession) {
          DYYYLogVideo(@"错误: 创建导出会话失败");
          if (completion) {
              dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO);
              });
          }
          return;
      }

      exportSession.videoComposition = videoComposition;
      exportSession.outputURL = [NSURL fileURLWithPath:outputPath];
      exportSession.outputFileType = AVFileTypeMPEG4;
      exportSession.shouldOptimizeForNetworkUse = YES;

      // 导出视频
      DYYYLogVideo(@"开始导出视频到: %@", outputPath);
      [exportSession exportAsynchronouslyWithCompletionHandler:^{
        for (NSDictionary *segment in mediaSegments) {
            if ([segment[@"type"] isEqualToString:@"image"]) {
                NSError *removeError = nil;
                [[NSFileManager defaultManager] removeItemAtPath:segment[@"path"] error:&removeError];
                if (removeError) {
                    DYYYLogVideo(@"清理临时文件失败: %@, 错误: %@", segment[@"path"], removeError);
                } else {
                    DYYYLogVideo(@"清理临时图片视频文件: %@", segment[@"path"]);
                }
            }
        }
        switch (exportSession.status) {
            case AVAssetExportSessionStatusCompleted: {
                DYYYLogVideo(@"视频导出成功: %@", outputPath);

                NSDictionary *fileAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outputPath error:nil];
                if (fileAttrs) {
                    unsigned long long fileSize = [fileAttrs fileSize];
                    DYYYLogVideo(@"导出视频大小: %.2f MB", fileSize / (1024.0 * 1024.0));
                }

                if (completion) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                      completion(YES);
                    });
                }
                break;
            }

            case AVAssetExportSessionStatusFailed: {
                DYYYLogVideo(@"导出视频失败: %@", exportSession.error);
                if (completion) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                      completion(NO);
                    });
                }
                break;
            }

            case AVAssetExportSessionStatusCancelled: {
                DYYYLogVideo(@"导出视频被取消");
                if (completion) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                      completion(NO);
                    });
                }
                break;
            }

            default: {
                DYYYLogVideo(@"导出视频结束，状态码: %ld", (long)exportSession.status);
                if (completion) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                      completion(NO);
                    });
                }
                break;
            }
        }
      }];
    });
}

// 创建从静态图片生成的视频片段
+ (void)createVideoFromImage:(UIImage *)image duration:(float)duration outputPath:(NSString *)outputPath completion:(void (^)(BOOL success))completion {
    // 视频尺寸和参数
    CGSize videoSize = CGSizeMake(1080, 1920);
    NSInteger frameRate = 30;

    NSError *error = nil;
    // 设置视频写入器
    AVAssetWriter *videoWriter = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:outputPath] fileType:AVFileTypeMPEG4 error:&error];
    if (error) {
        NSLog(@"创建视频写入器失败: %@", error);
        if (completion)
            completion(NO);
        return;
    }

    // 配置视频设置
    NSDictionary *videoSettings = @{
        AVVideoCodecKey : AVVideoCodecTypeH264,
        AVVideoWidthKey : @(videoSize.width),
        AVVideoHeightKey : @(videoSize.height),
        AVVideoCompressionPropertiesKey : @{AVVideoAverageBitRateKey : @(6000000), AVVideoProfileLevelKey : AVVideoProfileLevelH264HighAutoLevel}
    };

    AVAssetWriterInput *writerInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    writerInput.expectsMediaDataInRealTime = YES;

    // 创建像素缓冲区适配器
    NSDictionary *sourcePixelBufferAttributes = @{
        (NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32ARGB),
        (NSString *)kCVPixelBufferWidthKey : @(videoSize.width),
        (NSString *)kCVPixelBufferHeightKey : @(videoSize.height)
    };

    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:writerInput
                                                                                                                     sourcePixelBufferAttributes:sourcePixelBufferAttributes];

    [videoWriter addInput:writerInput];
    [videoWriter startWriting];
    [videoWriter startSessionAtSourceTime:kCMTimeZero];

    // 不再统一缩放图片，只在需要时适配

    // 创建上下文并绘制图像
    CVPixelBufferRef pixelBuffer = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &pixelBuffer);

    if (pixelBuffer == NULL) {
        // 如果池创建失败，手动创建像素缓冲区
        NSDictionary *pixelBufferAttributes = @{
            (NSString *)kCVPixelBufferCGImageCompatibilityKey : @YES,
            (NSString *)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
            (NSString *)kCVPixelBufferWidthKey : @(videoSize.width),
            (NSString *)kCVPixelBufferHeightKey : @(videoSize.height)
        };
        CVPixelBufferCreate(kCFAllocatorDefault, videoSize.width, videoSize.height, kCVPixelFormatType_32ARGB, (__bridge CFDictionaryRef)pixelBufferAttributes, &pixelBuffer);
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    void *pxdata = CVPixelBufferGetBaseAddress(pixelBuffer);

    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pxdata, videoSize.width, videoSize.height, 8, CVPixelBufferGetBytesPerRow(pixelBuffer), rgbColorSpace, kCGImageAlphaPremultipliedFirst);

    // 填充背景
    CGContextSetFillColorWithColor(context, [UIColor blackColor].CGColor);
    CGContextFillRect(context, CGRectMake(0, 0, videoSize.width, videoSize.height));

    // 居中绘制图像，保持原始比例
    CGRect drawRect = [DYYYUtils rectForImageAspectFit:image.size inSize:videoSize];
    CGContextDrawImage(context, drawRect, image.CGImage);

    CGColorSpaceRelease(rgbColorSpace);
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    // 计算帧数
    NSInteger totalFrames = duration * frameRate;

    // 写入每一帧
    dispatch_queue_t queue = dispatch_queue_create("com.dyyy.videoframe", DISPATCH_QUEUE_SERIAL);
    dispatch_async(queue, ^{
      BOOL success = YES;
      for (int i = 0; i < totalFrames; i++) {
          if (writerInput.readyForMoreMediaData) {
              CMTime frameTime = CMTimeMake(i, frameRate);
              success = [adaptor appendPixelBuffer:pixelBuffer withPresentationTime:frameTime];
              if (!success) {
                  NSLog(@"无法写入像素缓冲区");
                  break;
              }
          } else {
              // 如果写入器未准备好，等待
              usleep(10000);
              i--;
          }
      }

      // 完成视频写入
      [writerInput markAsFinished];
      [videoWriter finishWritingWithCompletionHandler:^{
        if (pixelBuffer) {
            CVPixelBufferRelease(pixelBuffer);
        }

        if (videoWriter.status == AVAssetWriterStatusCompleted) {
            if (completion)
                completion(YES);
        } else {
            NSLog(@"写入视频失败: %@", videoWriter.error);
            if (completion)
                completion(NO);
        }
      }];
    });
}

// 动画贴纸和GIF相关方法迁移自 DYYYUtils.m
+ (void)saveAnimatedSticker:(YYAnimatedImageView *)targetStickerView {
    if (!targetStickerView) {
        [DYYYUtils showToast:@"无法获取表情视图"];
        return;
    }
    UIImage *stickerImage = targetStickerView.image;
    if (!stickerImage) {
        [DYYYUtils showToast:@"无法获取表情内容"];
        return;
    }

    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (status != PHAuthorizationStatusAuthorized) {
            [DYYYUtils showToast:@"需要相册权限才能保存"];
            return;
        }

        NSURL *sourceURL = [DYYYUtils sourceURLForAnimatedImage:stickerImage];
        if (sourceURL) {
            [self downloadMedia:sourceURL
                     mediaType:MediaTypeHeic
                         audio:nil
                    completion:^(BOOL success) {
                      if (!success) {
                          [DYYYUtils showToast:@"表情保存失败"];
                      }
                    }];
            return;
        }

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          NSArray *images = [DYYYUtils getImagesFromAnimatedImage:stickerImage];
          CGFloat duration = [DYYYUtils getDurationFromAnimatedImage:stickerImage];
          if (!images || images.count == 0) {
              dispatch_async(dispatch_get_main_queue(), ^{
                [DYYYUtils showToast:@"无法获取表情帧"];
              });
              return;
          }
          NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"sticker_%ld.gif", (long)[[NSDate date] timeIntervalSince1970]]];
          BOOL success = [DYYYUtils createGIFWithImages:images
                                               duration:duration
                                                   path:tempPath
                                               progress:^(float progress){
                                               }];
          dispatch_async(dispatch_get_main_queue(), ^{
            if (!success) {
                return;
            }
            [DYYYUtils saveGIFToPhotoLibrary:tempPath
                                  completion:^(BOOL saved, NSError *error) {
                               if (saved) {
                                   [DYYYToast showSuccessToastWithMessage:@"已保存到相册"];
                               } else {
                                   NSString *errorMsg = error ? error.localizedDescription : @"未知错误";
                                   [DYYYUtils showToast:[NSString stringWithFormat:@"保存失败: %@", errorMsg]];
                               }
                             }];
          });
        });
      });
    }];
}
+ (void)downloadAndShareCommentAudio:(NSString *)audioContent
                            userName:(NSString *)userName
                          createTime:(NSNumber *)createTime {
    if (!audioContent || audioContent.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [DYYYUtils showToast:@"语音内容为空"];
        });
        return;
    }

    NSData *jsonData = [audioContent dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    NSDictionary *audioDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];

    if (error || !audioDict) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [DYYYUtils showToast:@"语音数据解析失败"];
        });
        NSLog(@"[DYYY] 解析语音 JSON 失败: %@", error);
        return;
    }

    NSArray *videoList = audioDict[@"video_list"];
    if (!videoList || videoList.count == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [DYYYUtils showToast:@"未找到语音URL"];
        });
        return;
    }

    NSDictionary *videoInfo = videoList.firstObject;
    NSString *audioURLString = videoInfo[@"main_url"];
    if (!audioURLString || audioURLString.length == 0) {
        audioURLString = videoInfo[@"backup_url"];
    }

    if (!audioURLString || audioURLString.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [DYYYUtils showToast:@"语音URL无效"];
        });
        return;
    }

    NSURL *audioURL = [NSURL URLWithString:audioURLString];
    if (!audioURL) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [DYYYUtils showToast:@"语音URL格式错误"];
        });
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [DYYYUtils showToast:@"正在下载语音..."];
    });

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:audioURL completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [DYYYUtils showToast:[NSString stringWithFormat:@"下载失败: %@", error.localizedDescription]];
            });
            NSLog(@"[DYYY] 下载语音失败: %@", error);
            return;
        }

        if (!location) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [DYYYUtils showToast:@"下载失败：无效的文件"];
            });
            return;
        }

        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        NSTimeInterval timestamp = (createTime && [createTime doubleValue] > 0) ? [createTime doubleValue] : [[NSDate date] timeIntervalSince1970];
        NSDate *commentDate = [NSDate dateWithTimeIntervalSince1970:timestamp];
        NSString *timeString = [formatter stringFromDate:commentDate];
        timeString = [timeString stringByReplacingOccurrencesOfString:@":" withString:@"-"];
        timeString = [timeString stringByReplacingOccurrencesOfString:@" " withString:@"_"];

        NSString *safeUserName = userName ?: @"未知用户";
        safeUserName = [safeUserName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        safeUserName = [safeUserName stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];

        NSString *fileName = [NSString stringWithFormat:@"%@_%@.m4a", safeUserName, timeString];
        NSString *tempDir = NSTemporaryDirectory();
        NSString *targetPath = [tempDir stringByAppendingPathComponent:fileName];

        NSError *moveError = nil;
        [[NSFileManager defaultManager] removeItemAtPath:targetPath error:nil];
        [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:targetPath error:&moveError];

        if (moveError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [DYYYUtils showToast:@"文件保存失败"];
            });
            NSLog(@"[DYYY] 移动文件失败: %@", moveError);
            return;
        }

        NSURL *fileURL = [NSURL fileURLWithPath:targetPath];

        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *topVC = [DYYYUtils topView];
            if (!topVC) {
                [DYYYUtils showToast:@"无法显示分享界面"];
                return;
            }

            UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];

            activityVC.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
                [[NSFileManager defaultManager] removeItemAtPath:targetPath error:nil];

                if (completed) {
                    [DYYYUtils showToast:@"分享成功"];
                } else if (activityError) {
                    [DYYYUtils showToast:@"分享失败"];
                }
            };

            if ([activityVC respondsToSelector:@selector(popoverPresentationController)]) {
                activityVC.popoverPresentationController.sourceView = topVC.view;
                activityVC.popoverPresentationController.sourceRect = CGRectMake(topVC.view.bounds.size.width / 2, topVC.view.bounds.size.height / 2, 0, 0);
            }

            [topVC presentViewController:activityVC animated:YES completion:nil];
        });
    }];

    [downloadTask resume];
}

@end
