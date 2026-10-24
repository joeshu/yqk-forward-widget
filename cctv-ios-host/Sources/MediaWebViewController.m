#import "MediaWebViewController.h"
#import "HostTheme.h"
#import <WebKit/WebKit.h>
@interface MediaWebViewController () <WKNavigationDelegate>
@property(nonatomic, copy) NSDictionary *result;
@property(nonatomic, strong) WKWebView *web;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@end
@implementation MediaWebViewController
- (instancetype)initWithResult:(NSDictionary *)result title:(NSString *)title {if((self=[super init])){_result=result;self.title=title;}return self;}
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=HostBackground();
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)];
    WKWebViewConfiguration *configuration=[WKWebViewConfiguration new];configuration.websiteDataStore=WKWebsiteDataStore.nonPersistentDataStore;configuration.allowsInlineMediaPlayback=YES;configuration.mediaTypesRequiringUserActionForPlayback=WKAudiovisualMediaTypeNone;
    self.web=[[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];self.web.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;self.web.navigationDelegate=self;self.web.allowsBackForwardNavigationGestures=YES;[self.view addSubview:self.web];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.spinner.center=self.view.center;self.spinner.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleRightMargin|UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleBottomMargin;[self.view addSubview:self.spinner];
    NSDictionary *headers=self.result[@"headers"];for(NSString *key in headers)if([key.lowercaseString isEqual:@"user-agent"])self.web.customUserAgent=headers[key];
    [self refresh];
}
- (void)refresh {
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:self.result[@"url"]] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25];request.allHTTPHeaderFields=self.result[@"headers"];
    self.navigationItem.prompt=@"网页播放 · 由当前来源提供";[self.spinner startAnimating];[self.web loadRequest:request];
}
- (void)close {[self.web stopLoading];[self dismissViewControllerAnimated:YES completion:nil];}
- (void)dealloc {self.web.navigationDelegate=nil;[self.web stopLoading];}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url=action.request.URL;BOOL allowed=[@[@"http",@"https",@"about"] containsObject:url.scheme.lowercaseString];decisionHandler(allowed?WKNavigationActionPolicyAllow:WKNavigationActionPolicyCancel);
    if(allowed && !action.targetFrame)[webView loadRequest:action.request];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {[self.spinner stopAnimating];self.navigationItem.prompt=nil;}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {[self failed:error];}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {[self failed:error];}
- (void)failed:(NSError *)error {if(error.code==NSURLErrorCancelled)return;[self.spinner stopAnimating];self.navigationItem.prompt=error.localizedDescription;}
@end
