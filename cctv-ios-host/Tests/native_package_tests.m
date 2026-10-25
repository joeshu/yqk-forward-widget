#import "MediaPackageImporter.h"
#import "ServiceStore.h"
#import "MediaPackageDownloader.h"
#import <Foundation/Foundation.h>
#include <string.h>
int main(int argc,const char **argv){@autoreleasepool{
    if(argc==4 && strcmp(argv[1],"--update")==0){
        NSError *error=nil;NSMutableDictionary *old=[[MediaPackageImporter importFile:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]] error:&error] mutableCopy];
        NSDictionary *incoming=[MediaPackageImporter importFile:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[3]]] error:&error];
        if(!old||!incoming)return 4;
        old[@"port"]=@19991;old[@"name"]=@"user-name";NSMutableDictionary *manifest=[old[@"manifest"] mutableCopy];manifest[@"options"]=@{@"userChoice":@"keep"};old[@"manifest"]=manifest;[ServiceStore save:old];
        NSString *marker=[[[ServiceStore directory] stringByAppendingPathComponent:old[@"id"]] stringByAppendingPathComponent:@"fixture-account.json"];
        [@"account-data" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSString *before=[NSString stringWithContentsOfFile:[ServiceStore codePath:old] encoding:NSUTF8StringEncoding error:NULL];
        NSDictionary *updated=[ServiceStore replaceImportedService:old withService:incoming error:&error];
        NSDictionary *restored=updated?[ServiceStore rollbackImportedService:updated error:&error]:nil;
        NSString *after=restored?[NSString stringWithContentsOfFile:[ServiceStore codePath:restored] encoding:NSUTF8StringEncoding error:NULL]:nil;
        NSDictionary *result=@{@"ok":@(updated&&restored),@"sameID":@([old[@"id"] isEqual:updated[@"id"]]),@"portKept":@([updated[@"port"] isEqual:@19991]),@"optionsKept":@([updated[@"manifest"][@"options"][@"userChoice"] isEqual:@"keep"]),@"accountKept":@([NSFileManager.defaultManager fileExistsAtPath:marker]),@"rollbackRestoredCode":@(before&&[before isEqual:after]),@"error":error.localizedDescription?:@""};
        NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];fwrite(json.bytes,1,json.length,stdout);[ServiceStore remove:old[@"id"]];[ServiceStore remove:incoming[@"id"]];return 0;
    }
    if(argc<2 || argc>3)return 2;NSError *error=nil;
    NSString *input=[NSString stringWithUTF8String:argv[1]];__block NSDictionary *service=nil;
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
    else if([input hasPrefix:@"http"]){__block BOOL finished=NO;__block NSError *failure;MediaPackageDownloader *downloader=[MediaPackageDownloader new];[downloader importURL:[NSURL URLWithString:input] completion:^(NSDictionary *value,NSError *issue){service=value;failure=issue;finished=YES;}];NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:8];while(!finished && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];error=failure;if(!finished)return 3;}
    else service=[MediaPackageImporter importFile:[NSURL fileURLWithPath:input] error:&error];
    NSDictionary *result;
    if(service){NSString *code=[ServiceStore codePath:service];NSString *packagePath=[service[@"packageRoot"] stringByAppendingPathComponent:@"package.json"];NSData *packageData=[NSData dataWithContentsOfFile:packagePath];NSDictionary *package=packageData?[NSJSONSerialization JSONObjectWithData:packageData options:0 error:NULL]:@{};result=@{@"ok":@YES,@"name":service[@"name"],@"engine":service[@"engine"],@"protocol":service[@"protocol"],@"arguments":service[@"arguments"]?:@"",@"playlistPath":service[@"playlistPath"]?:@"",@"manifest":service[@"manifest"],@"nodePackageType":package[@"type"]?:@"",@"configurationState":service[@"configurationState"]?:@"",@"configurationExists":@([NSFileManager.defaultManager fileExistsAtPath:[service[@"packageRoot"] stringByAppendingPathComponent:service[@"manifest"][@"configEntry"]?:@"missing"]]),@"entryExists":@([NSFileManager.defaultManager fileExistsAtPath:code]),@"archiveExists":@([NSFileManager.defaultManager fileExistsAtPath:service[@"archivePath"]]),@"wrapper":([ServiceStore scriptPath:service].lastPathComponent?:@"")};[NSFileManager.defaultManager removeItemAtPath:[[ServiceStore directory] stringByAppendingPathComponent:service[@"id"]] error:NULL];}
    else result=@{@"ok":@NO,@"error":error.localizedDescription?:@"unknown"};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];fwrite(json.bytes,1,json.length,stdout);
}return 0;}
