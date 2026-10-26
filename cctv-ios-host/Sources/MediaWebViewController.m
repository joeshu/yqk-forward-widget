#import "MediaWebViewController.h"
#import "HostTheme.h"
#import "MediaPlaybackHeaders.h"
#import <WebKit/WebKit.h>
@interface MediaWebViewController () <WKNavigationDelegate>
@property(nonatomic, copy) NSDictionary *result;
@property(nonatomic) BOOL configurationPage;
@property(nonatomic) BOOL didClose;
@property(nonatomic, strong) WKWebView *web;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
- (void)installCookieHeader:(NSString *)cookie forURL:(NSURL *)url completion:(dispatch_block_t)completion;
@end
@implementation MediaWebViewController
- (instancetype)initWithResult:(NSDictionary *)result title:(NSString *)title {if((self=[super init])){_result=result;self.title=title;}return self;}
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=HostBackground();
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    UIBarButtonItem *refresh=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)];
    if(self.onTryNativePlayback){UIBarButtonItem *native=[[UIBarButtonItem alloc] initWithTitle:@"原生播放" style:UIBarButtonItemStylePlain target:self action:@selector(tryNativePlayback)];self.navigationItem.rightBarButtonItems=@[native,refresh];}else self.navigationItem.rightBarButtonItem=refresh;
    WKWebViewConfiguration *configuration=[WKWebViewConfiguration new];configuration.websiteDataStore=WKWebsiteDataStore.nonPersistentDataStore;configuration.allowsInlineMediaPlayback=YES;configuration.mediaTypesRequiringUserActionForPlayback=WKAudiovisualMediaTypeNone;
    self.web=[[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];self.web.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;self.web.navigationDelegate=self;self.web.allowsBackForwardNavigationGestures=YES;[self.view addSubview:self.web];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.spinner.center=self.view.center;self.spinner.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleRightMargin|UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleBottomMargin;[self.view addSubview:self.spinner];
    NSDictionary *headers=MediaPlaybackHeadersFromResult(self.result);for(NSString *key in headers)if([key.lowercaseString isEqual:@"user-agent"])self.web.customUserAgent=headers[key];
    self.configurationPage=[self.result[@"configurationPage"] boolValue];
    NSURL *configurationURL=[NSURL URLWithString:self.result[@"url"]];
    if(self.configurationPage){
        if(![configurationURL.scheme isEqual:@"http"]||![@[@"127.0.0.1",@"localhost",@"::1"] containsObject:configurationURL.host.lowercaseString]||!configurationURL.port||configurationURL.user.length||configurationURL.password.length){self.navigationItem.prompt=@"配置页地址无效";return;}
        // Install only this loopback service's normal login cookie, never a script bridge.
        NSString *cookie=nil;for(NSString *key in headers)if([key.lowercaseString isEqual:@"cookie"])cookie=headers[key];
        [self installCookieHeader:cookie forURL:configurationURL completion:^{if(!self.didClose)[self refresh];}];
    }else{
        NSString *cookie=nil;for(NSString *key in headers)if([key.lowercaseString isEqual:@"cookie"])cookie=headers[key];
        if(cookie.length)[self installCookieHeader:cookie forURL:configurationURL completion:^{if(!self.didClose)[self refresh];}];else[self refresh];
    }
}
- (void)installCookieHeader:(NSString *)cookie forURL:(NSURL *)url completion:(dispatch_block_t)completion {
    if(!url.host.length){if(completion)dispatch_async(dispatch_get_main_queue(),completion);return;}
    dispatch_group_t group=dispatch_group_create();
    for(NSString *part in [cookie componentsSeparatedByString:@";"]){NSRange equals=[part rangeOfString:@"="];if(equals.location==NSNotFound)continue;
        NSString *name=[[part substringToIndex:equals.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];NSString *value=[part substringFromIndex:equals.location+1];if(!name.length||[name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound||[value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)continue;
        NSHTTPCookie *item=[NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName:name,NSHTTPCookieValue:value,NSHTTPCookieDomain:url.host,NSHTTPCookiePath:@"/"}];
        if(item){dispatch_group_enter(group);[self.web.configuration.websiteDataStore.httpCookieStore setCookie:item completionHandler:^{dispatch_group_leave(group);}];}}
    dispatch_group_notify(group,dispatch_get_main_queue(),^{if(completion)completion();});
}
- (void)refresh {
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:self.result[@"url"]] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25];request.allHTTPHeaderFields=MediaPlaybackHeadersFromResult(self.result);
    self.navigationItem.prompt=self.configurationPage?@"源配置 · 账号数据由此资源管理":@"网页播放 · 由当前来源提供";[self.spinner startAnimating];[self.web loadRequest:request];
}
- (void)tryNativePlayback {if(self.didClose||!self.onTryNativePlayback)return;self.didClose=YES;[self.web stopLoading];dispatch_block_t callback=self.onTryNativePlayback;self.onTryNativePlayback=nil;self.onClose=nil;[self dismissViewControllerAnimated:YES completion:callback];}
- (void)close {if(self.didClose)return;self.didClose=YES;[self.web stopLoading];dispatch_block_t callback=self.onClose;self.onClose=nil;[self dismissViewControllerAnimated:YES completion:callback];}
- (void)dealloc {self.web.navigationDelegate=nil;[self.web stopLoading];}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url=action.request.URL;BOOL allowed=[@[@"http",@"https",@"about"] containsObject:url.scheme.lowercaseString];if(self.configurationPage&&(action.targetFrame.isMainFrame||!action.targetFrame)){NSURL *base=[NSURL URLWithString:self.result[@"url"]];allowed=allowed&&[url.scheme.lowercaseString isEqual:base.scheme.lowercaseString]&&[url.host.lowercaseString isEqual:base.host.lowercaseString]&&[(url.port?:@0) isEqual:(base.port?:@0)];if(!allowed)self.navigationItem.prompt=@"此操作需要离开源配置页，当前未打开";}
    decisionHandler(allowed?WKNavigationActionPolicyAllow:WKNavigationActionPolicyCancel);
    if(allowed && !action.targetFrame)[webView loadRequest:action.request];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {[self.spinner stopAnimating];self.navigationItem.prompt=nil;}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {[self failed:error];}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {[self failed:error];}
- (void)failed:(NSError *)error {if(error.code==NSURLErrorCancelled)return;[self.spinner stopAnimating];self.navigationItem.prompt=error.localizedDescription;}
@end
