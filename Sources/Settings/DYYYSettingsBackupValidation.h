#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSUInteger const DYYYSettingsBackupMaximumBytes;
FOUNDATION_EXPORT NSUInteger const DYYYSettingsBackupMaximumIconBytes;
FOUNDATION_EXPORT NSString *const DYYYSettingsBackupValidationErrorDomain;

// 校验结果仅含可写入偏好的不可变 JSON/plist 值，以及已验证的原始图片数据。
@interface DYYYValidatedSettingsBackup : NSObject
@property(nonatomic, copy, readonly) NSDictionary<NSString *, id> *settings;
@property(nonatomic, copy, readonly) NSDictionary<NSString *, NSData *> *icons;
@end

// 与旧导出一致的八个固定文件名，不从备份内容构造任意路径。
FOUNDATION_EXPORT NSArray<NSString *> *DYYYSettingsBackupIconFileNames(void);
// 有界读取：即使文件提供器未报告长度，也不会无限读入内存。
FOUNDATION_EXPORT NSData *_Nullable DYYYReadSettingsBackupData(NSURL *url, NSError * _Nullable * _Nullable error);
// 纯校验，无偏好、文件系统写入；任何项目失败即拒绝整个备份。
FOUNDATION_EXPORT DYYYValidatedSettingsBackup *_Nullable DYYYValidateSettingsBackupData(NSData *data, NSError * _Nullable * _Nullable error);

// 仅转换本次导入中尚未迁移的旧 HDR/尺寸键；本机配置只用于补缺判断。
// 输出的删除键和新增完成标记必须与配置一起纳入同一提交/回滚。
FOUNDATION_EXPORT NSDictionary<NSString *, id> *_Nullable DYYYNormalizeLegacySettingsBackup(
    NSDictionary<NSString *, id> *settings, NSDictionary<NSString *, id> *existingSettings,
    NSSet<NSString *> * _Nullable * _Nullable keysToRemove, NSError * _Nullable * _Nullable error);

// 接收已验证并完成兼容归一化的配置；失败会回滚，仅触及本次白名单图标和配置键。
// documentsURL/defaults/domain 可注入临时目录及测试 suite，不依赖宿主或 UIKit。
FOUNDATION_EXPORT BOOL DYYYCommitSettingsBackup(NSDictionary<NSString *, id> *settings,
    NSDictionary<NSString *, NSData *> *icons, NSSet<NSString *> *keysToRemove,
    NSUserDefaults *defaults, NSString *domain,
    NSURL *documentsURL, NSError * _Nullable * _Nullable error);

// 导出只读取规范目录下的白名单普通文件，拒绝目录/文件符号链接及超限图片。
FOUNDATION_EXPORT NSDictionary<NSString *, NSData *> *_Nullable DYYYReadSettingsBackupIcons(NSURL *documentsURL, NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
