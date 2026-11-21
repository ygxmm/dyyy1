#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, DYYYABConfigMode) {
    DYYYABConfigModeUnspecified,
    DYYYABConfigModePatch,
    DYYYABConfigModeReplace,
    DYYYABConfigModeRemote,
};

/// 仅限制接收完成后的提交大小，不是流式接收的内存上限。
FOUNDATION_EXPORT const NSUInteger DYYYABConfigMaximumRemoteBytes;
/// 本地历史整份配置允许到四十兆，不沿用远程提交的八兆限制。
FOUNDATION_EXPORT const NSUInteger DYYYABConfigMaximumLocalBytes;

/// 文件只允许覆写或替换；设置还支持远程模式和原有中文名称。
FOUNDATION_EXPORT DYYYABConfigMode DYYYABConfigModeForPreference(id _Nullable preference);
FOUNDATION_EXPORT BOOL DYYYABConfigUsesPatchMode(DYYYABConfigMode preferenceMode, DYYYABConfigMode fileMode);

/// 支持非空的 data 封装或非空纯字典。失败时不写入 fileMode。
FOUNDATION_EXPORT NSDictionary * _Nullable DYYYABConfigParseJSON(NSData * _Nullable jsonData, DYYYABConfigMode * _Nullable fileMode,
                                                                 NSError * _Nullable * _Nullable error);

/// 仅接受有主机名的 HTTPS 地址，也用于校验重定向目标。
FOUNDATION_EXPORT NSURL * _Nullable DYYYABConfigHTTPSURL(id _Nullable value);
/// 检查最终响应的协议、HTTP 状态和声明的体积；完成回调另检实际体积。
FOUNDATION_EXPORT BOOL DYYYABConfigAcceptsResponse(NSURLResponse * _Nullable response);
FOUNDATION_EXPORT BOOL DYYYABConfigCanAppendBytes(NSUInteger received, NSUInteger incoming);

/// 先验证再原子保存；失败不改变磁盘旧文件及任何输出参数，错误参数除外。
FOUNDATION_EXPORT BOOL DYYYABConfigPersistJSON(NSData *jsonData, NSString *path,
    NSDictionary * _Nullable * _Nullable config, DYYYABConfigMode * _Nullable fileMode,
    BOOL * _Nullable updated, NSError * _Nullable * _Nullable error);

/// 仅从本地文件流有限读取，取得的安全作用域会在返回前配对释放。
FOUNDATION_EXPORT NSData * _Nullable DYYYABConfigReadLocalFileURL(NSURL * _Nullable url,
    NSError * _Nullable * _Nullable error);
/// 只删除普通文件或符号链接；确认为不存在也成功，其余失败保留调用方状态。
FOUNDATION_EXPORT BOOL DYYYABConfigDeleteFile(NSString * _Nullable path,
    NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
