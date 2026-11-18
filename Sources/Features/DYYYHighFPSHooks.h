#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^DYYYFPSReadout)(NSInteger fps);

/// 在前台维护可随时释放的刷新率请求；不改宿主设置。
FOUNDATION_EXPORT void DYYYStartHighFPSHooks(void);

/// 主线程注册/移除显示回调；负值表示开始新一轮采样。
FOUNDATION_EXPORT void DYYYSetFPSReadout(DYYYFPSReadout _Nullable readout);

NS_ASSUME_NONNULL_END
