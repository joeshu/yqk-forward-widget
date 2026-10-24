#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Validates bundled route URLs and retains the legacy CDN-config rollback helper.
// A successful config readback does not prove which CDN playback actually used.
@interface NativeCDNPreference : NSObject
@property(nonatomic,readonly) BOOL overrideMayBeActive;
@property(nonatomic,copy,readonly,nullable) NSDictionary *requestedPreference;
- (instancetype)initWithPlayerClass:(nullable Class)playerClass configurationClass:(nullable Class)configurationClass;
- (nullable NSString *)URLForRoute:(NSDictionary *)route error:(NSError **)error;
- (BOOL)applyRoute:(NSDictionary *)route error:(NSError **)error;
- (BOOL)restoreDefault:(NSError **)error;
+ (NSString *)observedCDNDescriptionForPlayer:(nullable id)player;
@end
NS_ASSUME_NONNULL_END
