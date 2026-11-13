#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, ResourceImportOption) {
    ResourceImportOptionLiveURL,
    ResourceImportOptionMediaURL,
    ResourceImportOptionLiveFile,
    ResourceImportOptionMediaFile,
    ResourceImportOptionServices,
    ResourceImportOptionTVBox,
    ResourceImportOptionMacCMS,
    ResourceImportOptionPythonURL,
    ResourceImportOptionCatVodURL,
    ResourceImportOptionNodeURL,
    ResourceImportOptionPythonFile,
    ResourceImportOptionNodeFile,
    ResourceImportOptionHostCapabilities,
    ResourceImportOptionFolder,
    ResourceImportOptionTVBoxFile,
    ResourceImportOptionMediaServer
};

@interface ResourceImportSheetViewController : UIViewController
@property(nonatomic, copy) void (^onSelect)(ResourceImportOption option);
- (void)reloadThemeAppearance;
@end
