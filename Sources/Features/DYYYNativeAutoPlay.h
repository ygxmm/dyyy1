#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// DYYY owns the saved switch; Douyin still executes the playback and paging.
FOUNDATION_EXPORT BOOL DYYYAutoPlayIsEnabled(void);
/// Persists the switch even if the current host cannot apply it immediately.
FOUNDATION_EXPORT BOOL DYYYAutoPlaySetEnabled(BOOL enabled);
FOUNDATION_EXPORT void DYYYRestoreAutoPlayPreference(void);
FOUNDATION_EXPORT NSDictionary *DYYYAutoPlayNormalizeBackup(NSDictionary *settings);

NS_ASSUME_NONNULL_END
