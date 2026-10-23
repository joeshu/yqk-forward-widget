#import "MediaPackageImporter.h"
#import "ServiceStore.h"
#import <Foundation/Foundation.h>
int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=2)return 2;NSError *error=nil;
    NSDictionary *service=[MediaPackageImporter importFile:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]] error:&error];
    NSDictionary *result;
    if(service){NSString *code=[ServiceStore codePath:service];result=@{@"ok":@YES,@"name":service[@"name"],@"engine":service[@"engine"],@"protocol":service[@"protocol"],@"manifest":service[@"manifest"],@"entryExists":@([NSFileManager.defaultManager fileExistsAtPath:code]),@"archiveExists":@([NSFileManager.defaultManager fileExistsAtPath:service[@"archivePath"]]),@"wrapper":([ServiceStore scriptPath:service].lastPathComponent?:@"")};[NSFileManager.defaultManager removeItemAtPath:[[ServiceStore directory] stringByAppendingPathComponent:service[@"id"]] error:NULL];}
    else result=@{@"ok":@NO,@"error":error.localizedDescription?:@"unknown"};
    NSData *json=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];fwrite(json.bytes,1,json.length,stdout);
}return 0;}
