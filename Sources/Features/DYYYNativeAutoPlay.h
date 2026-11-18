#import <Foundation/Foundation.h>

// Use the same state as the native long-press panel, not a forced getter result.
FOUNDATION_EXPORT BOOL DYYYNativeAutoPlayIsEnabled(void);
FOUNDATION_EXPORT BOOL DYYYNativeAutoPlaySetEnabled(BOOL enabled);
FOUNDATION_EXPORT void DYYYNativeAutoPlayMigrateLegacySetting(void);
