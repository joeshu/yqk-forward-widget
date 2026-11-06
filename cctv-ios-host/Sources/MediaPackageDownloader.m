#import "MediaPackageDownloader.h"
#import "MediaPackageImporter.h"
#import "ServiceStore.h"
#import <CommonCrypto/CommonDigest.h>

typedef NS_ENUM(NSUInteger, PackageDownloadPhase) { PackageChecksum, PackageScript, PackageConfigChecksum, PackageConfig };
static NSString *PackageMD5(NSData *data) {
    unsigned char digest[CC_MD5_DIGEST_LENGTH];CC_MD5(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hash=[NSMutableString string];for(NSUInteger i=0;i<sizeof(digest);i++)[hash appendFormat:@"%02x",digest[i]];return hash;
}
static BOOL PackageLooksLikeHTML(NSData *data) {
    if(!data.length)return NO;
    NSUInteger length=MIN(data.length,(NSUInteger)2048);
    NSString *text=[[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0,length)] encoding:NSUTF8StringEncoding];
    if(!text)return NO;
    if([text hasPrefix:@"\uFEFF"])text=[text substringFromIndex:1];
    NSString *prefix=[[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    return [prefix hasPrefix:@"<!doctype html"]||[prefix hasPrefix:@"<html"]||[prefix hasPrefix:@"<head"]||[prefix hasPrefix:@"<body"];
}
static NSDictionary<NSString *,NSString *> *PackageSafeHeaders(id value) {
    if(![value isKindOfClass:NSDictionary.class])return @{};
    NSRegularExpression *namePattern=[NSRegularExpression regularExpressionWithPattern:@"^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,128}$" options:0 error:NULL];
    NSSet *blocked=[NSSet setWithArray:@[@"host",@"content-length",@"connection",@"transfer-encoding",@"keep-alive",@"upgrade"]];
    NSMutableDictionary *result=[NSMutableDictionary dictionary];NSUInteger count=0;
    for(id rawName in value){if(count++>=24)break;id rawValue=value[rawName];if(![rawName isKindOfClass:NSString.class]||![rawValue isKindOfClass:NSString.class])continue;NSString *name=rawName,*text=rawValue;NSRange range=NSMakeRange(0,name.length);if(!name.length||name.length>128||text.length>4096||[namePattern numberOfMatchesInString:name options:0 range:range]!=1||[blocked containsObject:name.lowercaseString]||[text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]].location!=NSNotFound)continue;result[name]=text;}
    return result.copy;
}
static BOOL PackageIsForADMYqkSourceURL(NSURL *sourceURL) {
    return [sourceURL.host.lowercaseString isEqual:@"raw.githubusercontent.com"]&&[sourceURL.path.lowercaseString isEqual:@"/joeshu/for-adm/master/cctvhost/yqk.js"];
}
static NSData *PackageAdaptForADMYqkSource(NSData *data,NSError **error) {
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if(!text||![text containsString:@"id: \"joeshu.yqk\""]||![text containsString:@"async function apiRequest(path, params, budget)"]){
        if(error)*error=[NSError errorWithDomain:@"CCTVHostImport" code:31 userInfo:@{NSLocalizedDescriptionKey:@"For-ADM 一起看脚本与站点地址不匹配，已停止导入。"}];return nil;
    }
    if([text containsString:@"function yqkRequestTimeout(budget,fallback)"]&&[text containsString:@"timeout:yqkRequestTimeout(budget,12000)"]&&[text containsString:@"timeout:yqkRequestTimeout(budget,15000)"]&&[text containsString:@"await apiBases(false,budget)"]&&[text containsString:@"await apiBases(true,budget)"]&&[text containsString:@"params.checkBudget==null?30:params.checkBudget"])return data;
    NSArray<NSDictionary<NSString *,NSString *> *> *replacements=@[
        @{@"old":@"{name:\"checkBudget\",title:\"线路检查预算\",description:\"默认15秒，可选8/15/30秒；到时停止后续检查。当前请求的超时由客户端控制，可能超过此预算。\",type:\"enumeration\",value:\"15\",enumOptions:[{title:\"8秒（较快）\",value:\"8\"},{title:\"15秒（推荐）\",value:\"15\"},{title:\"30秒（更多检查）\",value:\"30\"}]}",@"new":@"{name:\"checkBudget\",title:\"线路检查预算\",description:\"默认30秒，可选8/15/30秒；到时停止后续检查。当前请求超时会受检查预算约束。\",type:\"enumeration\",value:\"30\",enumOptions:[{title:\"8秒（较快）\",value:\"8\"},{title:\"15秒\",value:\"15\"},{title:\"30秒（推荐）\",value:\"30\"}]}"},
        @{@"old":@"var seconds=Number(params.checkBudget==null?15:params.checkBudget)",@"new":@"var seconds=Number(params.checkBudget==null?30:params.checkBudget)"},
        @{@"old":@"async function apiBases(force)",@"new":@"async function apiBases(force,budget)"},
        @{@"old":@"function(){return discoverBases(force);}",@"new":@"function(){return discoverBases(force,budget);}"},
        @{@"old":@"async function discoverBases(force)",@"new":@"async function discoverBases(force,budget)"},
        @{@"old":@"CCTVHttp.get(YQK.site+\"/js/baseUrlList.js\", { headers: { Referer: YQK.site+\"/\" } })",@"new":@"CCTVHttp.get(YQK.site+\"/js/baseUrlList.js\", { timeout:budget?Math.min(20000,Math.max(1000,budget.deadline-Date.now())):12000, headers: { Referer: YQK.site+\"/\" } })"},
        @{@"old":@"var bases = await apiBases(), errors = [], preferred = await getStored(\"lastBase\");",@"new":@"var bases = await apiBases(false,budget), errors = [], preferred = await getStored(\"lastBase\");"},
        @{@"old":@"if (phase===1) bases=await apiBases(true);",@"new":@"if (phase===1) bases=await apiBases(true,budget);"},
        @{@"old":@"response = await CCTVHttp.post(bases[i]+path, body, { headers: {",@"new":@"response = await CCTVHttp.post(bases[i]+path, body, { timeout:budget?Math.min(20000,Math.max(1000,budget.deadline-Date.now())):15000, headers: {"},
        @{@"old":@"r=await CCTVHttp.get(url,{headers:headers});",@"new":@"r=await CCTVHttp.get(url,{timeout:budget?Math.min(20000,Math.max(1000,budget.deadline-Date.now())):15000,headers:headers});"}
    ];
    for(NSDictionary<NSString *,NSString *> *replacement in replacements){
        NSString *old=replacement[@"old"],*updated=replacement[@"new"];NSUInteger occurrences=[[text componentsSeparatedByString:old] count]-1;
        if(occurrences==1)text=[text stringByReplacingOccurrencesOfString:old withString:updated];
        else if(![text containsString:updated]){if(error)*error=[NSError errorWithDomain:@"CCTVHostImport" code:32 userInfo:@{NSLocalizedDescriptionKey:@"For-ADM 一起看的播放预算或网络超时协议已变化，未导入不兼容版本。"}];return nil;}
    }
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}
static NSData *PackageAdaptForADMSignedSource(NSData *data,NSURL *sourceURL,NSError **error) {
    if(![sourceURL.host.lowercaseString isEqual:@"raw.githubusercontent.com"])return data;
    if(PackageIsForADMYqkSourceURL(sourceURL))return PackageAdaptForADMYqkSource(data,error);
    if([sourceURL.path.lowercaseString isEqual:@"/joeshu/for-adm/master/cctvhost/dyls.js"]){
        NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if(!text||![text containsString:@"id:'joeshu.dyls'"]){
            if(error)*error=[NSError errorWithDomain:@"CCTVHostImport" code:31 userInfo:@{NSLocalizedDescriptionKey:@"For-ADM 电影猎手脚本与站点地址不匹配，已停止导入。"}];return nil;
        }
        if([text containsString:@"var direct=String(ep.parseUrl||ep.play_url||'').trim()"]&&[text containsString:@"async function dylProbeHls(url,headers)"]&&[text containsString:@"await dylProbeHls(safe,headers)"])return data;
        NSString *old=@"function dylNeedParse(ep,line){var value=line.need_to_parse??line.player_need_to_parse??ep.need_to_parse??ep.player_need_to_parse;if(value!=null&&value!=='')return value===true||value===1||String(value).toLowerCase()==='true'||String(value)==='1';return !ep.ready_to_play;}";
        NSString *updated=@"function dylNeedParse(ep,line){if(String(ep.parseUrl||'').trim())return false;var direct=String(ep.play_url||'');if(/^https?:\\/\\//i.test(direct)&&/\\.(?:m3u8|mp4)(?:[?#]|$)/i.test(direct))return false;var value=line.need_to_parse??line.player_need_to_parse??ep.need_to_parse??ep.player_need_to_parse;if(value!=null&&value!=='')return value===true||value===1||String(value).toLowerCase()==='true'||String(value)==='1';return !ep.ready_to_play;}";
        NSUInteger occurrences=[[text componentsSeparatedByString:old] count]-1;
        if(occurrences==1)text=[text stringByReplacingOccurrencesOfString:old withString:updated];
        else if(![text containsString:updated]){if(error)*error=[NSError errorWithDomain:@"CCTVHostImport" code:32 userInfo:@{NSLocalizedDescriptionKey:@"For-ADM 电影猎手播放协议已变化，未导入不兼容版本。"}];return nil;}
        NSString *oldResolver=@"async function dylResolve(id,line,episode){";
        NSString *newResolver=@"async function dylProbeHls(url,headers){var r=await CCTVHttp.get(url,{headers:headers||{}}),status=Number(r.statusCode||r.status||0),body=r.data;if(status!==200||typeof body!=='string'||body.length>1048576||!/^\\s*#EXTM3U(?:\\s|$)/.test(body))throw new Error('电影猎手 HLS 清单不可用');if(!/#EXT-X-STREAM-INF:/i.test(body)&&!body.split(/\\r?\\n/).some(function(line){line=line.trim();return line&&line.charAt(0)!=='#';}))throw new Error('电影猎手 HLS 清单为空');return url;}async function dylResolve(id,line,episode){";
        NSUInteger resolverOccurrences=[[text componentsSeparatedByString:oldResolver] count]-1;
        if(resolverOccurrences==1&&![text containsString:@"async function dylProbeHls(url,headers)"])text=[text stringByReplacingOccurrencesOfString:oldResolver withString:newResolver];
        else if(![text containsString:@"async function dylProbeHls(url,headers)"]){if(error)*error=[NSError errorWithDomain:@"CCTVHostImport" code:32 userInfo:@{NSLocalizedDescriptionKey:@"For-ADM 电影猎手播放流程已变化，未导入不兼容版本。"}];return nil;}
        NSString *oldReturn=@"return [{url:safe,name:line.name,headers:dylMediaHeaders(line)}];}";
        NSString *newReturn=@"var headers=dylMediaHeaders(line);if(/\\.m3u8(?:[?#]|$)/i.test(safe))await dylProbeHls(safe,headers);return [{url:safe,name:line.name,headers:headers}];}";
        NSUInteger returnOccurrences=[[text componentsSeparatedByString:oldReturn] count]-1;
        if(returnOccurrences==1)text=[text stringByReplacingOccurrencesOfString:oldReturn withString:newReturn];
        else if(![text containsString:@"await dylProbeHls(safe,headers)"]){if(error)*error=[NSError errorWithDomain:@"CCTVHostImport" code:32 userInfo:@{NSLocalizedDescriptionKey:@"For-ADM 电影猎手媒体校验流程已变化，未导入不兼容版本。"}];return nil;}
        return [text dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSDictionary *sourceIDs=@{@"/joeshu/for-adm/master/cctvhost/kkapp.js":@"kkapp",@"/joeshu/for-adm/master/cctvhost/ncat.js":@"ncat",@"/joeshu/for-adm/master/cctvhost/happ.js":@"happ"};
    NSString *sourceID=sourceIDs[sourceURL.path.lowercaseString];if(!sourceID.length)return data;
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if(!text||![text containsString:[NSString stringWithFormat:@"var Source={\"id\":\"%@\"",sourceID]]){
        if(error)*error=[NSError errorWithDomain:@"CCTVHostImport" code:31 userInfo:@{NSLocalizedDescriptionKey:@"For-ADM 三源脚本与站点地址不匹配，已停止导入。"}];return nil;
    }
    NSArray<NSDictionary<NSString *,NSString *> *> *replacements=@[
        @{@"old":@"var query=get?Object.keys(data).sort().filter(function(k){return data[k]!==''&&data[k]!=null;}).map(function(k){return k+'='+data[k]+'&';}).join(''):'';",@"new":@"var query=get?Object.keys(data).sort().filter(function(k){return data[k]!==''&&data[k]!=null;}).map(function(k){return k+'='+data[k];}).join('&'):'';"},
        @{@"old":@"var ts=String(Date.now()),sig=C.HmacSHA1(method+'|'+path+'|'+query+'|'+ts+'|'+session+'|',Source.signKey).toString(C.enc.Hex);",@"new":@"var signMethod=path==='/config/prod/appInit.html'?method:method.toLowerCase(),ts=String(Date.now()),sig=C.HmacSHA1(signMethod+'|'+path+'|'+query+'|'+ts+'|'+session+'|',Source.signKey).toString(C.enc.Hex);"},
        @{@"old":@"if(user&&user.id&&user.token){headers.userId=String(user.id);headers['x-token']=String(user.token);}",@"new":@"if(!get)headers['Content-Type']='application/json';if(user&&user.id&&user.token){headers.userId=String(user.id);headers['x-token']=String(user.token);}"},
        @{@"old":@"SiteAdapter.prototype.sessionApi=async function(path,params){await this.ensureGuest();return this.api(path,params,'logic','POST');};",@"new":@"SiteAdapter.prototype.sessionApi=async function(path,params){await this.ensureGuest();return this.api(path,params,'logic','GET');};"},
        @{@"old":@"var result=await adapter.play(vodId,line,selected),rows=siteArray(result&& (result.playUrls||result.urls));",@"new":@"var result=await adapter.play(vodId,line,selected),rows=Array.isArray(result)?result:siteArray(result&& (result.playUrls||result.urls));"},
        @{@"old":@"return {name:String(row.name||line.name||'原站线路'),url:url,playerType:'app',customHeaders:siteHeaders(row.customHeaders||row.headers||row.header)};",@"new":@"var headers=siteHeaders(row.customHeaders||row.headers||row.header);if(row.referrerPolicy!=='no-referrer'&&!headers.Referer&&!headers.referer)headers.Referer=Source.origin+'/';return {name:String(row.name||line.name||'原站线路'),url:url,playerType:'app',customHeaders:headers};"}
    ];
    for(NSDictionary<NSString *,NSString *> *replacement in replacements){
        NSString *old=replacement[@"old"],*updated=replacement[@"new"];NSUInteger occurrences=[[text componentsSeparatedByString:old] count]-1;
        if(occurrences==1)text=[text stringByReplacingOccurrencesOfString:old withString:updated];
        else if(![text containsString:updated]){if(error)*error=[NSError errorWithDomain:@"CCTVHostImport" code:32 userInfo:@{NSLocalizedDescriptionKey:@"For-ADM 三源脚本协议已变化，未导入不兼容版本。"}];return nil;}
    }
    NSString *imageHelper=
    @"var siteImageDomains=Object.create(null),siteImageDomainFlights=Object.create(null);\n"
    @"function siteHeaderValue(headers,name){if(!headers||typeof headers!=='object')return '';name=String(name||'').toLowerCase();var keys=Object.keys(headers);for(var i=0;i<keys.length;i++)if(String(keys[i]).toLowerCase()===name)return String(headers[keys[i]]||'');return '';}\n"
    @"async function sitePrepareImageDomains(value){if(!siteConfig)return;var samples=Object.create(null),visited=0;function visit(v,depth){if(depth>8||!v||typeof v!=='object'||visited++>1200)return;if(Array.isArray(v)){for(var i=0;i<Math.min(v.length,300);i++)visit(v[i],depth+1);return;}var path=String(siteGet(v,['imagePath','coverPath','vodPic','vod_pic'])||''),group=String(v.imageGroup||'');if(path.charAt(0)==='/'&&path.slice(0,2)!=='//'&&path.length<2048&&group&&!samples[group])samples[group]=path;Object.keys(v).slice(0,48).forEach(function(key){visit(v[key],depth+1);});}visit(value,0);var groupIDs=Object.keys(samples);await Promise.all(groupIDs.map(async function(groupID){var cached=siteImageDomains[groupID],cacheAge=cached&&cached.domain?1800000:60000;if(cached&&Date.now()-cached.time<cacheAge)return;var active=siteImageDomainFlights[groupID];if(active){try{await active;}catch(_){}return;}var flight=(async function(){var group=siteArray(siteConfig.groups).find(function(row){return String(row.id)===groupID;}),mirrors=siteArray(group&&group.url).map(function(row){return siteSafeURL(String(row&&row.domain||''));}).filter(Boolean).slice(0,9),selected='';for(var offset=0;offset<mirrors.length&&!selected;offset+=3){var probes=await Promise.all(mirrors.slice(offset,offset+3).map(async function(mirror){try{var base=mirror;while(base.charAt(base.length-1)==='/')base=base.slice(0,-1);var result=await CCTVHttp.get(base+samples[groupID],{buffer:1,timeout:3000,headers:{Referer:Source.origin+'/',Accept:'image/*'}}),status=Number(result.statusCode||result.status||0),headers=result.headers||{},contentType=siteHeaderValue(headers,'content-type').toLowerCase();return status>=200&&status<300&&contentType.indexOf('image/')===0&&siteHeaderValue(headers,'encrypted')!=='1'?mirror:'';}catch(_){return '';}}));selected=probes.find(function(mirror){return !!mirror;})||'';}siteImageDomains[groupID]={domain:selected,time:Date.now()};})();siteImageDomainFlights[groupID]=flight;try{await flight;}catch(_){siteImageDomains[groupID]={domain:'',time:Date.now()};}finally{if(siteImageDomainFlights[groupID]===flight)delete siteImageDomainFlights[groupID];}}));}\n";
    NSString *oldImageDomain=@"image=domains.length?domains[0].replace(/\\/$/,'')+'/'+path.replace(/^\\//,''):Source.origin+path;";
    NSString *newImageDomain=@"image=domains.length?String(siteImageDomains[String(row.imageGroup||'')]&&siteImageDomains[String(row.imageGroup||'')].domain||domains[0]).replace(/\\/$/,'')+'/'+path.replace(/^\\//,''):Source.origin+path;";
    NSUInteger imageDomainOccurrences=[[text componentsSeparatedByString:oldImageDomain] count]-1;
    if(imageDomainOccurrences==1)text=[text stringByReplacingOccurrencesOfString:oldImageDomain withString:newImageDomain];
    else if(![text containsString:newImageDomain]&&![text containsString:@"probe=siteImageDomains[String(row.imageGroup||'')]"]){if(error)*error=[NSError errorWithDomain:@"CCTVHostImport" code:32 userInfo:@{NSLocalizedDescriptionKey:@"For-ADM 三源封面地址协议已变化，未导入不兼容版本。"}];return nil;}
    NSString *oldAdapter=@"var adapter=new SiteAdapter();";
    NSUInteger adapterOccurrences=[[text componentsSeparatedByString:oldAdapter] count]-1;
    if(adapterOccurrences==1&&![text containsString:@"async function sitePrepareImageDomains(value)"])text=[text stringByReplacingOccurrencesOfString:oldAdapter withString:[imageHelper stringByAppendingString:oldAdapter]];
    else if(![text containsString:@"async function sitePrepareImageDomains(value)"]){if(error)*error=[NSError errorWithDomain:@"CCTVHostImport" code:32 userInfo:@{NSLocalizedDescriptionKey:@"For-ADM 三源封面探测入口已变化，未导入不兼容版本。"}];return nil;}
    NSArray<NSDictionary<NSString *,NSString *> *> *imageCallReplacements=@[
        @{@"old":@"async function loadHome(){return siteCards(await adapter.home());}",@"new":@"async function loadHome(){var data=await adapter.home();await sitePrepareImageDomains(data);return siteCards(data);}"},
        @{@"old":@"async function loadCatalog(p){p=p||{};var d=await adapter.category(p);return siteCards(d);}",@"new":@"async function loadCatalog(p){p=p||{};var d=await adapter.category(p);await sitePrepareImageDomains(d);return siteCards(d);}"},
        @{@"old":@"async function search(p){p=p||{};return siteCards(await adapter.search(p));}",@"new":@"async function search(p){p=p||{};var data=await adapter.search(p);await sitePrepareImageDomains(data);return siteCards(data);}"},
        @{@"old":@"var d=siteDetails[id]||await adapter.detail(id),lines=siteArray(d.playSources||d.playerList||d.lines).filter(function(x){return x&&x.needLogin!==true;});",@"new":@"var d=siteDetails[id]||await adapter.detail(id);await sitePrepareImageDomains(d);var lines=siteArray(d.playSources||d.playerList||d.lines).filter(function(x){return x&&x.needLogin!==true;});"}
    ];
    for(NSDictionary<NSString *,NSString *> *replacement in imageCallReplacements){NSString *old=replacement[@"old"],*updated=replacement[@"new"];NSUInteger occurrences=[[text componentsSeparatedByString:old] count]-1;if(occurrences==1)text=[text stringByReplacingOccurrencesOfString:old withString:updated];else if(![text containsString:updated]){if(error)*error=[NSError errorWithDomain:@"CCTVHostImport" code:32 userInfo:@{NSLocalizedDescriptionKey:@"For-ADM 三源封面加载流程已变化，未导入不兼容版本。"}];return nil;}}
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}
static BOOL PackageHeaderIsSensitive(NSString *name) {
    if(!name.length)return NO;
    NSString *compact=[[[name lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@""] stringByReplacingOccurrencesOfString:@"_" withString:@""];
    for(NSString *marker in @[@"authorization",@"cookie",@"token",@"apikey",@"secret",@"password",@"credential",@"signature",@"sign",@"session"])if([compact containsString:marker])return YES;
    return [compact hasSuffix:@"key"];
}
static BOOL PackageSameOrigin(NSURL *left,NSURL *right) {
    NSURLComponents *a=[NSURLComponents componentsWithURL:left resolvingAgainstBaseURL:NO],*b=[NSURLComponents componentsWithURL:right resolvingAgainstBaseURL:NO];if(!a||!b||![a.scheme.lowercaseString isEqual:b.scheme.lowercaseString]||![a.host.lowercaseString isEqual:b.host.lowercaseString])return NO;
    NSNumber *aPort=a.port?:([a.scheme.lowercaseString isEqual:@"https"]?@443:@80),*bPort=b.port?:([b.scheme.lowercaseString isEqual:@"https"]?@443:@80);return [aPort isEqual:bPort];
}
static BOOL PackageSameCredentialScope(NSURL *origin,NSURL *target) {
    if(PackageSameOrigin(origin,target))return YES;
    NSURLComponents *a=[NSURLComponents componentsWithURL:origin resolvingAgainstBaseURL:NO],*b=[NSURLComponents componentsWithURL:target resolvingAgainstBaseURL:NO];if(!a||!b||![a.scheme.lowercaseString isEqual:@"http"]||![b.scheme.lowercaseString isEqual:@"https"]||![a.host.lowercaseString isEqual:b.host.lowercaseString])return NO;
    NSNumber *aPort=a.port?:@80,*bPort=b.port?:@443;return [aPort isEqual:@80]&&[bPort isEqual:@443];
}
@interface MediaPackageDownloader () <NSURLSessionDataDelegate>
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic,strong) NSMutableData *body;
@property(nonatomic,strong) NSData *scriptData;
@property(nonatomic,strong) NSURL *originalURL;
@property(nonatomic,strong) NSURL *targetURL;
@property(nonatomic,strong) NSURL *effectiveURL;
@property(nonatomic,strong) NSURL *credentialOrigin;
@property(nonatomic,copy) NSDictionary<NSString *,NSString *> *requestHeaders;
@property(nonatomic,copy) NSString *checksum;
@property(nonatomic,copy) NSString *configChecksum;
@property(nonatomic,copy) NSString *configContentChecksum;
@property(nonatomic,copy) NSString *configurationState;
@property(nonatomic,copy) NSString *runtimeHint;
@property(nonatomic,copy) void (^completion)(NSDictionary *,NSError *);
@property(atomic) BOOL finished;
@property(nonatomic) PackageDownloadPhase phase;
@property(nonatomic) NSInteger responseStatus;
@property(nonatomic) NSInteger redirects;
@property(nonatomic) int64_t expectedBytes;
@property(nonatomic) NSTimeInterval lastProgressTime;
@property(nonatomic,copy) NSString *lastProgressStage;
@end
@implementation MediaPackageDownloader
- (NSError *)error:(NSString *)message {return [NSError errorWithDomain:@"CCTVHostImport" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];}
- (BOOL)validURL:(NSURL *)url {return url&&url.scheme.length&&[@[@"http",@"https"] containsObject:url.scheme.lowercaseString]&&url.host.length&&!url.user.length&&!url.password.length;}
- (NSUInteger)limit {return (self.phase==PackageChecksum||self.phase==PackageConfigChecksum)?4096:(self.phase==PackageConfig?65536:([self.targetURL.pathExtension.lowercaseString isEqual:@"zip"]?24:8)*1024*1024);}
- (NSString *)stage {return @[@"读取资源校验值",@"下载主脚本 / 资源包",@"检查配套配置校验值",@"下载配套配置"][(NSUInteger)self.phase];}
- (void)progress:(NSString *)stage {
    NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;BOOL stageChanged=![self.lastProgressStage isEqual:stage];if(!stageChanged&&self.lastProgressTime>0&&now-self.lastProgressTime<0.12)return;self.lastProgressTime=now;self.lastProgressStage=[stage copy];
    void(^callback)(NSString *,int64_t,int64_t)=[self.onProgress copy];int64_t received=self.body.length,expected=self.expectedBytes;
    if(callback)dispatch_async(dispatch_get_main_queue(),^{callback(stage,received,expected);});
}
- (void)importURL:(NSURL *)url completion:(void (^)(NSDictionary *,NSError *))completion {
    [self importURL:url headers:nil runtimeHint:nil completion:completion];
}
- (void)importURL:(NSURL *)url headers:(NSDictionary<NSString *,NSString *> *)headers completion:(void (^)(NSDictionary *,NSError *))completion {
    [self importURL:url headers:headers runtimeHint:nil completion:completion];
}
- (void)importURL:(NSURL *)url headers:(NSDictionary<NSString *,NSString *> *)headers runtimeHint:(NSString *)runtimeHint completion:(void (^)(NSDictionary *,NSError *))completion {
    self.runtimeHint=runtimeHint;
    self.completion=completion;NSMutableDictionary *safeHeaders=[PackageSafeHeaders(headers) mutableCopy];NSURLComponents *input=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];NSString *user=input.percentEncodedUser.stringByRemovingPercentEncoding?:@"",*password=input.percentEncodedPassword.stringByRemovingPercentEncoding?:@"";
    if(input.user.length||input.password.length){NSData *credentials=[[NSString stringWithFormat:@"%@:%@",user,password] dataUsingEncoding:NSUTF8StringEncoding];if(credentials.length){BOOL hasAuthorization=NO;for(NSString *name in safeHeaders)if([name caseInsensitiveCompare:@"Authorization"]==NSOrderedSame){hasAuthorization=YES;break;}if(!hasAuthorization)safeHeaders[@"Authorization"]=[@"Basic " stringByAppendingString:[credentials base64EncodedStringWithOptions:0]];}input.user=nil;input.password=nil;url=input.URL;}
    self.originalURL=url;self.targetURL=url;self.configurationState=@"not_applicable";self.requestHeaders=PackageSafeHeaders(safeHeaders);self.credentialOrigin=url;
    if(![self validURL:url]){[self finish:nil error:[self error:@"请输入有效的 HTTP/HTTPS 资源文件地址"]];return;}
    self.phase=[url.pathExtension.lowercaseString isEqual:@"md5"]?PackageChecksum:PackageScript;
    if(self.phase==PackageChecksum){NSURLComponents *c=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];c.path=c.path.stringByDeletingPathExtension;self.targetURL=c.URL;}
    // A short checksum URL may redirect to the conventional index.js.md5 form;
    // validate the resolved script extension after reading the final checksum.
    if(self.phase!=PackageChecksum && ![@[@"js",@"mjs",@"cjs",@"py",@"zip"] containsObject:self.targetURL.pathExtension.lowercaseString]){[self finish:nil error:[self error:@"链接须指向 JS、Python、ZIP 或对应的 .md5 校验文件"]];return;}
    NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;configuration.URLCache=nil;configuration.HTTPCookieStorage=nil;configuration.timeoutIntervalForRequest=20;configuration.timeoutIntervalForResource=60;
    NSOperationQueue *queue=[NSOperationQueue new];queue.maxConcurrentOperationCount=1;
    self.session=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:queue];[self begin:url];
}
- (void)begin:(NSURL *)url {
    if(self.finished)return;self.body=[NSMutableData data];self.responseStatus=0;self.redirects=0;self.expectedBytes=-1;self.lastProgressTime=0;self.lastProgressStage=nil;
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];BOOL canSendCredentials=PackageSameCredentialScope(self.credentialOrigin,url);for(NSString *name in self.requestHeaders){if(PackageHeaderIsSensitive(name)&&!canSendCredentials)continue;[request setValue:self.requestHeaders[name] forHTTPHeaderField:name];}
    self.task=[self.session dataTaskWithRequest:request];[self progress:self.stage];[self.task resume];
}
- (NSURL *)configURL:(BOOL)checksum {
    NSURLComponents *c=[NSURLComponents componentsWithURL:self.effectiveURL resolvingAgainstBaseURL:NO];
    c.path=[c.path.stringByDeletingLastPathComponent stringByAppendingPathComponent:checksum?@"index.config.js.md5":@"index.config.js"];c.fragment=nil;return c.URL;
}
- (void)cancel {[self finish:nil error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];}
- (void)finish:(NSDictionary *)service error:(NSError *)error {
    @synchronized(self){if(self.finished)return;self.finished=YES;}
    [self.session invalidateAndCancel];self.session=nil;self.task=nil;self.body=nil;self.scriptData=nil;
    void (^callback)(NSDictionary *,NSError *)=self.completion;self.completion=nil;self.onProgress=nil;
    if(callback)dispatch_async(dispatch_get_main_queue(),^{callback(service,error);});
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    if(self.finished||task!=self.task){completion(NSURLSessionResponseCancel);return;}
    self.responseStatus=[response isKindOfClass:NSHTTPURLResponse.class]?((NSHTTPURLResponse *)response).statusCode:0;self.expectedBytes=response.expectedContentLength;
    BOOL optional=self.phase==PackageConfigChecksum||self.phase==PackageConfig;
    BOOL missing=optional&&self.responseStatus==404;
    BOOL valid=missing||(self.responseStatus==200&&response.expectedContentLength<=(long long)self.limit);
    if(self.phase==PackageScript&&self.responseStatus==200)self.effectiveURL=response.URL;
    // A redirected checksum describes the script beside the final checksum URL.
    if(self.phase==PackageChecksum&&self.responseStatus==200){NSURLComponents *c=[NSURLComponents componentsWithURL:response.URL resolvingAgainstBaseURL:NO];if([c.path.pathExtension.lowercaseString isEqual:@"md5"]){c.path=c.path.stringByDeletingPathExtension;self.targetURL=c.URL;}}
    completion(valid&&!missing?NSURLSessionResponseAllow:NSURLSessionResponseCancel);
    if(!valid)[self finish:nil error:[self error:[NSString stringWithFormat:@"%@失败：HTTP %ld，或响应超过大小上限",self.stage,(long)self.responseStatus]]];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if(self.finished||task!=self.task)return;
    if(self.body.length+data.length>self.limit){[task cancel];[self finish:nil error:[self error:[self.stage stringByAppendingString:@"超过大小上限"]]];return;}
    [self.body appendData:data];[self progress:self.stage];
}
- (NSString *)readChecksum {
    NSString *text=[[NSString alloc] initWithData:self.body encoding:NSUTF8StringEncoding];
    text=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray *parts=[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];NSString *hash=parts.firstObject;
    return hash.length==32&&[hash rangeOfString:@"^[0-9a-fA-F]{32}$" options:NSRegularExpressionSearch].location!=NSNotFound?hash.lowercaseString:nil;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if(self.finished||task!=self.task)return;BOOL missing=(self.phase==PackageConfigChecksum||self.phase==PackageConfig)&&self.responseStatus==404;
    if(error&&!(missing&&error.code==NSURLErrorCancelled)){[self finish:nil error:error];return;}
    if(self.phase==PackageChecksum||self.phase==PackageConfigChecksum){
        BOOL config=self.phase==PackageConfigChecksum;NSString *hash=self.responseStatus==404?nil:[self readChecksum];
        if(self.responseStatus!=404&&PackageLooksLikeHTML(self.body)){[self finish:nil error:[self error:config?@"配套配置校验地址返回了 HTML 网页，请检查资源权限或登录状态":@"资源校验地址返回了 HTML 网页，不是 MD5 校验文件"]];return;}
        if(self.responseStatus!=404&&!hash){[self finish:nil error:[self error:config?@"配套配置 MD5 格式无效":@"资源 MD5 校验文件格式无效"]];return;}
        if(config){self.configChecksum=hash;if(hash)[self progress:@"配套配置 MD5 校验值已读取"];self.phase=PackageConfig;[self begin:[self configURL:NO]];}
        else{self.checksum=hash;if(![@[@"js",@"mjs",@"cjs",@"py",@"zip"] containsObject:self.targetURL.pathExtension.lowercaseString]){[self finish:nil error:[self error:@"MD5 地址最终没有指向受支持的 JS、Python 或 ZIP 文件"]];return;}if(hash)[self progress:@"资源 MD5 校验值已读取"];self.phase=PackageScript;[self begin:self.targetURL];}return;
    }
    if(self.phase==PackageConfig){
        if(self.responseStatus==404){if(self.configChecksum){[self finish:nil error:[self error:@"配置校验文件存在，但对应配置文件缺失，未安装"]];return;}self.configurationState=@"missing_using_defaults";[self install:@{}];return;}
        if(PackageLooksLikeHTML(self.body)){[self finish:nil error:[self error:@"配套配置地址返回了 HTML 网页，不是配置文件；请检查权限或登录状态"]];return;}
        if(!self.body.length||![[NSString alloc] initWithData:self.body encoding:NSUTF8StringEncoding]){[self finish:nil error:[self error:@"配套配置不是有效 UTF-8 文件"]];return;}
        if(self.configChecksum&&![PackageMD5(self.body) isEqual:self.configChecksum]){[self finish:nil error:[self error:@"配套配置与 MD5 校验值不一致，未安装"]];return;}
        [self progress:self.configChecksum?@"配套配置 MD5 校验通过":@"配套配置没有 MD5 · 未验证来源完整性"];
        self.configContentChecksum=PackageMD5(self.body);
        self.configurationState=self.configChecksum?@"verified":@"downloaded_without_checksum";
        [self install:@{@"index.config.js":[self.body copy]}];return;
    }
    if(PackageLooksLikeHTML(self.body)){[self finish:nil error:[self error:@"资源地址返回了 HTML 网页而非脚本或 ZIP；请检查直链、访问权限或登录状态"]];return;}
    if(self.checksum&&![PackageMD5(self.body) isEqual:self.checksum]){[self finish:nil error:[self error:@"资源与 MD5 校验值不一致，未安装"]];return;}
    [self progress:self.checksum?@"主资源 MD5 校验通过":@"来源没有 MD5 · 未验证来源完整性"];
    self.scriptData=[self.body copy];NSError *adapterError=nil;NSData *adapted=PackageAdaptForADMSignedSource(self.scriptData,self.effectiveURL?:self.originalURL,&adapterError);if(!adapted){[self finish:nil error:adapterError];return;}self.scriptData=adapted;
    NSString *text=[@[@"js",@"mjs",@"cjs"] containsObject:self.targetURL.pathExtension.lowercaseString]?[[NSString alloc] initWithData:self.scriptData encoding:NSUTF8StringEncoding]:nil;
    BOOL catpaw=[text containsString:@"/config"]&&[text containsString:@"/spider"]&&([text containsString:@"catServerFactory"]||[text containsString:@"createService"]||[text containsString:@"serverFactory"]);
    if(catpaw){self.phase=PackageConfigChecksum;[self begin:[self configURL:YES]];return;}
    [self install:@{}];
}
- (void)install:(NSDictionary<NSString *,NSData *> *)companions {
    if(self.finished)return;self.lastProgressTime=0;[self progress:@"检查资源入口、运行时与协议"];
    NSError *error=nil;NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];NSFileManager *fm=NSFileManager.defaultManager;
    [fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error];NSString *path=[directory stringByAppendingPathComponent:self.targetURL.lastPathComponent];NSDictionary *service=nil;
    if(!error&&[self.scriptData writeToFile:path options:NSDataWritingAtomic error:&error])service=[MediaPackageImporter importFile:[NSURL fileURLWithPath:path] companionFiles:companions runtimeHint:self.runtimeHint error:&error];
    [fm removeItemAtPath:directory error:NULL];
    if(self.finished){if(service)[ServiceStore remove:service[@"id"]];return;}
    if(service){[self progress:@"识别完成 · 保存到本机资源库"];NSMutableDictionary *saved=[service mutableCopy];saved[@"url"]=self.originalURL.absoluteString;if(self.requestHeaders.count)saved[@"importHeaders"]=self.requestHeaders;
        if(PackageIsForADMYqkSourceURL(self.effectiveURL?:self.originalURL)){NSMutableDictionary *manifest=[saved[@"manifest"] mutableCopy]?:[NSMutableDictionary dictionary];NSMutableDictionary *options=[manifest[@"options"] mutableCopy]?:[NSMutableDictionary dictionary];options[@"playTimeoutMs"]=@60000;manifest[@"options"]=options;saved[@"manifest"]=manifest;}
        if([@[@"index",@"main"] containsObject:[service[@"name"] lowercaseString]])saved[@"name"]=[NSString stringWithFormat:@"%@ · %@",self.originalURL.host,[service[@"protocol"] isEqual:@"catpaw-http"]?@"猫源":service[@"name"]];saved[@"downloadChecksum"]=self.checksum?:@"";saved[@"configDownloadChecksum"]=self.configChecksum?:@"";saved[@"configContentChecksum"]=self.configContentChecksum?:@"";saved[@"configurationState"]=self.configurationState;service=saved;}
    [self finish:service error:error];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    BOOL valid=task==self.task&&++self.redirects<=5&&[self validURL:request.URL];
    if([response.URL.scheme.lowercaseString isEqual:@"https"]&&[request.URL.scheme.lowercaseString isEqual:@"http"])valid=NO;
    BOOL sameOrigin=valid&&PackageSameOrigin(response.URL,request.URL),sameHostUpgrade=valid&&!sameOrigin&&[self.credentialOrigin.scheme.lowercaseString isEqual:@"http"]&&[request.URL.scheme.lowercaseString isEqual:@"https"]&&PackageSameCredentialScope(self.credentialOrigin,response.URL)&&PackageSameCredentialScope(self.credentialOrigin,request.URL);
    if(valid&&!sameOrigin&&!sameHostUpgrade){NSMutableURLRequest *safe=[request mutableCopy];for(NSString *name in safe.allHTTPHeaderFields?:@{})if(PackageHeaderIsSensitive(name))[safe setValue:nil forHTTPHeaderField:name];request=safe;}
    else if(sameHostUpgrade){NSMutableURLRequest *safe=[request mutableCopy];for(NSString *name in self.requestHeaders)if(PackageHeaderIsSensitive(name))[safe setValue:self.requestHeaders[name] forHTTPHeaderField:name];request=safe;}
    if(self.phase==PackageConfig||self.phase==PackageConfigChecksum){NSURL *base=self.effectiveURL;valid=valid&&[request.URL.scheme.lowercaseString isEqual:base.scheme.lowercaseString]&&[request.URL.host.lowercaseString isEqual:base.host.lowercaseString]&&[(request.URL.port?:@0) isEqual:(base.port?:@0)];}
    completion(valid?request:nil);if(!valid)[self finish:nil error:[self error:@"重定向次数过多，或配套配置跳转到其他来源"]];
}
@end
