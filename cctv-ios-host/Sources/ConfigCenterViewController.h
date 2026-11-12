#import <UIKit/UIKit.h>
@interface ConfigCenterViewController : UITableViewController
- (void)setTopSafeAreaInset:(CGFloat)inset;
- (void)setBottomOverlayInset:(CGFloat)inset;
- (void)prepareForNavigationTransition;
- (void)refreshHeaderAfterNavigationTransition;
- (void)reloadProfiles;
- (void)refreshProfiles;
- (void)reloadThemeAppearance;
- (void)probeSingleProfile:(NSString *)source;
- (void)copyResourceDiagnosticSummary;
@property(nonatomic, copy) NSArray<NSDictionary *> * (^profilesProvider)(void);
@property(nonatomic, copy) dispatch_block_t onServices;
@property(nonatomic, copy) dispatch_block_t onAdd;
@property(nonatomic, copy) NSString * (^importTaskSummaryProvider)(void);
@property(nonatomic, copy) dispatch_block_t onRefresh;
@property(nonatomic, copy) dispatch_block_t onRefreshMediaHome;
@property(nonatomic, copy) void (^onRefreshProfile)(NSString *source);
@property(nonatomic, copy) void (^onOpenSubscription)(NSString *source);
@property(nonatomic, copy) void (^onRecheckProfile)(NSString *source);
@property(nonatomic, copy) void (^onRematchEPGProfile)(NSString *source);
@property(nonatomic, copy) void (^onRestartProfile)(NSString *source);
@property(nonatomic, copy) void (^onRefreshCatalogProfile)(NSString *source);
@property(nonatomic, copy) void (^onSelectProfile)(NSString *source);
@property(nonatomic, copy) void (^onToggleProfile)(NSString *source, BOOL enabled);
@property(nonatomic, copy) void (^onToggleChannelLogo)(NSString *source, BOOL enabled);
@property(nonatomic, copy) void (^onTogglePlayerCornerLogo)(NSString *source, BOOL enabled);
@property(nonatomic, copy) void (^onToggleChannelPreview)(NSString *source, BOOL enabled);
@property(nonatomic, copy) void (^onToggleChannelTelemetry)(NSString *source, BOOL enabled);
@property(nonatomic, copy) void (^onMatchStationLogos)(NSString *source);
@property(nonatomic, copy) void (^onEditProfile)(NSString *source);
@property(nonatomic, copy) void (^onDeleteProfile)(NSString *source);
@property(nonatomic, copy) void (^onOpenResource)(NSString *source);
@property(nonatomic, copy) void (^onUseResource)(NSString *source, NSString *kind);
@property(nonatomic, copy) void (^onOpenTVBoxCatalog)(NSString *catalogID);
@property(nonatomic, copy) void (^onExportResource)(NSString *source,NSString *format);
@end
