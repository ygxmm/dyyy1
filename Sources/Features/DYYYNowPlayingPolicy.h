#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// 统一协调旧版Now Playing和系统自动发布会话信息、播放态及会话资格；不持有媒体对象。
@interface DYYYNowPlayingPolicy : NSObject
@property(nonatomic, readonly) BOOL suppressed;
- (BOOL)hasRequestForChannel:(NSString *)channel owner:(id)owner;
- (BOOL)configureChannel:(NSString *)channel hiddenValue:(nullable id)value sink:(void (^)(id owner, id _Nullable value))sink;
- (void)writeValue:(nullable id)value owner:(id)owner channel:(NSString *)channel;
- (void)seedValue:(nullable id)value owner:(id)owner channel:(NSString *)channel;
- (void)forgetOwner:(id)owner;
- (BOOL)setSuppressed:(BOOL)suppressed;
@end
NS_ASSUME_NONNULL_END
