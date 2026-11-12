#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const CCTVMediaAdaptationMonitorDidUpdateNotification;
FOUNDATION_EXPORT NSString *const CCTVMediaAdaptationMonitorEnabledKey;
FOUNDATION_EXPORT NSString *const CCTVMediaAdaptationMonitorRecordsKey;

@interface MediaAdaptationMonitor : NSObject

+ (instancetype)shared;

@property(nonatomic, assign, getter=isMonitoringEnabled) BOOL monitoringEnabled;

- (NSArray<NSDictionary *> *)allRecords;
- (NSArray<NSDictionary *> *)recordsFilteredByKind:(nullable NSString *)kind
                                       searchQuery:(nullable NSString *)query;
- (NSArray<NSDictionary *> *)siteHealthSummaries;
- (NSDictionary *)playerAdaptationSummary;

- (void)recordAPICallWithOperation:(NSString *)operation
                            source:(nullable NSDictionary *)source
                          provider:(nullable NSString *)provider
                         arguments:(nullable NSDictionary *)arguments
                            result:(nullable id)result
                             error:(nullable NSError *)error
                         elapsedMs:(NSInteger)elapsedMs;

- (void)recordPlaybackAdaptationWithSource:(nullable NSDictionary *)source
                                  provider:(nullable NSString *)provider
                                 mediaName:(nullable NSString *)mediaName
                               episodeName:(nullable NSString *)episodeName
                                  lineName:(nullable NSString *)lineName
                                 streamURL:(nullable NSString *)streamURL
                               originalURL:(nullable NSString *)originalURL
                              playerEngine:(nullable NSString *)playerEngine
                                 routeKind:(nullable NSString *)routeKind
                           containerFormat:(nullable NSString *)containerFormat
                                videoCodec:(nullable NSString *)videoCodec
                                   headers:(nullable NSDictionary *)headers
                                 startupMs:(NSInteger)startupMs
                                   success:(BOOL)success
                              failureStage:(nullable NSString *)failureStage
                              errorMessage:(nullable NSString *)errorMessage;

- (void)recordCatalogEventWithName:(NSString *)name
                         sourceURL:(nullable NSString *)sourceURL
                         siteCount:(NSUInteger)siteCount
                    supportedCount:(NSUInteger)supportedCount
                         liveCount:(NSUInteger)liveCount
                        bundleType:(nullable NSString *)bundleType
                       jarVerified:(BOOL)jarVerified
                             notes:(nullable NSString *)notes;

- (NSDictionary *)decodeAndInspectConfigString:(NSString *)rawInput;

- (void)batchProbeCatalogSites:(nullable NSArray<NSDictionary *> *)sites
                   catalogName:(nullable NSString *)catalogName
                    completion:(void (^_Nullable)(NSDictionary *summary))completion;

- (void)probeURLString:(NSString *)urlString
               headers:(nullable NSDictionary<NSString *, NSString *> *)headers
            contextTag:(nullable NSString *)contextTag
            completion:(void (^)(NSDictionary *report))completion;

- (NSString *)diagnosisAndRecommendationForRecord:(NSDictionary *)record;
- (NSString *)exportDiagnosticReportText;
- (void)clearAllRecords;

@end

@interface MediaAdaptationMonitorViewController : UIViewController

@property(nonatomic, copy, nullable) NSDictionary *initialContext;

- (instancetype)initWithContext:(nullable NSDictionary *)context;

@end

NS_ASSUME_NONNULL_END
