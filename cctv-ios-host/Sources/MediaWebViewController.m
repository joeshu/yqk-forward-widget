#import "MediaWebViewController.h"
#import "HostTheme.h"
#import "RuntimeDiagnostics.h"
#import "MediaPlaybackHeaders.h"
#import <WebKit/WebKit.h>
@interface MediaWebViewController () <WKNavigationDelegate>
@property(nonatomic, copy) NSDictionary *result;
@property(nonatomic) BOOL configurationPage;
@property(nonatomic) BOOL didClose;
@property(nonatomic) BOOL resolvingMedia;
@property(nonatomic) NSUInteger mediaGeneration;
@property(nonatomic,strong) UIBarButtonItem *nativeButton;
@property(nonatomic, strong) WKWebView *web;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic, strong) UILabel *statusLabel;
- (void)installCookieHeader:(NSString *)cookie forURL:(NSURL *)url completion:(dispatch_block_t)completion;
- (void)loadInitialPageAtURL:(NSURL *)url cookie:(NSString *)cookie;
- (void)showStatusMessage:(NSString *)message;
@end
@implementation MediaWebViewController
- (instancetype)initWithResult:(NSDictionary *)result title:(NSString *)title {if((self=[super init])){_result=result;self.title=title;}return self;}
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=HostBackground();
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    UIBarButtonItem *refresh=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refresh)];
    if(self.onTryNativePlayback||self.onResolvedMedia){UIBarButtonItem *native=[[UIBarButtonItem alloc] initWithTitle:@"原生播放" style:UIBarButtonItemStylePlain target:self action:@selector(tryNativePlayback)];self.nativeButton=native;self.navigationItem.rightBarButtonItems=@[native,refresh];}else self.navigationItem.rightBarButtonItem=refresh;
    WKWebViewConfiguration *configuration=[WKWebViewConfiguration new];configuration.websiteDataStore=WKWebsiteDataStore.nonPersistentDataStore;configuration.allowsInlineMediaPlayback=YES;configuration.mediaTypesRequiringUserActionForPlayback=WKAudiovisualMediaTypeNone;
    self.web=[[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];self.web.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;self.web.navigationDelegate=self;self.web.allowsBackForwardNavigationGestures=YES;[self.view addSubview:self.web];
    self.spinner=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.spinner.center=self.view.center;self.spinner.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleRightMargin|UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleBottomMargin;[self.view addSubview:self.spinner];
    self.statusLabel=[UILabel new];self.statusLabel.translatesAutoresizingMaskIntoConstraints=NO;self.statusLabel.numberOfLines=0;self.statusLabel.textAlignment=NSTextAlignmentCenter;self.statusLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.statusLabel.adjustsFontForContentSizeCategory=YES;self.statusLabel.textColor=HostSecondaryText();self.statusLabel.hidden=YES;[self.view addSubview:self.statusLabel];
    [NSLayoutConstraint activateConstraints:@[[self.statusLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],[self.statusLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:48],[self.statusLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],[self.statusLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24]]];
    NSDictionary *headers=MediaPlaybackHeadersFromResult(self.result);for(NSString *key in headers)if([key.lowercaseString isEqual:@"user-agent"])self.web.customUserAgent=headers[key];
    self.configurationPage=[self.result[@"configurationPage"] boolValue];
    NSURL *configurationURL=[NSURL URLWithString:self.result[@"url"]];
    if(self.configurationPage){
        // host 为 nil（如 http:///path）时直接传给 containsObject: 会抛异常，先归一为空串。
        NSString *configurationHost=configurationURL.host.lowercaseString?:@"";
        if(![configurationURL.scheme isEqual:@"http"]||![@[@"127.0.0.1",@"localhost",@"::1"] containsObject:configurationHost]||!configurationURL.port||configurationURL.user.length||configurationURL.password.length){self.navigationItem.prompt=@"配置页地址无效";[self showStatusMessage:@"配置页地址无效，请检查来源配置后重试"];return;}
        // Install only this loopback service's normal login cookie, never a script bridge.
        // Do not gate the first load on the cookie-store install: WKHTTPCookieStore
        // setCookie completion is unreliable on an ephemeral store and can leave the
        // web view with a nil URL (smoke step 16d). The initial request already carries
        // the Cookie header (set in -refresh via MediaPlaybackHeadersFromResult), so
        // load immediately and install the cookie in the background for later navigations.
        NSString *cookie=nil;for(NSString *key in headers)if([key.lowercaseString isEqual:@"cookie"])cookie=headers[key];
        [self loadInitialPageAtURL:configurationURL cookie:cookie];
    }else{
        NSString *cookie=nil;for(NSString *key in headers)if([key.lowercaseString isEqual:@"cookie"])cookie=headers[key];
        [self loadInitialPageAtURL:configurationURL cookie:cookie];
    }
}
- (void)loadInitialPageAtURL:(NSURL *)url cookie:(NSString *)cookie {
    __weak typeof(self) weakSelf=self;__block BOOL started=NO;
    dispatch_block_t startLoading=^{MediaWebViewController *owner=weakSelf;if(!owner||owner.didClose||started)return;started=YES;[owner refresh];};
    if(!cookie.length){startLoading();return;}
    // Cookie-store writes normally finish quickly, but must not block the page
    // forever. The initial request also carries the source's Cookie header;
    // later requests can use the asynchronously installed WebKit cookie.
    [self installCookieHeader:cookie forURL:url completion:startLoading];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1200*NSEC_PER_MSEC),dispatch_get_main_queue(),startLoading);
}
- (void)showStatusMessage:(NSString *)message {self.statusLabel.text=message?:@"";self.statusLabel.hidden=!message.length;}
- (void)installCookieHeader:(NSString *)cookie forURL:(NSURL *)url completion:(dispatch_block_t)completion {
    if(!url.host.length){if(completion)dispatch_async(dispatch_get_main_queue(),completion);return;}
    dispatch_group_t group=dispatch_group_create();
    for(NSString *part in [cookie componentsSeparatedByString:@";"]){NSRange equals=[part rangeOfString:@"="];if(equals.location==NSNotFound)continue;
        NSString *name=[[part substringToIndex:equals.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];NSString *value=[part substringFromIndex:equals.location+1];if(!name.length||[name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound||[value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)continue;
        NSHTTPCookie *item=[NSHTTPCookie cookieWithProperties:@{NSHTTPCookieName:name,NSHTTPCookieValue:value,NSHTTPCookieDomain:url.host,NSHTTPCookiePath:@"/"}];
        if(item){dispatch_group_enter(group);[self.web.configuration.websiteDataStore.httpCookieStore setCookie:item completionHandler:^{dispatch_group_leave(group);}];}}
    dispatch_group_notify(group,dispatch_get_main_queue(),^{if(completion)completion();});
}
- (void)invalidateMediaResolution {self.mediaGeneration++;self.resolvingMedia=NO;self.nativeButton.enabled=YES;}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];if(self.isMovingFromParentViewController||self.isBeingDismissed||self.navigationController.isBeingDismissed){self.didClose=YES;[self invalidateMediaResolution];[self.web stopLoading];self.onResolvedMedia=nil;self.onTryNativePlayback=nil;}}
- (void)refresh {
    if(self.didClose)return;[self invalidateMediaResolution];
    NSString *urlString=[self.result[@"url"] isKindOfClass:NSString.class]?self.result[@"url"]:nil;
    NSURL *targetURL=urlString.length?[NSURL URLWithString:urlString]:nil;
    if(!targetURL||!targetURL.scheme.length){[self.spinner stopAnimating];self.navigationItem.prompt=@"网页地址无效";[self showStatusMessage:@"网页地址无效，无法打开此页面"];return;}
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:targetURL cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25];request.allHTTPHeaderFields=MediaPlaybackHeadersFromResult(self.result);
    self.navigationItem.prompt=self.configurationPage?@"源配置 · 账号数据由此资源管理":@"网页播放 · 由当前来源提供";[self.spinner startAnimating];[self showStatusMessage:nil];[self.web loadRequest:request];
}
- (void)recordMediaEvent:(NSString *)event fields:(NSDictionary *)extra {
    if(self.configurationPage)return;
    NSMutableDictionary *fields=[@{@"correlation_id":self.correlationID?:@"",@"service_id":self.serviceID?:@"",@"playback_attempt_id":self.playbackAttemptID?:@"",@"request_generation":@(self.mediaGeneration)} mutableCopy];
    if(extra)[fields addEntriesFromDictionary:extra];
    [RuntimeDiagnostics.shared recordEvent:event category:@"playback" fields:fields];
}
- (void)tryNativePlayback {
    if(self.didClose||self.resolvingMedia)return;
    if(!self.onResolvedMedia){if(self.onTryNativePlayback){self.didClose=YES;[self.web stopLoading];dispatch_block_t callback=self.onTryNativePlayback;self.onTryNativePlayback=nil;self.onClose=nil;[self dismissViewControllerAnimated:YES completion:callback];}return;}
    self.resolvingMedia=YES;self.nativeButton.enabled=NO;NSUInteger generation=++self.mediaGeneration;self.navigationItem.prompt=@"正在读取网页媒体地址…";
    [self recordMediaEvent:@"web_media_extraction_started" fields:nil];
    NSString *script=@"(function scan(w){try{for(const v of w.document.querySelectorAll('video,audio')){const s=v.currentSrc||v.src;if(/^https?:/i.test(s))return s;}for(const f of w.frames){const s=scan(f);if(s)return s;}}catch(e){}return ''; })(window)";
    __weak typeof(self) weakSelf=self;
    [self.web evaluateJavaScript:script completionHandler:^(id value,NSError *error){
        MediaWebViewController *owner=weakSelf;if(!owner||owner.didClose||owner.mediaGeneration!=generation)return;
        NSString *raw=[value isKindOfClass:NSString.class]?value:@"";NSURL *url=[NSURL URLWithString:raw];
        if(error||raw.length>8192||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]||!url.host.length||url.user.length||url.password.length||[raw rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){[owner recordMediaEvent:@"web_media_extraction_failed" fields:@{@"failure_stage":error?@"javascript_evaluation":@"no_valid_http_media",@"result_has_media_url":@(raw.length>0),@"error_domain":error.domain?:@"",@"error_code":@(error.code)}];owner.resolvingMedia=NO;owner.nativeButton.enabled=YES;owner.navigationItem.prompt=@"尚未取得可交给原生播放器的地址，请先在网页内开始播放";return;}
        NSMutableDictionary *headers=[MediaPlaybackHeadersFromResult(owner.result) mutableCopy];
        // Page credentials must not be forwarded to a different media origin.
        for(NSString *key in headers.allKeys.copy)if([@[@"cookie",@"authorization",@"proxy-authorization"] containsObject:key.lowercaseString])[headers removeObjectForKey:key];
        if(owner.web.URL.absoluteString.length)headers[@"Referer"]=owner.web.URL.absoluteString;
        [owner.web.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies){dispatch_async(dispatch_get_main_queue(),^{
            MediaWebViewController *page=weakSelf;if(!page||page.didClose||page.mediaGeneration!=generation)return;
            NSMutableArray *matching=[NSMutableArray array];for(NSHTTPCookie *cookie in cookies){NSString *domain=cookie.domain.lowercaseString;BOOL subdomains=[domain hasPrefix:@"."];if(subdomains)domain=[domain substringFromIndex:1];BOOL host=[url.host.lowercaseString isEqual:domain]||(subdomains&&[url.host.lowercaseString hasSuffix:[@"." stringByAppendingString:domain]]);NSString *path=url.path.length?url.path:@"/";NSString *cp=cookie.path.length?cookie.path:@"/";BOOL pathMatch=[path isEqual:cp]||([path hasPrefix:cp]&&([cp hasSuffix:@"/"]||[path hasPrefix:[cp stringByAppendingString:@"/"]]));if(host&&pathMatch&&(!cookie.secure||[url.scheme.lowercaseString isEqual:@"https"])&&(!cookie.expiresDate||[cookie.expiresDate timeIntervalSinceNow]>0))[matching addObject:cookie];}
            [headers addEntriesFromDictionary:[NSHTTPCookie requestHeaderFieldsWithCookies:matching]];
            NSDictionary *resolved=@{@"url":raw,@"headers":headers,@"parse":@0,@"jx":@0,@"requiresWebPlayback":@NO};
            [page recordMediaEvent:@"web_media_native_handoff" fields:@{@"result_has_media_url":@YES,@"transport_host":url.host.lowercaseString?:@"",@"request_header_count":@(headers.count),@"matched_cookie_count":@(matching.count)}];page.didClose=YES;[page.web stopLoading];void (^callback)(NSDictionary *)=page.onResolvedMedia;page.onResolvedMedia=nil;page.onClose=nil;[page dismissViewControllerAnimated:YES completion:^{if(callback)callback(resolved);}];
        });}];
    }];
    // evaluateJavaScript 与 getAllCookies 均无超时：挂起时 resolvingMedia 恒为
    // YES、原生按钮永久禁用。15 秒后若同一代次仍未完成，直接失效本次解析，
    // 让迟到的回调因代次不匹配而丢弃，用户可重试。
    __weak typeof(self) weakTimeoutSelf=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,15*NSEC_PER_SEC),dispatch_get_main_queue(),^{MediaWebViewController *owner=weakTimeoutSelf;if(!owner||owner.didClose||owner.mediaGeneration!=generation||!owner.resolvingMedia)return;[owner recordMediaEvent:@"web_media_extraction_timeout" fields:nil];[owner invalidateMediaResolution];owner.navigationItem.prompt=@"网页媒体读取超时，请重试";});
}
- (void)close {if(self.didClose)return;self.didClose=YES;[self.web stopLoading];dispatch_block_t callback=self.onClose;self.onClose=nil;[self dismissViewControllerAnimated:YES completion:callback];}
- (void)dealloc {self.web.navigationDelegate=nil;[self.web stopLoading];}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url=action.request.URL;NSString *scheme=url.scheme.lowercaseString?:@"";BOOL allowed=[@[@"http",@"https",@"about"] containsObject:scheme];if(self.configurationPage&&(action.targetFrame.isMainFrame||!action.targetFrame)){NSURL *base=[NSURL URLWithString:self.result[@"url"]];allowed=allowed&&[url.scheme.lowercaseString isEqual:base.scheme.lowercaseString]&&[url.host.lowercaseString isEqual:base.host.lowercaseString]&&[(url.port?:@0) isEqual:(base.port?:@0)];if(!allowed)self.navigationItem.prompt=@"此操作需要离开源配置页，当前未打开";}
    decisionHandler(allowed?WKNavigationActionPolicyAllow:WKNavigationActionPolicyCancel);
    if(allowed && !action.targetFrame)[webView loadRequest:action.request];
}
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {[self invalidateMediaResolution];[self showStatusMessage:nil];}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {[self.spinner stopAnimating];self.navigationItem.prompt=nil;[self showStatusMessage:nil];}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {[self failed:error];}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {[self failed:error];}
- (void)failed:(NSError *)error {if(error.code==NSURLErrorCancelled)return;[self.spinner stopAnimating];[self recordMediaEvent:@"web_media_navigation_failed" fields:@{@"failure_stage":@"web_navigation",@"error_domain":error.domain?:@"",@"error_code":@(error.code)}];self.navigationItem.prompt=error.localizedDescription;[self showStatusMessage:error.localizedDescription];}
@end
