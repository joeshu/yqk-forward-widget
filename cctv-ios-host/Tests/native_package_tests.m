#import "MediaPackageImporter.h"
#import "ServiceStore.h"
#import "MediaPackageDownloader.h"
#import <Foundation/Foundation.h>
#include <string.h>
int main(int argc,const char **argv){@autoreleasepool{
    if(argc==4 && (strcmp(argv[1],"--update")==0||strcmp(argv[1],"--update-manual")==0)){
        BOOL manual=strcmp(argv[1],"--update-manual")==0;
        NSError *error=nil;NSMutableDictionary *old=[[MediaPackageImporter importFile:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]] error:&error] mutableCopy];
        NSDictionary *incoming=[MediaPackageImporter importFile:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[3]]] error:&error];
        if(!old||!incoming)return 4;
        old[@"port"]=@19991;old[@"name"]=@"user-name";old[@"arguments"]=manual?@"--user-old":@"--inferred-old";old[@"argumentsSource"]=manual?@"manual":@"inferred";old[@"playlistPath"]=manual?@"/user.m3u":@"/inferred-old.m3u";old[@"playlistPathSource"]=manual?@"manual":@"inferred";NSMutableDictionary *manifest=[old[@"manifest"] mutableCopy];manifest[@"options"]=@{@"userChoice":@"keep"};old[@"manifest"]=manifest;[ServiceStore save:old];
        NSMutableDictionary *next=[incoming mutableCopy];next[@"arguments"]=@"--inferred-new";next[@"argumentsSource"]=@"inferred";next[@"playlistPath"]=@"/inferred-new.m3u";next[@"playlistPathSource"]=@"inferred";
        NSString *marker=[[[ServiceStore directory] stringByAppendingPathComponent:old[@"id"]] stringByAppendingPathComponent:@"fixture-account.json"];
        [@"account-data" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSString *before=[NSString stringWithContentsOfFile:[ServiceStore codePath:old] encoding:NSUTF8StringEncoding error:NULL];
        NSDictionary *updated=[ServiceStore replaceImportedService:old withService:next error:&error];
        NSDictionary *restored=updated?[ServiceStore rollbackImportedService:updated error:&error]:nil;
        NSString *after=restored?[NSString stringWithContentsOfFile:[ServiceStore codePath:restored] encoding:NSUTF8StringEncoding error:NULL]:nil;
        NSString *expectedUpdatedArguments=manual?@"--user-old":@"--inferred-new",*expectedUpdatedPlaylist=manual?@"/user.m3u":@"/inferred-new.m3u",*expectedRestoredArguments=manual?@"--user-old":@"--inferred-old",*expectedRestoredPlaylist=manual?@"/user.m3u":@"/inferred-old.m3u";
        NSDictionary *result=@{@"ok":@(updated&&restored),@"sameID":@([old[@"id"] isEqual:updated[@"id"]]),@"portKept":@([updated[@"port"] isEqual:@19991]),@"optionsKept":@([updated[@"manifest"][@"options"][@"userChoice"] isEqual:@"keep"]),@"accountKept":@([NSFileManager.defaultManager fileExistsAtPath:marker]),@"argumentsUpdatedCorrectly":@([updated[@"arguments"] isEqual:expectedUpdatedArguments]),@"playlistUpdatedCorrectly":@([updated[@"playlistPath"] isEqual:expectedUpdatedPlaylist]),@"rollbackRestoredCode":@(before&&[before isEqual:after]),@"rollbackRestoredArguments":@([restored[@"arguments"] isEqual:expectedRestoredArguments]),@"rollbackRestoredPlaylist":@([restored[@"playlistPath"] isEqual:expectedRestoredPlaylist]),@"error":error.localizedDescription?:@""};
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];fwrite(json.bytes,1,json.length,stdout);[ServiceStore remove:old[@"id"]];[ServiceStore remove:incoming[@"id"]];return 0;
    }
    if(argc==3 && strcmp(argv[1],"--playlist-check")==0){NSString *protocol=[NSString stringWithUTF8String:argv[2]],*engine=[protocol isEqual:@"nanotv-service-v2"]?@"node":@"python";NSDictionary *service=@{@"id":@"playlist-fixture",@"engine":engine,@"protocol":protocol,@"port":@18780,@"playlistPath":@"/all.m3u",@"manifest":@{@"schemaVersion":@1}};NSString *path=[ServiceStore playlistPathForService:service]?:@"";NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"playlistPath":path} options:0 error:NULL];fwrite(json.bytes,1,json.length,stdout);return 0;}
    if(argc<2 || argc>3)return 2;NSError *error=nil;
    NSString *input=[NSString stringWithUTF8String:argv[1]];__block NSDictionary *service=nil;NSArray *progressStages=@[];
    if([input isEqual:@"--migrate"] && argc==3){
        NSString *root=[NSString stringWithUTF8String:argv[2]];
        [ServiceStore save:@{@"id":@"legacy-node-fixture",@"name":@"legacy",@"port":@19999,@"engine":@"javascript",@"protocol":@"cctvhost.media/1",@"packageRoot":root,@"manifest":@{@"schemaVersion":@1,@"entry":@"index.js",@"runtime":@"javascript",@"protocol":@"cctvhost.media/1",@"moduleType":@"commonjs"}}];
        [MediaPackageImporter migrateLegacyRuntimeMetadata];
        for(NSDictionary *row in [NSUserDefaults.standardUserDefaults arrayForKey:@"pythonServices"])
            if([row[@"id"] isEqual:@"legacy-node-fixture"]){service=row;break;}
        NSMutableArray *saved=[[NSUserDefaults.standardUserDefaults arrayForKey:@"pythonServices"] mutableCopy];
        [saved removeObjectsAtIndexes:[saved indexesOfObjectsPassingTest:^BOOL(NSDictionary *row,NSUInteger index,BOOL *stop){return [row[@"id"] isEqual:@"legacy-node-fixture"];}]];
        [NSUserDefaults.standardUserDefaults setObject:saved forKey:@"pythonServices"];
    } else if([input isEqual:@"--cancel-download"] && argc==3){
        __block BOOL finished=NO;__block NSError *failure=nil;MediaPackageDownloader *downloader=[MediaPackageDownloader new];__weak MediaPackageDownloader *weak=downloader;
        downloader.onProgress=^(NSString *stage,int64_t received,int64_t expected){[weak cancel];};
        [downloader importURL:[NSURL URLWithString:[NSString stringWithUTF8String:argv[2]]] completion:^(NSDictionary *value,NSError *issue){service=value;failure=issue;finished=YES;}];
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:8];while(!finished&&deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        error=failure;if(!finished)return 3;
    } else if(argc!=2)return 2;
    else if([input hasPrefix:@"http"]){__block BOOL finished=NO;__block NSError *failure;NSMutableArray *stages=[NSMutableArray array];MediaPackageDownloader *downloader=[MediaPackageDownloader new];downloader.onProgress=^(NSString *stage,int64_t received,int64_t expected){if(![stages.lastObject isEqual:stage])[stages addObject:stage];};[downloader importURL:[NSURL URLWithString:input] completion:^(NSDictionary *value,NSError *issue){service=value;failure=issue;finished=YES;}];NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:8];while(!finished && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];error=failure;progressStages=[stages copy];if(!finished)return 3;}
    else service=[MediaPackageImporter importFile:[NSURL fileURLWithPath:input] error:&error];
    NSDictionary *result;
    if(service){NSString *code=[ServiceStore codePath:service];NSString *packagePath=[service[@"packageRoot"] stringByAppendingPathComponent:@"package.json"];NSData *packageData=[NSData dataWithContentsOfFile:packagePath];NSDictionary *package=packageData?[NSJSONSerialization JSONObjectWithData:packageData options:0 error:NULL]:@{};result=@{@"ok":@YES,@"name":service[@"name"],@"engine":service[@"engine"],@"protocol":service[@"protocol"],@"arguments":service[@"arguments"]?:@"",@"playlistPath":service[@"playlistPath"]?:@"",@"resolvedPlaylistPath":[ServiceStore playlistPathForService:service]?:@"",@"vodCapable":@([ServiceStore isVODMediaService:service]),@"verifiedLocalChecksums":service[@"manifest"][@"verifiedLocalChecksums"]?:@[],@"manifest":service[@"manifest"],@"nodePackageType":package[@"type"]?:@"",@"configurationState":service[@"configurationState"]?:@"",@"configurationExists":@([NSFileManager.defaultManager fileExistsAtPath:[service[@"packageRoot"] stringByAppendingPathComponent:service[@"manifest"][@"configEntry"]?:@"missing"]]),@"entryExists":@([NSFileManager.defaultManager fileExistsAtPath:code]),@"archiveExists":@([NSFileManager.defaultManager fileExistsAtPath:service[@"archivePath"]]),@"wrapper":([ServiceStore scriptPath:service].lastPathComponent?:@""),@"progressStages":progressStages};[NSFileManager.defaultManager removeItemAtPath:[[ServiceStore directory] stringByAppendingPathComponent:service[@"id"]] error:NULL];}
    else result=@{@"ok":@NO,@"error":error.localizedDescription?:@"unknown"};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];fwrite(json.bytes,1,json.length,stdout);
}return 0;}
