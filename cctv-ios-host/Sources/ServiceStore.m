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
    NSDictionary *manifest=service[@"manifest"];
    if([manifest isKindOfClass:NSDictionary.class]&&[manifest[@"runtime"] isEqual:@"python"]&&![manifest[@"moduleType"] isEqual:@"script"]){NSMutableDictionary *updated=[manifest mutableCopy];updated[@"moduleType"]=@"script";resolved[@"manifest"]=updated;}
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
    for(NSUInteger index=0;index<rows.count;index++){NSDictionary *row=rows[index];if(![row isKindOfClass:NSDictionary.class])continue;NSDictionary *resolved=[self resolvedService:row];if(![resolved isEqual:row]){rows[index]=resolved;pathsChanged=YES;}}
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
    if([service[@"manifest"] isKindOfClass:NSDictionary.class]){NSString *entry=service[@"manifest"][@"entry"];if(!ServiceRelativePath(entry))return nil;return [service[@"packageRoot"] stringByAppendingPathComponent:entry];}
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
+ (NSString *)inferredPlaylistPathInCode:(NSString *)source {
    if(![source isKindOfClass:NSString.class]||source.length>2*1024*1024)return nil;
    // Only infer a URL when it appears in an actual route declaration or a
    // request-path comparison. A mention in help text or an example is not a
    // reliable endpoint and must not silently become a subscription.
    NSMutableString *routeSource=[NSMutableString string];
    for(NSString *line in [source componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]){NSString *trimmed=[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];if(![trimmed hasPrefix:@"#"])[routeSource appendString:line];[routeSource appendString:@"\n"];}
    NSString *lower=routeSource.lowercaseString;
    BOOL m3uEvidence=[lower containsString:@"#extm3u"]||[lower containsString:@"#extinf"]||[lower containsString:@"m3u"]||[lower containsString:@"playlist"];
    if(!m3uEvidence)return nil;
    NSString *routePattern=@"(?is)(?:@[a-z_][a-z0-9_.]*\\.(?:route|get|post|put)\\s*\\(|(?:add_url_rule|add_get|add_route)\\s*\\(|(?:(?:self|request)\\.)?path\\s*(?:==|in)\\s*|(?:route|playlist(?:_path)?|m3u_path)\\s*=\\s*)['\\\"](/[^'\\\"?#\\\\\\s]{1,126})['\\\"]";
    NSError *error=nil;NSRegularExpression *routes=[NSRegularExpression regularExpressionWithPattern:routePattern options:0 error:&error];if(!routes||error)return nil;
    NSArray<NSTextCheckingResult *> *matches=[routes matchesInString:routeSource options:0 range:NSMakeRange(0,routeSource.length)];
    NSSet *tokens=[NSSet setWithArray:@[@"m3u",@"playlist",@"live",@"channel",@"iptv",@"tv"]];
    NSArray *preferred=@[@"/all.m3u",@"/m3u",@"/playlist.m3u",@"/live.m3u",@"/channels.m3u"];
    NSMutableArray<NSString *> *candidates=[NSMutableArray array];
    for(NSTextCheckingResult *match in matches){NSString *path=[routeSource substringWithRange:[match rangeAtIndex:1]];if(ServiceValidPlaylistPath(path)&&![candidates containsObject:path])[candidates addObject:path];}
    for(NSString *preferredPath in preferred)if([candidates containsObject:preferredPath])return preferredPath;
    for(NSString *path in candidates){NSString *candidate=path.lowercaseString;BOOL likely=NO;for(NSString *token in tokens)if([candidate containsString:token]){likely=YES;break;}if(likely)return path;}
    return nil;
}
+ (NSString *)playlistPathForService:(NSDictionary *)service {
    if(![service isKindOfClass:NSDictionary.class])return nil;
    if([service[@"builtin"] boolValue]&&[service[@"id"] isEqual:@"builtin-ysp"])return @"/all.m3u";
    BOOL nanoTVLive=[service[@"protocol"] isEqual:@"nanotv-service-v2"];
    BOOL pythonHTTP=[service[@"protocol"] isEqual:@"python-http"];
    BOOL legacyPythonHTTP=![service[@"manifest"] isKindOfClass:NSDictionary.class]&&[service[@"engine"] isEqual:@"python"];
    if(!nanoTVLive&&!pythonHTTP&&!legacyPythonHTTP)return nil;
    NSString *declared=service[@"playlistPath"];
    if(ServiceValidPlaylistPath(declared))return nanoTVLive&&![declared isEqual:@"/all.m3u"]?nil:declared;
    if(nanoTVLive)return @"/all.m3u";
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
+ (NSString *)subscriptionURLForService:(NSDictionary *)service {
    NSInteger port=[service[@"port"] integerValue];NSString *path=[self playlistPathForService:service];if(port<1||port>65535||!path.length)return nil;
    return [NSString stringWithFormat:@"http://127.0.0.1:%ld%@",(long)port,path];
}
+ (void)associateLegacyLoopbackSubscriptionsForService:(NSDictionary *)service {
    NSString *identifier=[service[@"id"] isKindOfClass:NSString.class]?service[@"id"]:@"";NSInteger port=[service[@"port"] integerValue];if(!identifier.length||port<1||port>65535)return;
    NSSet *loopback=[NSSet setWithArray:@[@"127.0.0.1",@"localhost",@"::1"]];
    for(id rawSource in [NSUserDefaults.standardUserDefaults arrayForKey:@"subscriptions"]?:@[]){if(![ProfileStore isHTTP:rawSource])continue;NSString *source=rawSource;NSURLComponents *components=[NSURLComponents componentsWithString:source];NSString *host=components.host.lowercaseString;if(!components.URL||![loopback containsObject:host]||components.port.integerValue!=port)continue;NSDictionary *metadata=[ProfileStore metadata:source];if([metadata[@"managedServiceID"] isEqual:identifier])continue;if(metadata[@"managedServiceID"]&&![metadata[@"managedServiceID"] isEqual:identifier])continue;[ProfileStore update:source values:@{@"managedServiceID":identifier}];[NSNotificationCenter.defaultCenter postNotificationName:ProfileStoreMetadataDidChangeNotification object:source];}
}
+ (NSString *)epgURLForService:(NSDictionary *)service {
    NSString *explicit=service[@"epgURL"];if([ProfileStore isHTTP:explicit])return explicit;NSInteger port=[service[@"port"] integerValue];if(port<1||port>65535)return nil;
    NSString *expected=[self subscriptionURLForService:service];
    NSArray *sources=[NSUserDefaults.standardUserDefaults arrayForKey:@"subscriptions"]?:@[];
    for(NSString *source in sources){if(!expected.length||![source isEqual:expected])continue;NSDictionary *metadata=[ProfileStore metadata:source];NSString *candidate=[metadata[@"epgURL"] isKindOfClass:NSString.class]?metadata[@"epgURL"]:metadata[@"detectedEPGURL"];if([ProfileStore isHTTP:candidate])return candidate;}
    // A manually configured XMLTV URL belongs to the service, not to its old
    // loopback port. Keep it available while the replacement playlist is being
    // checked, but never reuse an automatically detected URL from an old route.
    NSString *identifier=service[@"id"];
    for(NSString *source in sources){NSDictionary *metadata=[ProfileStore metadata:source];if([metadata[@"managedServiceID"] isEqual:identifier]&&[ProfileStore isHTTP:metadata[@"epgURL"]])return metadata[@"epgURL"];}
    return nil;
}
+ (void)save:(NSDictionary *)service {
    service=[self resolvedService:service];
    NSMutableArray *rows = [[self services] mutableCopy];
    NSIndexSet *matches =
        [rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *row, NSUInteger index, BOOL *stop) {
          return [row[@"id"] isEqualToString:service[@"id"]];
        }];
    [rows removeObjectsAtIndexes:matches];
    [rows addObject:service];
    [NSUserDefaults.standardUserDefaults setObject:rows forKey:@"pythonServices"];
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
    NSMutableDictionary *updated=[existing mutableCopy];NSMutableDictionary *manifest=[incoming[@"manifest"] mutableCopy];
    if(existing[@"manifest"][@"options"])manifest[@"options"]=existing[@"manifest"][@"options"];
    NSMutableDictionary *previous=[existing mutableCopy];[previous removeObjectForKey:@"previousImport"];updated[@"previousImport"]=previous;
    for(NSString *key in @[@"engine",@"protocol",@"downloadChecksum",@"configDownloadChecksum",@"configContentChecksum",@"configurationState",@"updated"])if(incoming[key])updated[key]=incoming[key];
    BOOL runtimeChanged=![existing[@"engine"] isEqual:incoming[@"engine"]];
    BOOL inferredArguments=[existing[@"argumentsSource"] isEqual:@"inferred"];
    // A changed runtime cannot safely reuse flags from the old engine. On the
    // same runtime, refresh detected defaults but retain explicit user edits.
    if(runtimeChanged||inferredArguments){updated[@"arguments"]=incoming[@"arguments"]?:@"";updated[@"argumentsSource"]=incoming[@"argumentsSource"]?:@"inferred";}
    BOOL hasManualPlaylist=[existing[@"playlistPath"] isKindOfClass:NSString.class]&&[existing[@"playlistPath"] length]&&![existing[@"playlistPathSource"] isEqual:@"inferred"];
    if(!hasManualPlaylist){[updated removeObjectForKey:@"playlistPath"];[updated removeObjectForKey:@"playlistPathSource"];if([incoming[@"playlistPath"] isKindOfClass:NSString.class]&&[incoming[@"playlistPath"] length]){updated[@"playlistPath"]=incoming[@"playlistPath"];updated[@"playlistPathSource"]=incoming[@"playlistPathSource"]?:@"inferred";}}
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
    if([service[@"playlistPath"] isKindOfClass:NSString.class]&&[service[@"playlistPath"] length]&&![service[@"playlistPathSource"] isEqual:@"inferred"]){restored[@"playlistPath"]=service[@"playlistPath"];restored[@"playlistPathSource"]=service[@"playlistPathSource"]?:@"manual";}
    if(service[@"manifest"][@"options"]){NSMutableDictionary *manifest=[restored[@"manifest"] mutableCopy];manifest[@"options"]=service[@"manifest"][@"options"];restored[@"manifest"]=manifest;}
    restored[@"previousImport"]=current;restored[@"status"]=@"已切回上一版 · 待启动验证";[self save:restored];return restored;
}
+ (void)remove:(NSString *)identifier {
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
