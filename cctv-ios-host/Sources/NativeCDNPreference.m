#import "NativeCDNPreference.h"
#import <objc/message.h>
#include <string.h>

@interface NativeCDNPreference ()
@property(nonatomic) Class playerClass;
@property(nonatomic) Class configurationClass;
@property(nonatomic,copy) NSDictionary *defaultPreference;
@property(nonatomic,copy,readwrite) NSDictionary *requestedPreference;
@property(nonatomic,readwrite) BOOL overrideMayBeActive;
@end
@implementation NativeCDNPreference
- (instancetype)init {return [self initWithPlayerClass:NSClassFromString(@"CNPlayer") configurationClass:NSClassFromString(@"CNVDNManager")];}
- (instancetype)initWithPlayerClass:(Class)playerClass configurationClass:(Class)configurationClass {
    if((self=[super init])){_playerClass=playerClass;_configurationClass=configurationClass;}return self;
}
- (NSError *)error:(NSString *)message {return [NSError errorWithDomain:@"CCTVHostCDN" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
- (NSDictionary *)readPreference:(NSError **)error {
    SEL selector=NSSelectorFromString(@"getVDNConfig_CDNLive_DefaultCDNInfo");
    NSMethodSignature *signature=[self.configurationClass methodSignatureForSelector:selector];
    if(![self.configurationClass respondsToSelector:selector]||signature.numberOfArguments!=2||signature.methodReturnType[0]!='@'){
        if(error)*error=[self error:@"当前 SDK 无法回读 CDN 配置，未切换线路。请使用 SDK 自动线路。"];return nil;
    }
    @try {
        id value=((id(*)(id,SEL))objc_msgSend)(self.configurationClass,selector);
        if([value isKindOfClass:NSDictionary.class]&&[value count])return [value copy];
    }@catch(NSException *exception){}
    if(error)*error=[self error:@"SDK 未返回有效 CDN 配置，未切换线路。请使用 SDK 自动线路。"];return nil;
}
- (BOOL)canWritePreference:(NSError **)error {
    SEL selector=NSSelectorFromString(@"configSDK_CDN_LIVEDefaultCDNInfo:");
    NSMethodSignature *signature=[self.playerClass methodSignatureForSelector:selector];
    if(![self.playerClass respondsToSelector:selector]||signature.numberOfArguments!=3||signature.methodReturnType[0]!='@'||strcmp([signature getArgumentTypeAtIndex:2],"@")!=0){
        if(error)*error=[self error:@"当前 SDK 不支持 CDN 偏好配置。请使用 SDK 自动线路。"];return NO;
    }
    return YES;
}
- (BOOL)writePreference:(NSDictionary *)preference error:(NSError **)error {
    if(![self canWritePreference:error])return NO;
    SEL selector=NSSelectorFromString(@"configSDK_CDN_LIVEDefaultCDNInfo:");
    @try {
        id failure=((id(*)(id,SEL,id))objc_msgSend)(self.playerClass,selector,preference);
        if(failure){
            if(error)*error=[failure isKindOfClass:NSError.class]?[NSError errorWithDomain:@"CCTVHostCDN" code:2 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"SDK 拒绝 CDN 偏好配置（%@ %ld），请查看 SDK 日志。",[failure domain],(long)[failure code]],NSUnderlyingErrorKey:failure}]:[self error:@"SDK 拒绝 CDN 偏好配置，请查看 SDK 错误日志。"];
            return NO;
        }
    }@catch(NSException *exception){if(error)*error=[self error:@"SDK CDN 配置调用失败，请使用 SDK 自动线路。"];return NO;}
    NSError *readError=nil;NSDictionary *actual=[self readPreference:&readError];
    if([actual isEqualToDictionary:preference])return YES;
    if(error)*error=readError?:[self error:@"SDK CDN 配置回读不一致，未确认切换成功。"];return NO;
}
- (NSString *)URLForRoute:(NSDictionary *)route error:(NSError **)error {
    if(![route isKindOfClass:NSDictionary.class]){if(error)*error=[self error:@"线路配置格式无效。"];return nil;}
    NSString *provider=[route[@"provider"] isKindOfClass:NSString.class]?route[@"provider"]:@"";
    NSString *raw=[route[@"url"] isKindOfClass:NSString.class]?route[@"url"]:@"";
    NSURLComponents *url=nil;@try{if(raw.length<=8192)url=[NSURLComponents componentsWithString:raw];}@catch(NSException *exception){}
    NSCharacterSet *invalidProvider=[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"] invertedSet];
    NSInteger defaultPort=[url.scheme.lowercaseString isEqual:@"https"]?443:80;
    if(!provider.length||provider.length>64||[provider rangeOfCharacterFromSet:invalidProvider].location!=NSNotFound||!url.host.length||!url.URL||url.user.length||url.password.length||![@[@"http",@"https"] containsObject:url.scheme.lowercaseString]||(url.port&&url.port.integerValue!=defaultPort)){
        if(error)*error=[self error:@"线路缺少有效的 HTTP/HTTPS 来源和节点标识，未切换播放。"];return nil;
    }
    return raw;
}
- (BOOL)applyRoute:(NSDictionary *)route error:(NSError **)error {
    NSString *raw=[self URLForRoute:route error:error];
    if(!raw)return NO;
    NSURLComponents *url=[NSURLComponents componentsWithString:raw];
    NSString *provider=[route[@"provider"] lowercaseString];
    if(![self canWritePreference:error])return NO;
    NSError *failure=nil;NSDictionary *previous=[self readPreference:&failure];
    if(!previous){if(error)*error=failure;return NO;}
    if(!self.defaultPreference)self.defaultPreference=previous;
    // The bundled SDK expects a dictionary and a host string, not an array,
    // CNPlayerHlsCdnInfoItem, URL or numeric cdn_vip. Provider is a config label.
    NSMutableDictionary *preference=[previous mutableCopy];preference[@"cdn_code"]=provider.lowercaseString;preference[@"cdn_name"]=provider.uppercaseString;preference[@"cdn_vip"]=url.host.lowercaseString;
    self.overrideMayBeActive=YES;
    if([self writePreference:preference error:&failure]){self.requestedPreference=preference;return YES;}
    NSError *rollbackError=nil;
    if([self writePreference:previous error:&rollbackError])self.overrideMayBeActive=![previous isEqualToDictionary:self.defaultPreference];
    else failure=[self error:@"CDN 配置失败且未确认恢复原值，请先选择 SDK 自动线路；若仍失败请重启 App。"];
    if(error)*error=failure;return NO;
}
- (BOOL)restoreDefault:(NSError **)error {
    if(!self.overrideMayBeActive)return YES;
    if(!self.defaultPreference){if(error)*error=[self error:@"缺少原始 CDN 配置，无法确认恢复。请重启 App。"];return NO;}
    if(![self writePreference:self.defaultPreference error:error])return NO;
    self.overrideMayBeActive=NO;self.requestedPreference=nil;return YES;
}
+ (NSString *)observedCDNDescriptionForPlayer:(id)player {
    @try {
        id item=[player valueForKey:@"p_cdn"];id raw=[item valueForKey:@"cdn_vip"];NSString *host=[raw isKindOfClass:NSString.class]?raw:nil;
        if(!host.length||host.length>8192)return @"未知（SDK 未返回实际节点）";
        NSURLComponents *url=[NSURLComponents componentsWithString:[host containsString:@"://"]?host:[@"https://" stringByAppendingString:host]];
        return url.host.length?url.host:@"未知（SDK 节点格式不支持）";
    }@catch(NSException *exception){return @"未知（SDK 未返回实际节点）";}
}
@end
