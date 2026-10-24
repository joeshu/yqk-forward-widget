#import "ServiceStore.h"
static BOOL ServiceRelativePath(NSString *path){
    if(![path isKindOfClass:NSString.class]||!path.length||[path hasPrefix:@"/"]||[path containsString:@"\\"]||[path containsString:@":"])return NO;
    for(NSString *part in path.pathComponents)if([part isEqual:@".."]||[part isEqual:@"."])return NO;
    return [path rangeOfString:[NSString stringWithFormat:@"%C",(unichar)0]].location==NSNotFound;
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
