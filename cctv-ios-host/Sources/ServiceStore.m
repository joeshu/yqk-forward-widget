#import "ServiceStore.h"
#import "ProfileStore.h"
static BOOL ServiceRelativePath(NSString *path){
    if(![path isKindOfClass:NSString.class]||!path.length||[path hasPrefix:@"/"]||[path containsString:@"\\"]||[path containsString:@":"])return NO;
    for(NSString *part in path.pathComponents)if([part isEqual:@".."]||[part isEqual:@"."])return NO;
    return [path rangeOfString:[NSString stringWithFormat:@"%C",(unichar)0]].location==NSNotFound;
}
static BOOL ServiceValidPlaylistPath(id value){
    if(![value isKindOfClass:NSString.class])return NO;NSString *path=[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [path isEqual:value]&&path.length>0&&path.length<128&&[path hasPrefix:@"/"]&&![path hasPrefix:@"//"]&&![path containsString:@".."]&&![path containsString:@"?"]&&![path containsString:@"#"]&&![path containsString:@"\\"]&&![path containsString:@":"]&&![path containsString:@"{"]&&![path containsString:@"}"]&&![path containsString:@"<"]&&![path containsString:@">"]&&[path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound&&[path rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location==NSNotFound;
}
static NSString *ServiceCodeWithoutComments(NSString *source){
    if(![source isKindOfClass:NSString.class]||source.length>2*1024*1024)return nil;
    NSMutableString *routeSource=[NSMutableString string];BOOL inBlockComment=NO;
    for(NSString *line in [source componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]){
        NSString *code=line;
        if(inBlockComment){NSRange close=[code rangeOfString:@"*/"];if(close.location==NSNotFound)continue;code=[code substringFromIndex:NSMaxRange(close)];inBlockComment=NO;}
        NSRange open=[code rangeOfString:@"/*"];
        if(open.location!=NSNotFound){NSRange close=[code rangeOfString:@"*/" options:0 range:NSMakeRange(NSMaxRange(open),code.length-NSMaxRange(open))];if(close.location==NSNotFound){code=[code substringToIndex:open.location];inBlockComment=YES;}else code=[[code substringToIndex:open.location]stringByAppendingString:[code substringFromIndex:NSMaxRange(close)]];}
        NSString *trimmed=[code stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if([trimmed hasPrefix:@"#"]||[trimmed hasPrefix:@"//"])continue;
        [routeSource appendString:code];[routeSource appendString:@"\n"];
    }
    return routeSource;
}
@implementation ServiceStore
+ (NSString *)directory {
    NSString *d =
        [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"Services"];
    [NSFileManager.defaultManager createDirectoryAtPath:d
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
    return d;
}
+ (NSDictionary *)resolvedService:(NSDictionary *)service {
    NSString *identifier=service[@"id"];
    if(!ServiceRelativePath(identifier)||identifier.pathComponents.count!=1||[service[@"builtin"] boolValue])return service;
    NSString *base=[[self directory] stringByAppendingPathComponent:identifier];
    NSMutableDictionary *resolved=[service mutableCopy];
    NSString *bundledID=[service[@"bundledResourceID"] isKindOfClass:NSString.class]?service[@"bundledResourceID"]:@"";
    BOOL isBundledHongguo=[bundledID isEqualToString:@"builtin-hongguo-python"]||[bundledID isEqualToString:@"builtin-hongguo-node"];
    NSDictionary *manifest=[resolved[@"manifest"] isKindOfClass:NSDictionary.class]?resolved[@"manifest"]:nil;
    if(manifest){
        NSMutableDictionary *updated=nil;
        if([manifest[@"runtime"] isEqual:@"python"]&&![manifest[@"moduleType"] isEqual:@"script"]){updated=[manifest mutableCopy];updated[@"moduleType"]=@"script";}
        if(isBundledHongguo){
            NSArray *caps=@[@"home",@"category",@"search",@"detail",@"play",@"proxy"];
            if(![resolved[@"capabilities"] isEqual:caps])resolved[@"capabilities"]=caps;
            if(![manifest[@"capabilities"] isEqual:caps]){if(!updated)updated=[manifest mutableCopy];updated[@"capabilities"]=caps;}
            NSDictionary *opts=[manifest[@"options"] isKindOfClass:NSDictionary.class]?manifest[@"options"]:@{};
            if([opts[@"playTimeoutMs"] integerValue]<120000){if(!updated)updated=[manifest mutableCopy];NSMutableDictionary *newOpts=[opts mutableCopy];newOpts[@"playTimeoutMs"]=@120000;updated[@"options"]=newOpts;}
        }
        if(updated)resolved[@"manifest"]=updated;
    }
    for(NSString *key in @[@"packageRoot",@"archivePath"]){
        NSString *relativeKey=[key isEqual:@"packageRoot"]?@"packageRelativePath":@"archiveRelativePath";
        NSString *relative=service[relativeKey],*stored=service[key];
        if(!ServiceRelativePath(relative)){
            relative=nil;
            if([stored isKindOfClass:NSString.class]&&[stored hasPrefix:[base stringByAppendingString:@"/"]])relative=[stored substringFromIndex:base.length+1];
            else if([stored isKindOfClass:NSString.class]){
                // Rebase only this service's imported files, never arbitrary
                // paths supplied by a package or another service's ID.
                NSString *marker=[NSString stringWithFormat:@"/Library/Application Support/Services/%@/",identifier];
                NSRange range=[stored rangeOfString:marker options:NSBackwardsSearch];
                if(range.location!=NSNotFound)relative=[stored substringFromIndex:NSMaxRange(range)];
            }
        }
        if(ServiceRelativePath(relative)){resolved[relativeKey]=relative;resolved[key]=[base stringByAppendingPathComponent:relative];}
    }
    return resolved;
}
+ (NSArray<NSDictionary *> *)services {
    NSMutableArray *rows =
        [[NSUserDefaults.standardUserDefaults arrayForKey:@"pythonServices"] ?: @[] mutableCopy];
    BOOL pathsChanged=NO;
    NSMutableSet *usedPorts=[NSMutableSet setWithObjects:@8767,@18770,nil];
    for(NSInteger index=(NSInteger)rows.count-1;index>=0;index--){
        NSDictionary *row=rows[(NSUInteger)index];if(![row isKindOfClass:NSDictionary.class])continue;
        if(![row[@"builtin"] boolValue]){
            NSString *entryPath=[self codePath:row];
            NSDictionary *attrs=entryPath.length?[NSFileManager.defaultManager attributesOfItemAtPath:entryPath error:NULL]:nil;
            if(attrs&&[attrs[NSFileSize] unsignedLongLongValue]>0&&[attrs[NSFileSize] unsignedLongLongValue]<=4096){
                NSData *entryData=[NSData dataWithContentsOfFile:entryPath options:NSDataReadingMappedIfSafe error:NULL];
                NSString *entryText=entryData?[[NSString alloc] initWithData:entryData encoding:NSUTF8StringEncoding]:nil;
                if([entryText containsString:@"self._engine = csp_adapter.AppVideoEngine('"]||[entryText containsString:@"home: async function(){ return { categories: [{ id: '1', name: '精选' }], items: [] }; }"]){
                    NSString *sid=[row[@"id"] isKindOfClass:NSString.class]?row[@"id"]:@"";
                    if(ServiceRelativePath(sid)&&sid.pathComponents.count==1){
                        [NSFileManager.defaultManager removeItemAtPath:[[self directory] stringByAppendingPathComponent:sid] error:NULL];
                    }
                    [rows removeObjectAtIndex:(NSUInteger)index];
                    pathsChanged=YES;
                }
            }
        }
    }
    for(NSUInteger index=0;index<rows.count;index++){
        NSDictionary *row=rows[index];if(![row isKindOfClass:NSDictionary.class])continue;
        NSMutableDictionary *resolved=[[self resolvedService:row] mutableCopy];
        NSInteger port=[resolved[@"port"] integerValue];
        if(![resolved[@"builtin"] boolValue]){
            if([self isMediaService:resolved]&&(port<1024||port>65535||[usedPorts containsObject:@(port)])){
                NSInteger nextPort=18780;while([usedPorts containsObject:@(nextPort)]&&nextPort<65535)nextPort++;
                resolved[@"port"]=@(nextPort);port=nextPort;
            }
            if(port>=1&&port<=65535)[usedPorts addObject:@(port)];
        }
        if(![resolved isEqual:row]){rows[index]=resolved.copy;pathsChanged=YES;}
    }
    if(pathsChanged)[NSUserDefaults.standardUserDefaults setObject:rows forKey:@"pythonServices"];
    BOOL found = NO;
    for (NSDictionary *s in rows)
        if ([s[@"id"] isEqualToString:@"builtin-ysp"])
            found = YES;
    if (!found)
        [rows insertObject:@{
            @"id" : @"builtin-ysp",
            @"name" : @"YSP Live",
            @"port" : @8767,
            @"builtin" : @YES,
            @"arguments" : @"",
            @"lan" : @NO
        }
                   atIndex:0];
    BOOL jsFound=NO;
    for(NSDictionary *s in rows)if([s[@"id"] isEqual:@"builtin-yangshipin-js"])jsFound=YES;
    if(!jsFound)[rows insertObject:@{@"id":@"builtin-yangshipin-js",@"name":@"央视频 JS",@"port":@18770,@"builtin":@YES,@"engine":@"javascript",@"arguments":@"",@"lan":@NO} atIndex:MIN((NSUInteger)1,rows.count)];
    return rows;
}
+ (NSString *)scriptPath:(NSDictionary *)service {
    if([self isMediaService:service])return [NSBundle.mainBundle pathForResource:@"media-service" ofType:@"py"];
    if([service[@"manifest"] isKindOfClass:NSDictionary.class])return [self codePath:service];
    if([service[@"id"] isEqual:@"builtin-yangshipin-js"])return [NSBundle.mainBundle pathForResource:@"yangshipin-js" ofType:@"py"];
    if ([service[@"builtin"] boolValue])
        return [NSBundle.mainBundle pathForResource:@"ysp-live" ofType:@"py"];
    return [[self directory]
        stringByAppendingPathComponent:[service[@"id"] stringByAppendingPathExtension:@"py"]];
}
+ (NSString *)codePath:(NSDictionary *)service {
    service=[self resolvedService:service];
    if([service[@"manifest"] isKindOfClass:NSDictionary.class]){
        NSString *entry=service[@"manifest"][@"entry"];if(!ServiceRelativePath(entry))return nil;
        NSString *target=[service[@"packageRoot"] stringByAppendingPathComponent:entry];
        NSString *bundledID=[service[@"bundledResourceID"] isKindOfClass:NSString.class]?service[@"bundledResourceID"]:@"";
        NSDictionary *bundleMap=@{@"builtin-hongguo-python":@[@"hongguo-python",@"py"],@"builtin-hongguo-node":@[@"hongguo-node",@"js"],@"zen.keke.rex.stream":@[@"zen-keke-stream",@"js"],@"builtin-webox-4kvm":@[@"webox-4kvm",@"js"],@"builtin-webox-hstream":@[@"webox-hstream",@"js"],@"builtin-webox-guazi":@[@"webox-guazi",@"js"],@"builtin-webox-rou":@[@"webox-rou",@"js"],@"builtin-webox-one":@[@"webox-one",@"js"]};
        NSArray *bundleSpec=bundleMap[bundledID];
        if(bundleSpec.count==2&&target.length){
            static NSMutableSet<NSString *> *syncedTargets;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{ syncedTargets = [NSMutableSet set]; });
            NSString *syncKey = [NSString stringWithFormat:@"%@|%@", bundledID, target];
            BOOL alreadySynced = NO;
            @synchronized(syncedTargets) {
                alreadySynced = [syncedTargets containsObject:syncKey] && [NSFileManager.defaultManager fileExistsAtPath:target];
            }
            if(!alreadySynced){
                NSString *bundlePath=[NSBundle.mainBundle pathForResource:bundleSpec[0] ofType:bundleSpec[1] inDirectory:@"BuiltinMedia"];
                if(bundlePath.length){
                    NSData *bundleData=[NSData dataWithContentsOfFile:bundlePath options:NSDataReadingMappedIfSafe error:NULL];
                    NSData *installedData=[NSData dataWithContentsOfFile:target options:NSDataReadingMappedIfSafe error:NULL];
                    if(bundleData.length&&(![installedData isEqualToData:bundleData])){
                        [NSFileManager.defaultManager createDirectoryAtPath:target.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
                        [bundleData writeToFile:target options:NSDataWritingAtomic error:NULL];
                    }
                    if(bundleData.length){
                        @synchronized(syncedTargets) { [syncedTargets addObject:syncKey]; }
                    }
                }
            }
        }
        return target;
    }
    if([service[@"id"] isEqual:@"builtin-yangshipin-js"])return [NSBundle.mainBundle pathForResource:@"yangshipin.bundle" ofType:@"js"];
    return [self scriptPath:service];
}
+ (BOOL)isMediaService:(NSDictionary *)service {return [service[@"manifest"] isKindOfClass:NSDictionary.class] && ![service[@"protocol"] isEqual:@"python-http"];}
+ (BOOL)isVODMediaService:(NSDictionary *)service {
    if(![self isMediaService:service])return NO;
    NSArray *capabilities=[service[@"capabilities"] isKindOfClass:NSArray.class]?service[@"capabilities"]:nil;
    if(!capabilities.count)capabilities=[service[@"manifest"][@"capabilities"] isKindOfClass:NSArray.class]?service[@"manifest"][@"capabilities"]:@[];
    // Preserve legacy generic media packages that predate capability metadata.
    if(!capabilities.count)return YES;
    NSSet *vodCapabilities=[NSSet setWithArray:@[@"vod",@"home",@"category",@"search",@"detail",@"play"]];
    for(id capability in capabilities)if([capability isKindOfClass:NSString.class]&&[vodCapabilities containsObject:capability])return YES;
    return NO;
}
+ (BOOL)isLiveMediaService:(NSDictionary *)service {
    if([service[@"protocol"] isEqual:@"nanotv-service-v2"])return YES;
    NSArray *capabilities=[service[@"capabilities"] isKindOfClass:NSArray.class]?service[@"capabilities"]:([service[@"manifest"][@"capabilities"] isKindOfClass:NSArray.class]?service[@"manifest"][@"capabilities"]:@[]);
    return [capabilities containsObject:@"live"];
}
+ (NSString *)resourceKindForService:(NSDictionary *)service subscriptionURL:(NSString *)subscriptionURL {
    BOOL live=[self isLiveMediaService:service]||subscriptionURL.length>0;
    BOOL vod=[self isVODMediaService:service];
    NSArray *capabilities=[service[@"capabilities"] isKindOfClass:NSArray.class]?service[@"capabilities"]:([service[@"manifest"][@"capabilities"] isKindOfClass:NSArray.class]?service[@"manifest"][@"capabilities"]:@[]);
    if(!capabilities.count && live)vod=NO;
    return live&&vod?@"both":(live?@"live":(vod?@"vod":@"unknown"));
}
+ (NSInteger)inferredPortInCode:(NSString *)source {
    NSString *code=ServiceCodeWithoutComments(source);
    if(!code.length)return 0;
    NSArray<NSString *> *patterns=@[
        @"(?is)add_argument\\s*\\(\\s*['\\\"](?:--port|-p|port)['\\\"][^\\n)]*?default\\s*=\\s*['\\\"]?(\\d{4,5})['\\\"]?",
        @"(?is)(?:os\\.environ\\.get|os\\.getenv)\\s*\\(\\s*['\\\"](?:CCTVHOST_PORT|PORT)['\\\"]\\s*,\\s*['\\\"]?(\\d{4,5})['\\\"]?\\s*\\)",
        @"(?is)process\\.env\\.(?:CCTVHOST_PORT|PORT)\\s*(?:\\|\\||\\?\\?)\\s*['\\\"]?(\\d{4,5})['\\\"]?",
        @"(?is)(?:ThreadingHTTPServer|HTTPServer|TCPServer|ThreadingTCPServer)\\s*\\(\\s*\\([^,)]+,\\s*(\\d{4,5})\\s*\\)",
        @"(?is)(?:app|server|uvicorn|bottle|web)\\.(?:run|run_app|listen)\\s*\\([^\\n)]*?(?:port\\s*=\\s*|:\\s*|(?:^|[,\\(\\s]))(\\d{4,5})\\b",
        @"(?m)^\\s*(?:DEFAULT_PORT|SERVER_PORT|LISTEN_PORT|PORT|port)\\s*=\\s*(\\d{4,5})\\b"
    ];
    for(NSString *pattern in patterns){
        NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
        NSTextCheckingResult *match=[re firstMatchInString:code options:0 range:NSMakeRange(0,code.length)];
        if(match&&match.numberOfRanges>1){
            NSInteger port=[[code substringWithRange:[match rangeAtIndex:1]] integerValue];
            if(port>=1024&&port<=65535)return port;
        }
    }
    return 0;
}
+ (NSString *)portRecognitionSummaryForService:(NSDictionary *)service {
    if(![service isKindOfClass:NSDictionary.class])return @"未配置端口";
    NSInteger port=[service[@"port"] integerValue];
    if([service[@"builtin"] boolValue])return [NSString stringWithFormat:@"内置固定端口 %ld · 宿主直连",(long)port];
    if([self isMediaService:service])return [NSString stringWithFormat:@"宿主网关端口 %ld · 自动桥接",(long)port];
    NSInteger inferred=[service[@"inferredPort"] integerValue];
    if(inferred<1024){
        NSString *entry=[self codePath:service];NSDictionary *attrs=entry.length?[NSFileManager.defaultManager attributesOfItemAtPath:entry error:NULL]:nil;
        if(entry.length&&[attrs[NSFileSize] unsignedLongLongValue]<=2*1024*1024){
            NSData *data=[NSData dataWithContentsOfFile:entry options:NSDataReadingMappedIfSafe error:NULL];
            NSString *source=data?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;
            inferred=[self inferredPortInCode:source];
        }
    }
    NSString *args=[service[@"arguments"] isKindOfClass:NSString.class]?service[@"arguments"]:@"";
    if([args containsString:@"{port}"]){
        if(inferred>=1024&&inferred!=port)return [NSString stringWithFormat:@"启动参数注入 %ld（脚本默认 %ld）",(long)port,(long)inferred];
        return [NSString stringWithFormat:@"启动参数注入 %ld · 宿主接管",(long)port];
    }
    if(inferred>=1024){
        if(inferred==port)return [NSString stringWithFormat:@"脚本声明端口 %ld · 宿主对齐",(long)inferred];
        return [NSString stringWithFormat:@"宿主重映射 %ld（脚本默认 %ld）",(long)port,(long)inferred];
    }
    return [NSString stringWithFormat:@"宿主接管端口 %ld（CCTVHOST_PORT）",(long)port];
}
+ (NSString *)inferredPlaylistPathInCode:(NSString *)source {
    if(![source isKindOfClass:NSString.class]||source.length>2*1024*1024)return nil;
    // Only infer a URL when it appears in an actual route declaration or a
    // request-path comparison. A mention in help text or an example is not a
    // reliable endpoint and must not silently become a subscription.
    NSMutableString *routeSource=[NSMutableString string];BOOL inBlockComment=NO;
    for(NSString *line in [source componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]){
        NSString *code=line;
        if(inBlockComment){NSRange close=[code rangeOfString:@"*/"];if(close.location==NSNotFound)continue;code=[code substringFromIndex:NSMaxRange(close)];inBlockComment=NO;}
        NSRange open=[code rangeOfString:@"/*"];
        if(open.location!=NSNotFound){NSRange close=[code rangeOfString:@"*/" options:0 range:NSMakeRange(NSMaxRange(open),code.length-NSMaxRange(open))];if(close.location==NSNotFound){code=[code substringToIndex:open.location];inBlockComment=YES;}else code=[[code substringToIndex:open.location]stringByAppendingString:[code substringFromIndex:NSMaxRange(close)]];}
        NSString *trimmed=[code stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if([trimmed hasPrefix:@"#"]||[trimmed hasPrefix:@"//"])continue;
        [routeSource appendString:code];[routeSource appendString:@"\n"];
    }
    NSString *lower=routeSource.lowercaseString;
    BOOL m3uEvidence=[lower containsString:@"#extm3u"]||[lower containsString:@"#extinf"]||[lower containsString:@"m3u"]||[lower containsString:@"playlist"];
    if(!m3uEvidence)return nil;
    NSString *routePattern=@"(?is)(?:@[a-z_][a-z0-9_.]*\\.(?:route|get|post|put)\\s*\\(|(?:[a-z_$][a-z0-9_$]*(?:\\.[a-z_$][a-z0-9_$]*)*)\\.(?:route|get|post|put|addroute|add_route|addget|add_get)\\s*\\(|(?:add_url_rule|add_get|add_route)\\s*\\(|(?:(?:self|request)\\.)?path\\s*(?:==|in)\\s*|(?:route|playlist(?:_path)?|m3u_path)\\s*=\\s*)['\\\"](/[^'\\\"?#\\\\\\s]{1,126})['\\\"]";
    NSError *error=nil;NSRegularExpression *routes=[NSRegularExpression regularExpressionWithPattern:routePattern options:0 error:&error];if(!routes||error)return nil;
    NSArray<NSTextCheckingResult *> *matches=[routes matchesInString:routeSource options:0 range:NSMakeRange(0,routeSource.length)];
    NSSet *tokens=[NSSet setWithArray:@[@"m3u",@"playlist",@"live",@"channel",@"iptv",@"tv"]];
    NSArray *preferred=@[@"/all.m3u",@"/all.m3u8",@"/m3u",@"/playlist.m3u",@"/playlist.m3u8",@"/live.m3u",@"/live.m3u8",@"/channels.m3u",@"/tv.m3u",@"/iptv.m3u",@"/index.m3u"];
    NSMutableArray<NSString *> *candidates=[NSMutableArray array];
    for(NSTextCheckingResult *match in matches){NSString *path=[routeSource substringWithRange:[match rangeAtIndex:1]];if(ServiceValidPlaylistPath(path)&&![candidates containsObject:path])[candidates addObject:path];}
    for(NSString *preferredPath in preferred)if([candidates containsObject:preferredPath])return preferredPath;
    for(NSString *path in candidates){NSString *candidate=path.lowercaseString;BOOL likely=NO;for(NSString *token in tokens)if([candidate containsString:token]){likely=YES;break;}if(likely)return path;}
    return nil;
}
+ (NSString *)inferredEPGPathInCode:(NSString *)source {
    NSString *routeSource=ServiceCodeWithoutComments(source);
    if(!routeSource.length)return nil;
    NSString *lower=routeSource.lowercaseString;
    BOOL epgEvidence=[lower containsString:@"epg"]||[lower containsString:@"xmltv"]||[lower containsString:@"x-tvg-url"]||[lower containsString:@"url-tvg"]||[lower containsString:@"tvg-url"]||[lower containsString:@"<programme"];
    if(!epgEvidence)return nil;
    NSString *routePattern=@"(?is)(?:@[a-z_][a-z0-9_.]*\\.(?:route|get|post|put)\\s*\\(|(?:[a-z_$][a-z0-9_$]*(?:\\.[a-z_$][a-z0-9_$]*)*)\\.(?:route|get|post|put|addroute|add_route|addget|add_get)\\s*\\(|(?:add_url_rule|add_get|add_route)\\s*\\(|(?:(?:self|request)\\.)?path\\s*(?:==|in)\\s*|(?:epg(?:_path|_route)?|xmltv(?:_path|_route)?|guide_path)\\s*=\\s*|(?:x-tvg-url|url-tvg|tvg-url|epg-url)\\s*=\\s*['\\\"]?(?:https?://[^'\\\"\\s/]+)?)['\\\"]?(/[^'\\\"?#\\\\\\s,;]{1,126})";
    NSError *error=nil;NSRegularExpression *routes=[NSRegularExpression regularExpressionWithPattern:routePattern options:0 error:&error];if(!routes||error)return nil;
    NSArray<NSTextCheckingResult *> *matches=[routes matchesInString:routeSource options:0 range:NSMakeRange(0,routeSource.length)];
    NSSet *tokens=[NSSet setWithArray:@[@"epg",@"xmltv",@"guide",@"tv.xml",@".xml"]];
    NSArray *preferred=@[@"/epg.xml",@"/epg.xml.gz",@"/xmltv.xml",@"/epg",@"/tv.xml",@"/guide.xml"];
    NSMutableArray<NSString *> *candidates=[NSMutableArray array];
    for(NSTextCheckingResult *match in matches){
        NSString *path=[routeSource substringWithRange:[match rangeAtIndex:1]];
        if(ServiceValidPlaylistPath(path)&&![candidates containsObject:path])[candidates addObject:path];
    }
    for(NSString *preferredPath in preferred)if([candidates containsObject:preferredPath])return preferredPath;
    for(NSString *path in candidates){
        NSString *candidate=path.lowercaseString;
        if([candidate hasSuffix:@".m3u"]||[candidate hasSuffix:@".m3u8"])continue;
        for(NSString *token in tokens)if([candidate containsString:token])return path;
    }
    return nil;
}
+ (NSString *)playlistPathForService:(NSDictionary *)service {
    if(![service isKindOfClass:NSDictionary.class])return nil;
    if([service[@"builtin"] boolValue]&&[service[@"id"] isEqual:@"builtin-ysp"])return @"/all.m3u";
    BOOL nanoTVLive=[service[@"protocol"] isEqual:@"nanotv-service-v2"];
    if(nanoTVLive)return @"/all.m3u";
    BOOL mediaHost=[self isMediaService:service];
    BOOL pythonHTTP=[service[@"protocol"] isEqual:@"python-http"];
    BOOL legacyPythonHTTP=![service[@"manifest"] isKindOfClass:NSDictionary.class]&&[service[@"engine"] isEqual:@"python"];
    if(!mediaHost&&!pythonHTTP&&!legacyPythonHTTP)return nil;
    NSString *configured=service[@"playlistPath"];
    BOOL configuredPath=ServiceValidPlaylistPath(configured);
    BOOL explicitPath=configuredPath&&([service[@"playlistPathSource"] isEqual:@"manual"]||[service[@"playlistPathSource"] isEqual:@"detected"]||![service[@"playlistPathSource"] isEqual:@"inferred"]);
    if(mediaHost){if(explicitPath)return configured;if([self isLiveMediaService:service])return @"/all.m3u";return nil;}
    if(configuredPath)return configured;
    // A Python Spider is hosted by the media API, but that API does not expose
    // the script's own Flask/FastAPI routes. Inferring one of those routes as
    // a live subscription would create a broken loopback M3U source. Only
    // Python HTTP services (and legacy unmanifested Python services) can have
    // their entry file interpreted as a local HTTP server declaration.
    if(![service[@"engine"] isEqual:@"python"])return nil;
    NSString *entry=[self codePath:service];NSDictionary *attributes=entry.length?[NSFileManager.defaultManager attributesOfItemAtPath:entry error:NULL]:nil;
    if(!entry.length||[attributes[NSFileSize] unsignedLongLongValue]>2*1024*1024)return nil;
    NSData *data=[NSData dataWithContentsOfFile:entry options:NSDataReadingMappedIfSafe error:NULL];NSString *source=data?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;
    return [self inferredPlaylistPathInCode:source];
}
+ (NSString *)epgPathForService:(NSDictionary *)service {
    if(![service isKindOfClass:NSDictionary.class])return nil;
    BOOL mediaHost=[self isMediaService:service];
    BOOL pythonHTTP=[service[@"protocol"] isEqual:@"python-http"];
    BOOL legacyPythonHTTP=![service[@"manifest"] isKindOfClass:NSDictionary.class]&&[service[@"engine"] isEqual:@"python"];
    if(!mediaHost&&!pythonHTTP&&!legacyPythonHTTP&&![service[@"protocol"] isEqual:@"nanotv-service-v2"])return nil;
    NSString *configured=service[@"epgPath"];
    if(ServiceValidPlaylistPath(configured))return configured;
    if(mediaHost)return nil;
    if(![service[@"engine"] isEqual:@"python"])return nil;
    NSString *entry=[self codePath:service];NSDictionary *attributes=entry.length?[NSFileManager.defaultManager attributesOfItemAtPath:entry error:NULL]:nil;
    if(!entry.length||[attributes[NSFileSize] unsignedLongLongValue]>2*1024*1024)return nil;
    NSData *data=[NSData dataWithContentsOfFile:entry options:NSDataReadingMappedIfSafe error:NULL];NSString *source=data?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;
    return [self inferredEPGPathInCode:source];
}
+ (NSArray<NSString *> *)epgPathCandidatesForService:(NSDictionary *)service {
    if(![service isKindOfClass:NSDictionary.class])return @[];
    BOOL mediaHost=[self isMediaService:service];
    BOOL pythonHTTP=[service[@"protocol"] isEqual:@"python-http"]||(![service[@"manifest"] isKindOfClass:NSDictionary.class]&&[service[@"engine"] isEqual:@"python"]);
    if(!mediaHost&&!pythonHTTP&&![service[@"protocol"] isEqual:@"nanotv-service-v2"])return @[];
    NSMutableOrderedSet<NSString *> *candidates=[NSMutableOrderedSet orderedSet];
    NSString *path=[self epgPathForService:service];
    if(path.length)[candidates addObject:path];
    for(NSString *candidate in @[@"/epg.xml",@"/xmltv.xml",@"/epg.xml.gz",@"/epg",@"/tv.xml",@"/guide.xml"]){
        if(ServiceValidPlaylistPath(candidate))[candidates addObject:candidate];
    }
    if(candidates.count>6)return [[candidates.array subarrayWithRange:NSMakeRange(0,6)] copy];
    return candidates.array.copy?:@[];
}
+ (NSArray<NSString *> *)playlistPathCandidatesForService:(NSDictionary *)service {
    if(![service isKindOfClass:NSDictionary.class])return @[];
    BOOL mediaHost=[self isMediaService:service];
    BOOL pythonHTTP=[service[@"protocol"] isEqual:@"python-http"]||(![service[@"manifest"] isKindOfClass:NSDictionary.class]&&[service[@"engine"] isEqual:@"python"]);
    if(!mediaHost&&!pythonHTTP&&![service[@"protocol"] isEqual:@"nanotv-service-v2"])return @[];
    NSString *path=[self playlistPathForService:service];NSMutableOrderedSet<NSString *> *candidates=[NSMutableOrderedSet orderedSet];
    if(path.length)[candidates addObject:path];
    BOOL explicitPath=path.length&&![service[@"playlistPathSource"] isEqual:@"inferred"]&&![service[@"playlistPathSource"] isEqual:@"detected"];
    if(explicitPath)return candidates.array.copy?:@[];
    // Manifest based Python/Node/JSC resources are served by the same
    // media-service host, whose live playlist route is fixed. Probe that
    // route even if an older package manifest forgot to declare "live";
    // only a non-empty parsed M3U will be saved or subscribed.
    if(mediaHost){if(!candidates.count)[candidates addObject:@"/all.m3u"];return candidates.array.copy?:@[];}
    for(NSString *candidate in @[@"/all.m3u",@"/all.m3u8",@"/m3u",@"/playlist.m3u",@"/live.m3u",@"/channels.m3u"]){
        if(ServiceValidPlaylistPath(candidate))[candidates addObject:candidate];
    }
    if(candidates.count>6)return [[candidates.array subarrayWithRange:NSMakeRange(0,6)] copy];
    return candidates.array.copy?:@[];
}
+ (NSString *)subscriptionURLForService:(NSDictionary *)service {
    NSInteger port=[service[@"port"] integerValue];NSString *path=[self playlistPathForService:service];if(port<1||port>65535||!path.length)return nil;
    return [NSString stringWithFormat:@"http://127.0.0.1:%ld%@",(long)port,path];
}
+ (void)associateLegacyLoopbackSubscriptionsForService:(NSDictionary *)service {
    NSString *identifier=[service[@"id"] isKindOfClass:NSString.class]?service[@"id"]:@"";NSInteger port=[service[@"port"] integerValue];if(!identifier.length||port<1||port>65535)return;
    NSSet *loopback=[NSSet setWithArray:@[@"127.0.0.1",@"localhost",@"::1"]];
    for(id rawSource in [NSUserDefaults.standardUserDefaults arrayForKey:@"subscriptions"]?:@[]){if(![ProfileStore isHTTP:rawSource])continue;NSString *source=rawSource;NSURLComponents *components=[NSURLComponents componentsWithString:source];NSString *host=components.host.lowercaseString;if(!components.URL||![loopback containsObject:host]||components.port.integerValue!=port)continue;NSDictionary *metadata=[ProfileStore metadata:source];if([metadata[@"managedServiceID"] isEqual:identifier])continue;if(metadata[@"managedServiceID"]&&![metadata[@"managedServiceID"] isEqual:identifier])continue;[ProfileStore update:source values:@{@"managedServiceID":identifier}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:source];}
}
+ (NSString *)rewrittenLoopbackURL:(NSString *)urlString forService:(NSDictionary *)service {
    if(![ProfileStore isHTTP:urlString])return nil;
    NSInteger port=[service[@"port"] integerValue];
    if(port<1||port>65535)return urlString;
    NSURLComponents *parts=[NSURLComponents componentsWithString:urlString];
    NSString *host=parts.host.lowercaseString;
    if(!parts||!([host isEqualToString:@"127.0.0.1"]||[host isEqualToString:@"localhost"]||[host isEqualToString:@"0.0.0.0"]||[host isEqualToString:@"::1"]))return urlString;
    parts.scheme=@"http";
    parts.host=@"127.0.0.1";
    parts.port=@(port);
    return parts.URL.absoluteString?:urlString;
}
+ (NSString *)epgURLForService:(NSDictionary *)service {
    NSString *explicit=service[@"epgURL"];if([ProfileStore isHTTP:explicit])return [self rewrittenLoopbackURL:explicit forService:service];
    NSInteger port=[service[@"port"] integerValue];if(port<1||port>65535)return nil;
    NSString *expected=[self subscriptionURLForService:service];
    NSArray *sources=[NSUserDefaults.standardUserDefaults arrayForKey:@"subscriptions"]?:@[];
    for(NSString *source in sources){
        if(!expected.length||![source isEqual:expected])continue;
        NSDictionary *metadata=[ProfileStore metadata:source];
        NSString *candidate=[metadata[@"epgURL"] isKindOfClass:NSString.class]&&[metadata[@"epgURL"] length]?metadata[@"epgURL"]:metadata[@"detectedEPGURL"];
        if([ProfileStore isHTTP:candidate])return [self rewrittenLoopbackURL:candidate forService:service];
    }
    // A manually configured XMLTV URL belongs to the service, not to its old
    // loopback port. Keep it available while the replacement playlist is being
    // checked, but never reuse an automatically detected URL from an old route.
    NSString *identifier=service[@"id"];
    for(NSString *source in sources){
        NSDictionary *metadata=[ProfileStore metadata:source];
        if([metadata[@"managedServiceID"] isEqual:identifier]&&[ProfileStore isHTTP:metadata[@"epgURL"]]){
            return [self rewrittenLoopbackURL:metadata[@"epgURL"] forService:service];
        }
    }
    if(expected.length){
        for(NSString *source in sources){
            NSDictionary *metadata=[ProfileStore metadata:source];
            if([metadata[@"managedServiceID"] isEqual:identifier]&&[ProfileStore isHTTP:metadata[@"detectedEPGURL"]]){
                return [self rewrittenLoopbackURL:metadata[@"detectedEPGURL"] forService:service];
            }
        }
        NSString *epgPath=[self epgPathForService:service];
        if(epgPath.length)return [NSString stringWithFormat:@"http://127.0.0.1:%ld%@",(long)port,epgPath];
    }
    return nil;
}
+ (void)save:(NSDictionary *)service {
    NSMutableDictionary *mutableService=[[self resolvedService:service] mutableCopy];
    NSMutableArray *rows = [[self services] mutableCopy];
    NSIndexSet *matches =
        [rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *row, NSUInteger index, BOOL *stop) {
          return [row[@"id"] isEqualToString:mutableService[@"id"]];
        }];
    [rows removeObjectsAtIndexes:matches];
    if(![mutableService[@"builtin"] boolValue]&&[self isMediaService:mutableService]){
        NSMutableSet *usedPorts=[NSMutableSet setWithObjects:@8767,@18770,nil];
        for(NSDictionary *row in rows)if(row[@"port"])[usedPorts addObject:row[@"port"]];
        NSInteger port=[mutableService[@"port"] integerValue];
        if(port<1024||port>65535||[usedPorts containsObject:@(port)]){
            NSInteger nextPort=18780;while([usedPorts containsObject:@(nextPort)]&&nextPort<65535)nextPort++;
            mutableService[@"port"]=@(nextPort);
        }
    }
    [rows addObject:mutableService.copy];
    [NSUserDefaults.standardUserDefaults setObject:rows forKey:@"pythonServices"];
}
+ (NSDictionary *)healthSnapshotForServiceIdentifier:(NSString *)identifier {
    if(!identifier.length)return @{};for(NSDictionary *service in [self services])if([service[@"id"] isEqual:identifier]){NSDictionary *snapshot=service[@"healthSnapshot"];return [snapshot isKindOfClass:NSDictionary.class]?snapshot:@{};}return @{};
}
+ (void)recordHealthSnapshot:(NSDictionary *)snapshot forServiceIdentifier:(NSString *)identifier {
    if(!identifier.length||![snapshot isKindOfClass:NSDictionary.class])return;NSMutableArray *rows=[[self services] mutableCopy];BOOL found=NO;
    for(NSUInteger i=0;i<rows.count;i++){NSDictionary *service=rows[i];if(![service[@"id"] isEqual:identifier])continue;NSMutableDictionary *updated=[service mutableCopy];NSMutableDictionary *clean=[NSMutableDictionary dictionary];for(NSString *key in @[@"status",@"result",@"httpStatus",@"channelCount",@"checkedAt",@"path"]){id value=snapshot[key];if(([value isKindOfClass:NSString.class]&&[value length]<=1024)||[value isKindOfClass:NSNumber.class])clean[key]=value;}updated[@"healthSnapshot"]=clean;rows[i]=updated;found=YES;break;}
    if(found)[NSUserDefaults.standardUserDefaults setObject:rows forKey:@"pythonServices"];
}
+ (NSDictionary *)replaceImportedService:(NSDictionary *)existing withService:(NSDictionary *)incoming error:(NSError **)error {
    NSString *identifier=existing[@"id"],*incomingID=incoming[@"id"];
    if(!ServiceRelativePath(identifier)||identifier.pathComponents.count!=1||!ServiceRelativePath(incomingID)||incomingID.pathComponents.count!=1||[identifier isEqual:incomingID]||[existing[@"builtin"] boolValue]||![incoming[@"manifest"] isKindOfClass:NSDictionary.class]){
        if(error)*error=[NSError errorWithDomain:@"CCTVHostImport" code:2 userInfo:@{NSLocalizedDescriptionKey:@"资源更新目标无效"}];return nil;}
    NSFileManager *fm=NSFileManager.defaultManager;NSString *base=[[self directory] stringByAppendingPathComponent:identifier],*source=[[self directory] stringByAppendingPathComponent:incomingID];
    NSDictionary *resolved=[self resolvedService:incoming];NSString *package=resolved[@"packageRoot"],*archive=resolved[@"archivePath"];
    if(![package hasPrefix:[source stringByAppendingString:@"/"]]||![fm fileExistsAtPath:[self codePath:resolved]]){if(error)*error=[NSError errorWithDomain:@"CCTVHostImport" code:3 userInfo:@{NSLocalizedDescriptionKey:@"新版资源文件不完整，保留原版"}];return nil;}
    NSString *relative=[@"versions" stringByAppendingPathComponent:incomingID],*destination=[base stringByAppendingPathComponent:relative];
    if(![fm createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]||![fm moveItemAtPath:source toPath:destination error:error])return nil;
    NSMutableDictionary *updated=[existing mutableCopy];[updated removeObjectForKey:@"healthSnapshot"];NSMutableDictionary *manifest=[incoming[@"manifest"] mutableCopy];
    if(existing[@"manifest"][@"options"])manifest[@"options"]=existing[@"manifest"][@"options"];
    NSMutableDictionary *previous=[existing mutableCopy];[previous removeObjectForKey:@"previousImport"];updated[@"previousImport"]=previous;
    for(NSString *key in @[@"engine",@"protocol",@"url",@"importHeaders",@"downloadChecksum",@"configDownloadChecksum",@"configContentChecksum",@"configurationState",@"updated",@"inferredPort"])if(incoming[key])updated[key]=incoming[key];
    BOOL runtimeChanged=![existing[@"engine"] isEqual:incoming[@"engine"]];
    BOOL inferredArguments=[existing[@"argumentsSource"] isEqual:@"inferred"];
    // A changed runtime cannot safely reuse flags from the old engine. On the
    // same runtime, refresh detected defaults but retain explicit user edits.
    if(runtimeChanged||inferredArguments){updated[@"arguments"]=incoming[@"arguments"]?:@"";updated[@"argumentsSource"]=incoming[@"argumentsSource"]?:@"inferred";}
    BOOL hasManualPlaylist=[existing[@"playlistPath"] isKindOfClass:NSString.class]&&[existing[@"playlistPath"] length]&&![existing[@"playlistPathSource"] isEqual:@"inferred"]&&![existing[@"playlistPathSource"] isEqual:@"detected"];
    if(!hasManualPlaylist){[updated removeObjectForKey:@"playlistPath"];[updated removeObjectForKey:@"playlistPathSource"];if([incoming[@"playlistPath"] isKindOfClass:NSString.class]&&[incoming[@"playlistPath"] length]){updated[@"playlistPath"]=incoming[@"playlistPath"];updated[@"playlistPathSource"]=incoming[@"playlistPathSource"]?:@"inferred";}}
    BOOL hasManualEPG=[existing[@"epgPath"] isKindOfClass:NSString.class]&&[existing[@"epgPath"] length]&&![existing[@"epgPathSource"] isEqual:@"inferred"]&&![existing[@"epgPathSource"] isEqual:@"detected"];
    if(!hasManualEPG){[updated removeObjectForKey:@"epgPath"];[updated removeObjectForKey:@"epgPathSource"];if([incoming[@"epgPath"] isKindOfClass:NSString.class]&&[incoming[@"epgPath"] length]){updated[@"epgPath"]=incoming[@"epgPath"];updated[@"epgPathSource"]=incoming[@"epgPathSource"]?:@"inferred";}}
    updated[@"manifest"]=manifest;[updated removeObjectForKey:@"capabilities"];
    updated[@"packageRelativePath"]=[relative stringByAppendingPathComponent:[package substringFromIndex:source.length+1]];updated[@"packageRoot"]=[base stringByAppendingPathComponent:updated[@"packageRelativePath"]];
    updated[@"archivePath"]=@"";[updated removeObjectForKey:@"archiveRelativePath"];
    if([archive hasPrefix:[source stringByAppendingString:@"/"]]){updated[@"archiveRelativePath"]=[relative stringByAppendingPathComponent:[archive substringFromIndex:source.length+1]];updated[@"archivePath"]=[base stringByAppendingPathComponent:updated[@"archiveRelativePath"]];}
    updated[@"status"]=@"已更新 · 待重新启动验证";[self save:updated];return [self resolvedService:updated];
}
+ (NSDictionary *)rollbackImportedService:(NSDictionary *)service error:(NSError **)error {
    NSDictionary *previous=service[@"previousImport"];
    if(![previous isKindOfClass:NSDictionary.class]||![previous[@"id"] isEqual:service[@"id"]]||![NSFileManager.defaultManager fileExistsAtPath:[self codePath:previous]]){if(error)*error=[NSError errorWithDomain:@"CCTVHostImport" code:4 userInfo:@{NSLocalizedDescriptionKey:@"没有可恢复的旧版代码，当前版本已保留"}];return nil;}
    NSMutableDictionary *restored=[[self resolvedService:previous] mutableCopy],*current=[service mutableCopy];[current removeObjectForKey:@"previousImport"];
    // Keep user changes made after updating; detected values belong to the
    // imported version and must roll back together with its code.
    for(NSString *key in @[@"name",@"port",@"lan",@"url"])if(service[key])restored[key]=service[key];
    if(![service[@"argumentsSource"] isEqual:@"inferred"]){if(service[@"arguments"])restored[@"arguments"]=service[@"arguments"];if(service[@"argumentsSource"])restored[@"argumentsSource"]=service[@"argumentsSource"];}
    if([service[@"playlistPath"] isKindOfClass:NSString.class]&&[service[@"playlistPath"] length]&&![service[@"playlistPathSource"] isEqual:@"inferred"]&&![service[@"playlistPathSource"] isEqual:@"detected"]){restored[@"playlistPath"]=service[@"playlistPath"];restored[@"playlistPathSource"]=service[@"playlistPathSource"]?:@"manual";}
    if([service[@"epgPath"] isKindOfClass:NSString.class]&&[service[@"epgPath"] length]&&![service[@"epgPathSource"] isEqual:@"inferred"]&&![service[@"epgPathSource"] isEqual:@"detected"]){restored[@"epgPath"]=service[@"epgPath"];restored[@"epgPathSource"]=service[@"epgPathSource"]?:@"manual";}
    if(service[@"manifest"][@"options"]){NSMutableDictionary *manifest=[restored[@"manifest"] mutableCopy];manifest[@"options"]=service[@"manifest"][@"options"];restored[@"manifest"]=manifest;}
    restored[@"previousImport"]=current;restored[@"status"]=@"已切回上一版 · 待启动验证";[self save:restored];return restored;
}
+ (void)remove:(NSString *)identifier {
    // identifier 直接拼路径删文件/目录：非单组件标识（如含 ../）会越界删除，
    // 先用 ServiceRelativePath + 单组件校验拦截。
    if(!ServiceRelativePath(identifier)||identifier.pathComponents.count!=1)return;
    if ([identifier isEqualToString:@"builtin-ysp"] || [identifier isEqualToString:@"builtin-yangshipin-js"])
        return;
    NSMutableArray *rows = [[self services] mutableCopy];
    [rows removeObjectsAtIndexes:[rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *s, NSUInteger i,
                                                                         BOOL *stop) {
            return [s[@"id"] isEqualToString:identifier];
          }]];
    [NSUserDefaults.standardUserDefaults setObject:rows forKey:@"pythonServices"];
    [NSFileManager.defaultManager
        removeItemAtPath:[[self directory]
                             stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"py"]]
                   error:NULL];
    [NSFileManager.defaultManager removeItemAtPath:[[self directory] stringByAppendingPathComponent:identifier] error:NULL];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:[@"CCTVJSStorage:" stringByAppendingString:identifier]];
}
+ (NSString *)dataDirectoryForService:(NSDictionary *)service error:(NSError **)error {
    NSString *identifier=service[@"id"];
    if(!ServiceRelativePath(identifier)||identifier.pathComponents.count!=1){if(error)*error=[NSError errorWithDomain:@"CCTVHostService" code:1 userInfo:@{NSLocalizedDescriptionKey:@"服务标识无效"}];return nil;}
    NSString *target=[[self directory] stringByAppendingPathComponent:identifier];
    NSFileManager *fm=NSFileManager.defaultManager;
    if([identifier isEqual:@"builtin-ysp"]){
        target=[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"ysp"];
        if(![fm createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:error])return nil;
        NSString *previous=[[self directory] stringByAppendingPathComponent:@"builtin-ysp"];
        for(NSString *name in [fm contentsOfDirectoryAtPath:previous error:NULL]){
            NSString *dest=[target stringByAppendingPathComponent:name];
            if(![fm fileExistsAtPath:dest]&&![fm copyItemAtPath:[previous stringByAppendingPathComponent:name] toPath:dest error:error])return nil;
        }
    }else if(![fm createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:error])return nil;
    return target;
}
+ (NSString *)activeIdentifier {
    return [NSUserDefaults.standardUserDefaults stringForKey:@"activePythonService"] ?: @"builtin-ysp";
}
@end
