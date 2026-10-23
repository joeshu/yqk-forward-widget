#import "MediaPackageImporter.h"
#import "ServiceStore.h"
#include <zlib.h>

static NSUInteger const PackageArchiveLimit=24*1024*1024;
static NSUInteger const PackageFileLimit=8*1024*1024;
static NSUInteger const PackageTotalLimit=64*1024*1024;
static NSUInteger const PackageCountLimit=2048;
static BOOL PackageError(NSError **error,NSString *message){if(error)*error=[NSError errorWithDomain:@"CCTVHostPackage" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];return NO;}
static uint16_t U16(const uint8_t *b,NSUInteger n){return (uint16_t)b[n]|((uint16_t)b[n+1]<<8);}
static uint32_t U32(const uint8_t *b,NSUInteger n){return (uint32_t)U16(b,n)|((uint32_t)U16(b,n+2)<<16);}
static BOOL SafeRelative(NSString *path){
    if(![path isKindOfClass:NSString.class] || !path.length || [path hasPrefix:@"/"] || [path containsString:@"\\"] || [path containsString:@":"] || [path rangeOfString:[NSString stringWithFormat:@"%C",(unichar)0]].location!=NSNotFound)return NO;
    for(NSString *part in path.pathComponents)if([part isEqual:@".."] || [part isEqual:@"."])return NO;
    return YES;
}
static NSData *ReadBounded(NSURL *url,NSUInteger limit,NSError **error){
    NSFileHandle *file=[NSFileHandle fileHandleForReadingFromURL:url error:error];if(!file)return nil;
    NSMutableData *bytes=[NSMutableData data];
    @try {
        while(bytes.length<=limit){NSData *part=[file readDataUpToLength:MIN((NSUInteger)65536,limit+1-bytes.length) error:error];if(!part){bytes=nil;break;}if(!part.length)break;[bytes appendData:part];}
    }@catch(NSException *exception){PackageError(error,@"无法读取资源文件");bytes=nil;}
    @finally{[file closeAndReturnError:NULL];}
    if(bytes.length>limit){PackageError(error,@"资源文件超过允许的大小");return nil;}return bytes;
}
static BOOL ExtractZip(NSData *data,NSString *directory,NSError **error){
    const uint8_t *b=data.bytes;NSUInteger length=data.length;if(length<22)return PackageError(error,@"ZIP 文件不完整");
    NSUInteger eocd=NSNotFound,minimum=length>65557?length-65557:0;
    for(NSUInteger p=length-22;;p--){if(U32(b,p)==0x06054b50 && p+22+U16(b,p+20)==length){eocd=p;break;}if(p==minimum)break;}
    if(eocd==NSNotFound)return PackageError(error,@"未找到有效 ZIP 目录");
    NSUInteger count=U16(b,eocd+10),size=U32(b,eocd+12),offset=U32(b,eocd+16);
    if(U16(b,eocd+4)||U16(b,eocd+6)||count!=U16(b,eocd+8)||!count||count>PackageCountLimit||offset+size>eocd)return PackageError(error,@"不支持分卷、ZIP64 或包含过多文件的资源包");
    NSUInteger p=offset,total=0;NSMutableSet *names=[NSMutableSet set];NSFileManager *fm=NSFileManager.defaultManager;
    for(NSUInteger index=0;index<count;index++){
        if(p+46>offset+size || U32(b,p)!=0x02014b50)return PackageError(error,@"ZIP 目录损坏");
        NSUInteger flags=U16(b,p+8),method=U16(b,p+10),crc=U32(b,p+16),compressed=U32(b,p+20),expanded=U32(b,p+24),nameLength=U16(b,p+28),extra=U16(b,p+30),comment=U16(b,p+32),local=U32(b,p+42);
        uint32_t attributes=U32(b,p+38);NSUInteger kind=(attributes>>16)&0170000;
        if(p+46+nameLength+extra+comment>offset+size || !nameLength || flags&1 || (method!=0 && method!=8) || compressed>PackageArchiveLimit || expanded>PackageFileLimit || expanded>PackageTotalLimit-total || local>=offset || kind==0120000 || (kind && kind!=0100000 && kind!=0040000))return PackageError(error,@"ZIP 含不支持的压缩、加密、链接或超出限制的文件");
        NSData *nameData=[data subdataWithRange:NSMakeRange(p+46,nameLength)];NSString *name=[[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding];
        if(!SafeRelative(name))return PackageError(error,@"ZIP 文件路径无效或超出资源目录");
        NSString *key=name.precomposedStringWithCanonicalMapping.lowercaseString;
        if([names containsObject:key])return PackageError(error,@"ZIP 中存在重复或大小写冲突的路径");[names addObject:key];
        BOOL isDirectory=[name hasSuffix:@"/"];
        if(kind==0040000 && !isDirectory)return PackageError(error,@"ZIP 目录类型与路径不一致");
        if(local+30>offset || U32(b,local)!=0x04034b50 || U16(b,local+8)!=method || (U16(b,local+6)&1))return PackageError(error,@"ZIP 文件头无效");
        NSUInteger localName=U16(b,local+26),body=local+30+localName+U16(b,local+28);
        if(body>offset || compressed>offset-body || localName!=nameLength || memcmp(b+local+30,nameData.bytes,nameLength)!=0)return PackageError(error,@"ZIP 数据范围或文件名不一致");
        NSString *target=[directory stringByAppendingPathComponent:name];
        if(isDirectory){if(expanded || ![fm createDirectoryAtPath:target withIntermediateDirectories:YES attributes:nil error:error])return NO;}
        else {
            NSMutableData *output=[NSMutableData dataWithLength:expanded];
            if(method==0){if(compressed!=expanded)return PackageError(error,@"ZIP 未压缩文件大小不一致");if(expanded)memcpy(output.mutableBytes,b+body,expanded);}
            else {
                uint8_t empty=0;z_stream stream={0};stream.next_in=(Bytef *)(b+body);stream.avail_in=(uInt)compressed;stream.next_out=expanded?output.mutableBytes:&empty;stream.avail_out=(uInt)MAX(expanded,(NSUInteger)1);
                if(inflateInit2(&stream,-MAX_WBITS)!=Z_OK)return PackageError(error,@"无法初始化 ZIP 解压器");int result=inflate(&stream,Z_FINISH);inflateEnd(&stream);
                if(result!=Z_STREAM_END || stream.total_out!=expanded || stream.total_in!=compressed)return PackageError(error,@"ZIP 文件解压失败或超出声明大小");
            }
            if(crc32(0L,output.bytes,(uInt)output.length)!=crc)return PackageError(error,@"ZIP 文件校验失败");
            if(![fm createDirectoryAtPath:target.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error] || ![output writeToFile:target options:NSDataWritingAtomic error:error])return NO;
            total+=expanded;
        }
        p+=46+nameLength+extra+comment;
    }
    return p==offset+size?YES:PackageError(error,@"ZIP 目录长度不一致");
}

@implementation MediaPackageImporter
+ (void)migrateLegacyRuntimeMetadata {
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    NSMutableArray *services=[[defaults arrayForKey:@"pythonServices"] mutableCopy];
    if(!services.count)return;
    BOOL changed=NO;
    for(NSUInteger index=0;index<services.count;index++){
        NSDictionary *service=services[index];NSDictionary *manifest=service[@"manifest"];
        NSString *root=service[@"packageRoot"];
        if([service[@"builtin"] boolValue] || ![service[@"engine"] isEqual:@"javascript"] ||
           ![manifest isKindOfClass:NSDictionary.class] || ![root isKindOfClass:NSString.class] || !root.length)continue;
        NSDictionary *detected=[self inspectDirectory:root error:NULL];
        if(![detected[@"runtime"] isEqual:@"node"])continue;
        NSMutableDictionary *updatedManifest=[detected mutableCopy];
        [updatedManifest removeObjectForKey:@"packageRoot"];
        if(manifest[@"options"] && !updatedManifest[@"options"])updatedManifest[@"options"]=manifest[@"options"];
        NSMutableDictionary *updatedService=[service mutableCopy];
        updatedService[@"manifest"]=updatedManifest;
        updatedService[@"engine"]=updatedManifest[@"runtime"];
        updatedService[@"protocol"]=updatedManifest[@"protocol"];
        services[index]=updatedService;changed=YES;
    }
    if(changed)[defaults setObject:services forKey:@"pythonServices"];
}

+ (NSDictionary *)inspectDirectory:(NSString *)directory error:(NSError **)error {
    NSFileManager *fm=NSFileManager.defaultManager;NSString *root=directory;
    NSArray *visible=[[fm contentsOfDirectoryAtPath:root error:error] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *name,NSDictionary *bindings){return ![name hasPrefix:@"."] && ![name isEqual:@"__MACOSX"];}]];
    if(visible.count==1){BOOL isDirectory=NO;NSString *nested=[root stringByAppendingPathComponent:visible.firstObject];if([fm fileExistsAtPath:nested isDirectory:&isDirectory] && isDirectory)root=nested;}
    NSData *manifestData=ReadBounded([NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"cctvhost.json"]],65536,NULL);
    if(!manifestData && [fm fileExistsAtPath:[root stringByAppendingPathComponent:@"cctvhost.json"]]){PackageError(error,@"cctvhost.json 无法读取或超过 64 KB");return nil;}
    id manifest=manifestData?[NSJSONSerialization JSONObjectWithData:manifestData options:0 error:NULL]:nil;
    if(manifestData && ![manifest isKindOfClass:NSDictionary.class]){PackageError(error,@"cctvhost.json 不是有效 JSON 对象");return nil;}
    NSMutableDictionary *result=[manifest?:@{} mutableCopy];
    for(NSString *key in @[@"entry",@"runtime",@"protocol",@"moduleType",@"name"])if(result[key] && ![result[key] isKindOfClass:NSString.class]){PackageError(error,@"资源清单字段类型错误");return nil;}
    if(result[@"schemaVersion"] && (![result[@"schemaVersion"] isKindOfClass:NSNumber.class] || [result[@"schemaVersion"] integerValue]!=1)){PackageError(error,@"不支持此资源清单版本");return nil;}
    NSData *packageData=ReadBounded([NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"package.json"]],65536,NULL);
    id package=packageData?[NSJSONSerialization JSONObjectWithData:packageData options:0 error:NULL]:nil;if(![package isKindOfClass:NSDictionary.class])package=@{};
    for(NSString *key in @[@"module",@"main",@"name",@"type"])if(package[key] && ![package[key] isKindOfClass:NSString.class]){PackageError(error,@"package.json 字段类型错误");return nil;}
    NSString *entry=result[@"entry"];
    if(!entry.length){
        entry=package[@"module"]?:package[@"main"];
        if([entry hasPrefix:@"./"])entry=[entry substringFromIndex:2];
        if(!entry.length)for(NSString *candidate in @[@"index.js",@"index.mjs",@"index.cjs",@"spider.py",@"main.py"]){if([fm fileExistsAtPath:[root stringByAppendingPathComponent:candidate]]){entry=candidate;break;}}
        if(!entry.length){NSMutableArray *candidates=[NSMutableArray array];for(NSString *name in [fm contentsOfDirectoryAtPath:root error:NULL])if([@[@"py",@"js",@"mjs",@"cjs"] containsObject:name.pathExtension.lowercaseString])[candidates addObject:name];if(candidates.count==1)entry=candidates.firstObject;}
    }
    if(!SafeRelative(entry) || ![fm fileExistsAtPath:[root stringByAppendingPathComponent:entry]]){PackageError(error,@"无法识别入口；请在 cctvhost.json 中指定 entry");return nil;}
    NSString *text=[[NSString alloc] initWithData:ReadBounded([NSURL fileURLWithPath:[root stringByAppendingPathComponent:entry]],PackageFileLimit,error) encoding:NSUTF8StringEncoding];if(!text.length){PackageError(error,@"入口不是有效 UTF-8 文本或文件过大");return nil;}
    NSString *runtime=result[@"runtime"],*protocol=result[@"protocol"],*moduleType=result[@"moduleType"];
    if(!runtime.length && [entry.pathExtension.lowercaseString isEqual:@"py"])runtime=@"python";
    if(!protocol.length){
        if([runtime isEqual:@"python"]){protocol=[text rangeOfString:@"class Spider"].location!=NSNotFound?@"python-spider":@"python-http";}
        else if([text containsString:@"createService"] && [text containsString:@"/config"] && [text containsString:@"/spider/"]){runtime=@"node";protocol=@"catpaw-http";}
        else if([text containsString:@"deferredRef"] && [text containsString:@"resolve"] && [text containsString:@"fetch"]){runtime=@"node";protocol=@"iptv-extractor";}
        else if([text rangeOfString:@"(?:var|let|const)\\s+rule\\s*=" options:NSRegularExpressionSearch].location!=NSNotFound)protocol=@"drpy";
        else if([text containsString:@"vod_play_from"] || [text containsString:@"vod_id"])protocol=@"catvod-js";
        else protocol=@"cctvhost.media/1";
    }
    if(!moduleType.length)moduleType=[entry.pathExtension isEqual:@"cjs"] || [text containsString:@"module.exports"]?@"commonjs":([package[@"type"] isEqual:@"module"] || [text rangeOfString:@"(?:^|\\n)\\s*(?:import|export)\\s" options:NSRegularExpressionSearch].location!=NSNotFound?@"esm":@"script");
    if(!runtime.length){
        NSDictionary *dependencies=[package[@"dependencies"] isKindOfClass:NSDictionary.class]?package[@"dependencies"]:@{};
        BOOL hasCommonJSRequire=[text rangeOfString:@"\\brequire\\s*\\(\\s*['\\\"]" options:NSRegularExpressionSearch].location!=NSNotFound;
        BOOL nodeProtocol=[@[@"drpy"] containsObject:protocol];
        runtime=(dependencies.count || (hasCommonJSRequire && !nodeProtocol))?@"node":@"javascript";
    }
    if(![@[@"esm",@"commonjs",@"script"] containsObject:moduleType] || ([runtime isEqual:@"python"] != [entry.pathExtension.lowercaseString isEqual:@"py"])){PackageError(error,@"入口类型与运行时声明不匹配");return nil;}
    if(![@[@"python",@"javascript",@"node"] containsObject:runtime] || ![@[@"python-spider",@"python-http",@"cctvhost.media/1",@"catvod-js",@"drpy",@"iptv-extractor",@"catpaw-http"] containsObject:protocol]){PackageError(error,@"资源声明了尚不支持的运行时或协议");return nil;}
    // Keep a small, typed manifest: no arbitrary paths or host control fields.
    NSMutableDictionary *clean=[@{@"schemaVersion":@1,@"entry":entry,@"runtime":runtime,@"protocol":protocol,@"moduleType":moduleType,@"name":([result[@"name"] isKindOfClass:NSString.class]?result[@"name"]:(package[@"name"]?:entry.stringByDeletingPathExtension))} mutableCopy];
    if(result[@"capabilities"]){if(![result[@"capabilities"] isKindOfClass:NSArray.class]){PackageError(error,@"capabilities 必须是字符串数组");return nil;}for(id value in result[@"capabilities"])if(![value isKindOfClass:NSString.class]){PackageError(error,@"capabilities 包含无效类型");return nil;}clean[@"capabilities"]=result[@"capabilities"];}
    if([result[@"options"] isKindOfClass:NSDictionary.class] || [result[@"options"] isKindOfClass:NSString.class])clean[@"options"]=result[@"options"];
    clean[@"packageRoot"]=root;
    return clean;
}
+ (NSDictionary *)importFile:(NSURL *)file error:(NSError **)error {
    NSData *bytes=ReadBounded(file,PackageArchiveLimit,error);if(!bytes)return nil;
    NSString *identifier=NSUUID.UUID.UUIDString,*stage=[[ServiceStore directory] stringByAppendingPathComponent:[@".import-" stringByAppendingString:identifier]];
    NSString *package=[stage stringByAppendingPathComponent:@"package"];NSFileManager *fm=NSFileManager.defaultManager;
    if(![fm createDirectoryAtPath:package withIntermediateDirectories:YES attributes:nil error:error])return nil;
    NSDictionary *service=nil;
    @try {
        if([file.pathExtension.lowercaseString isEqual:@"zip"]){if(!ExtractZip(bytes,package,error))return nil;}
        else {
            NSString *name=file.lastPathComponent;
            if(![@[@"js",@"mjs",@"cjs",@"py"] containsObject:file.pathExtension.lowercaseString] || !SafeRelative(name) || bytes.length>PackageFileLimit){PackageError(error,@"请选择 JS、Python 或 ZIP 资源文件");return nil;}
            if(![bytes writeToFile:[package stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:error])return nil;
        }
        NSMutableDictionary *manifest=[[self inspectDirectory:package error:error] mutableCopy];if(!manifest)return nil;
        NSString *relative=[manifest[@"packageRoot"] substringFromIndex:stage.length+1];[manifest removeObjectForKey:@"packageRoot"];
        BOOL zip=[file.pathExtension.lowercaseString isEqual:@"zip"];
        if(zip && ![bytes writeToFile:[stage stringByAppendingPathComponent:@"source.zip"] options:NSDataWritingAtomic error:error])return nil;
        NSString *target=[[ServiceStore directory] stringByAppendingPathComponent:identifier];
        if(![fm moveItemAtPath:stage toPath:target error:error])return nil;
        NSMutableSet *ports=[NSMutableSet set];for(NSDictionary *existing in [ServiceStore services])[ports addObject:existing[@"port"]?:@0];NSInteger port=18780;while([ports containsObject:@(port)] && port<65535)port++;
        service=@{@"id":identifier,@"name":manifest[@"name"],@"port":@(port),@"engine":manifest[@"runtime"],@"protocol":manifest[@"protocol"],@"manifest":manifest,@"packageRoot":[target stringByAppendingPathComponent:relative],@"archivePath":zip?[target stringByAppendingPathComponent:@"source.zip"]:@"",@"lan":@NO,@"updated":@(NSDate.date.timeIntervalSince1970),@"arguments":@""};
    } @catch(NSException *exception){PackageError(error,@"资源包结构或清单无效，未执行代码");return nil;}
    @finally {if([fm fileExistsAtPath:stage])[fm removeItemAtPath:stage error:NULL];}
    return service;
}
@end
