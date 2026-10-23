#import "ServiceStore.h"
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
+ (NSArray<NSDictionary *> *)services {
    NSMutableArray *rows =
        [[NSUserDefaults.standardUserDefaults arrayForKey:@"pythonServices"] ?: @[] mutableCopy];
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
    if([service[@"id"] isEqual:@"builtin-yangshipin-js"])return [NSBundle.mainBundle pathForResource:@"yangshipin-js" ofType:@"py"];
    if ([service[@"builtin"] boolValue])
        return [NSBundle.mainBundle pathForResource:@"ysp-live" ofType:@"py"];
    return [[self directory]
        stringByAppendingPathComponent:[service[@"id"] stringByAppendingPathExtension:@"py"]];
}
+ (NSString *)codePath:(NSDictionary *)service {
    if([service[@"id"] isEqual:@"builtin-yangshipin-js"])return [NSBundle.mainBundle pathForResource:@"yangshipin.bundle" ofType:@"js"];
    return [self scriptPath:service];
}
+ (void)save:(NSDictionary *)service {
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
