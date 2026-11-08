#import <UIKit/UIKit.h>

@interface MediaBrowserViewController : UIViewController
/// Refresh installed sources while preserving the current browser state when possible.
- (void)refreshSources;
/// Media display preferences, pushable from Settings without loading this page.
- (UIViewController *)mediaDisplaySettingsViewController;
- (void)reloadMediaDisplayConfigurationIfLoaded;
- (void)openSourceIdentifier:(NSString *)identifier;
- (void)invalidateServiceIdentifier:(NSString *)identifier;
- (void)showConfigurationForSource:(NSDictionary *)source;
- (void)activate:(NSDictionary *)source;
- (void)activate:(NSDictionary *)source keepingHome:(BOOL)keepingHome;
@property(nonatomic, copy) NSArray<NSDictionary *> *(^sourcesProvider)(void);
/// Saved TVBox collections are listed alongside resources and opened only when selected.
@property(nonatomic, copy) NSArray<NSDictionary *> *(^catalogsProvider)(void);
@property(nonatomic, copy) void (^onOpenTVBoxCatalog)(NSString *catalogID);
/// Loads only the selected script site from the current catalog.
@property(nonatomic, copy) void (^onImportCatalogSite)(NSDictionary *site,NSString *catalogID);
/// Adds the selected playlist from a grouped live catalog.
@property(nonatomic, copy) void (^onSubscribeCatalogLive)(NSDictionary *live,NSString *catalogID);
@property(nonatomic, copy) void (^onActivateService)(NSDictionary *service,void (^completion)(NSError *error));
@property(nonatomic, copy) void (^onRestartService)(NSDictionary *service,void (^completion)(NSError *error));
- (void)checkCurrentService;
- (void)pauseForBackground;
- (void)resumeAfterForeground;
- (void)saveSessionState;
- (void)returnToHomeFromNavigation;
- (BOOL)refreshHomeContentFromResourcePage;
@property(nonatomic, copy) void (^onPlay)(NSDictionary *result,NSDictionary *context);
/// Gives the app playback owner a chance to suspend live playback before VOD starts.
@property(nonatomic, copy) dispatch_block_t onPlaybackWillStart;
@property(nonatomic, copy) dispatch_block_t onResources;
@property(nonatomic, copy) NSError *(^startupErrorProvider)(void);
@property(nonatomic, copy) NSError *(^startupErrorForService)(NSDictionary *service);
@property(nonatomic, copy) void (^onSubscribeLive)(NSDictionary *service);
@property(nonatomic, readonly, getter=isHomeMode) BOOL homeMode;
@property(nonatomic, copy) void (^onDisplayModeChanged)(BOOL homeMode);
/// Set before the view is loaded when restoring the app session. Cached content is shown, but no service or media request is started.
@property(nonatomic) BOOL deferAutomaticLoading;
/// Starts or refreshes the selected source only after an explicit user action.
- (void)loadHomeOnDemand;
- (void)setTopSafeAreaInset:(CGFloat)inset;
- (void)setBottomOverlayInset:(CGFloat)inset;
- (void)prepareForNavigationTransition;
- (void)refreshHeaderAfterNavigationTransition;
@end
