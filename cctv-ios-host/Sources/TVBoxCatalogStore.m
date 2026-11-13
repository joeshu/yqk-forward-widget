#import "TVBoxCatalogStore.h"
#import "MediaJARSource.h"
#include <zlib.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonCryptor.h>
#import <objc/message.h>

static NSError *TVBoxError(NSString *message) {
    return [NSError errorWithDomain:@"CCTVHostTVBox" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

static NSString *TVBoxString(id value, NSUInteger limit) {
    if ([value isKindOfClass:NSString.class]) return [value length] <= limit ? value : nil;
    if ([value isKindOfClass:NSNumber.class]) return [value stringValue];
    return nil;
}

static NSURLComponents *TVBoxURLComponents(NSString *value) {
    if(![value isKindOfClass:NSString.class]||!value.length)return nil;
    NSURLComponents *parts=[NSURLComponents componentsWithString:value];
    if(parts)return parts;
    NSMutableCharacterSet *allowed=[NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed addCharactersInString:@"#%/:?@[]!$&'()*+,;="];
    NSString *encoded=[value stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    return encoded.length?[NSURLComponents componentsWithString:encoded]:nil;
}

static BOOL TVBoxWebURL(NSString *value) {
    NSURLComponents *parts=TVBoxURLComponents(value ?: @"");
    return parts&&[@[@"http",@"https"] containsObject:parts.scheme.lowercaseString] && parts.host.length && !parts.user.length && !parts.password.length && value.length<=8192;
}

static NSString *TVBoxCatalogStorageDirectory(void) {
    NSString *applicationSupport=NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject;
    NSString *directory=[applicationSupport stringByAppendingPathComponent:@"TVBoxCatalogs"];
    [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    return directory;
}

static NSString *TVBoxCatalogBundlesDirectory(void) {
    NSString *dir=[TVBoxCatalogStorageDirectory() stringByAppendingPathComponent:@"Bundles"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

static BOOL TVBoxSafeCatalogID(NSString *identifier) {
    if(![identifier isKindOfClass:NSString.class]||!identifier.length||identifier.length>128)return NO;
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound;
}

static NSString *TVBoxHashHex(NSData *data, BOOL md5) {
    if(!data.length)return @"";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if(md5)CC_MD5(data.bytes,(CC_LONG)data.length,digest);
    else CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    NSMutableString *hex=[NSMutableString stringWithCapacity:(md5?CC_MD5_DIGEST_LENGTH:CC_SHA256_DIGEST_LENGTH)*2];
    for(NSUInteger i=0;i<(md5?CC_MD5_DIGEST_LENGTH:CC_SHA256_DIGEST_LENGTH);i++)[hex appendFormat:@"%02x",digest[i]];
    return hex;
}

static void TVBoxPreseedJARRuntimeCache(NSData *jarData, NSString *jarURL, NSString *md5) {
    if(!jarData.length||!jarURL.length)return;
    NSString *support=NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES).firstObject;
    if(!support.length)return;
    NSString *root=[support stringByAppendingPathComponent:@"JARRuntime"];
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *digest=TVBoxHashHex(jarData,NO);
    if(digest.length!=64)return;
    NSString *jarPath=[root stringByAppendingPathComponent:[digest stringByAppendingString:@".jar"]];
    if(![NSFileManager.defaultManager fileExistsAtPath:jarPath]){
        [jarData writeToFile:jarPath options:NSDataWritingAtomic error:NULL];
    }
    NSString *effectiveMD5=md5.length?md5.lowercaseString:TVBoxHashHex(jarData,YES);
    for(NSString *candidateMD5 in (effectiveMD5.length?@[effectiveMD5,@""]:@[@""])){
        NSData *identity=[NSJSONSerialization dataWithJSONObject:@{@"url":jarURL,@"headers":@{},@"md5":candidateMD5} options:NSJSONWritingSortedKeys error:NULL];
        if(!identity.length)continue;
        NSString *recordPath=[root stringByAppendingPathComponent:[TVBoxHashHex(identity,NO) stringByAppendingString:@".json"]];
        NSData *recData=[NSJSONSerialization dataWithJSONObject:@{@"digest":digest,@"time":@(NSDate.date.timeIntervalSince1970+86400*365)} options:0 error:NULL];
        [recData writeToFile:recordPath atomically:YES];
    }
}

static NSString *TVBoxDecodeQiaojiExt(NSString *rawExt) {
    if(![rawExt isKindOfClass:NSString.class]||rawExt.length<16)return nil;
    NSString *trimmed=[rawExt stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(![trimmed.lowercaseString hasPrefix:@"7lj763gg"])return nil;
    static NSDictionary<NSString *,NSString *> *knownVariants=nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{
        knownVariants=@{
            @"7lj763gg402i79425739i3jghj118797l4hj840gi13l33238l4708g2h7145403":@"http://111.180.198.40:1110|asgcxhjkts124573|asgcxhjkts124573|101",
            @"7lj763gg402i79425033i3i7h6079796glh69g0i":@"http://172.83.156.150:1010/api.php/app/",
            @"7lj763gg402i7942463ji1j0hj46869hllh7810ki3":@"https://fs-im-kefu.7moor-fs1.com/ly/4d2c3f00-7d4c-11e5-af15-41bf63ae4ea0/1745208060258/cksp.txt",
            @"7lj763gg0939790i012ii6j6hj468h9hl7":@"http://gw.mcyan.cn|顾我追剧|4.1.9",
            @"7lj763gg402i7942463h93i0h44j8681highi4":@"https://api.wwgz.cn:520/webcloud/relay.php?url=",
            @"7lj763gg402i7942556484j2h8489888highi4":@"https://www.hskjjglo.com",
            @"7lj763gg402i7942572k85i2h948879hll":@"https://v.xlys.ltd.ua",
            @"7lj763gg402i7942572k85i2h8498181l5h6825ii6":@"https://www.libvio.cc",
            @"7lj763gg402i7942572k85i2h2529282highi4":@"https://www.zxzjys.com",
            @"7lj763gg402i7942572k85i2hj448085l8h7":@"https://www.czzy77.com",
            @"7lj763gg402i7942463ji1j0hj46869hllh7810ki36k2628800059j2h614415609966789267892174082h1477293h2468098l7079g11i2232k22871819i7i1059994":@"https://www.qiaoji8.com/tvbox/bili.json",
            @"7lj763gg09397919127185i6h5488682l5h6825ii63l222g9h1019g019584359578234822429":@"http://175.178.80.209/mb/api.php/provide/vod/|okhttp/4.9.1|qiaoji",
        };
    });
    if(knownVariants[trimmed])return knownVariants[trimmed];
    NSString *cleaned=[trimmed stringByReplacingOccurrencesOfString:@"qiaoji" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0,trimmed.length)];
    cleaned=[cleaned stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(cleaned.length<16||(cleaned.length%2)!=0)return nil;
    static const uint8_t kQiaojiKey[170]={
        0x17, 0xa3, 0x17, 0xda, 0x33, 0x16, 0x56, 0x6d, 0x31, 0x4a, 0xea, 0xb3, 0xd0, 0x3c, 0xec, 0xf2,
        0x92, 0xc8, 0xaa, 0x3d, 0xac, 0xe9, 0x5c, 0x41, 0x32, 0x21, 0x7b, 0x93, 0x99, 0x77, 0x3b, 0x6e,
        0x7b, 0xf6, 0x3d, 0xd7, 0xf8, 0x32, 0xf3, 0xe4, 0x5b, 0x7d, 0xdd, 0xe3, 0x96, 0x9c, 0x78, 0x87,
        0x90, 0x00, 0x14, 0x3e, 0x84, 0xd2, 0xab, 0x9c, 0x46, 0xe5, 0x5d, 0x93, 0x0f, 0xcd, 0x2d, 0x20,
        0x9a, 0x97, 0xa2, 0xc2, 0x96, 0x17, 0x42, 0x18, 0xff, 0x22, 0x5c, 0x35, 0xf2, 0x97, 0x28, 0x06,
        0x12, 0xd1, 0x9a, 0x0e, 0x47, 0x86, 0xae, 0xcc, 0xe5, 0xeb, 0x49, 0xc1, 0x08, 0x7f, 0x73, 0x0f,
        0x01, 0xa5, 0x47, 0x98, 0xd3, 0x2b, 0xd6, 0x27, 0xef, 0x49, 0x1c, 0x4d, 0x6d, 0xf5, 0x7f, 0xf5,
        0xbd, 0x79, 0x4c, 0xf0, 0x63, 0xb6, 0x1d, 0x28, 0xc4, 0x1b, 0x2d, 0xf0, 0xb4, 0x30, 0x0c, 0x79,
        0x5b, 0x24, 0x79, 0x67, 0x57, 0xd8, 0x2d, 0xe7, 0xb0, 0x86, 0x32, 0x50, 0xbd, 0x54, 0x49, 0xdc,
        0x0b, 0x65, 0x97, 0x35, 0xe9, 0x02, 0x10, 0xd8, 0x61, 0x0b, 0x8f, 0x27, 0x31, 0x09, 0xc1, 0x77,
        0x64, 0xc1, 0xf2, 0xb8, 0x34, 0xa5, 0x6c, 0xaa, 0x3f, 0x11
    };
    NSUInteger byteCount=cleaned.length/2;
    NSMutableData *out=[NSMutableData dataWithLength:byteCount];
    uint8_t *outBytes=(uint8_t *)out.mutableBytes;
    for(NSUInteger i=0;i<byteCount;i++){
        unichar c1=[cleaned characterAtIndex:i*2];
        unichar c2=[cleaned characterAtIndex:i*2+1];
        int hi=-1,lo=-1;
        if(c1>='0'&&c1<='9')hi=c1-'0';
        else if(c1>='g'&&c1<='l')hi=10+(c1-'g');
        else if(c1>='G'&&c1<='L')hi=10+(c1-'G');
        if(c2>='0'&&c2<='9')lo=c2-'0';
        else if(c2>='g'&&c2<='l')lo=10+(c2-'g');
        else if(c2>='G'&&c2<='L')lo=10+(c2-'G');
        if(hi<0||lo<0)return nil;
        uint8_t b=(uint8_t)((hi<<4)|lo);
        outBytes[i]=b ^ kQiaojiKey[i % sizeof(kQiaojiKey)];
    }
    NSString *decoded=[[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
    if(!decoded.length)decoded=[[NSString alloc] initWithData:out encoding:NSISOLatin1StringEncoding];
    if(decoded.length&&([decoded.lowercaseString hasPrefix:@"http://"]||[decoded.lowercaseString hasPrefix:@"https://"]))return decoded;
    return nil;
}

static NSData *TVBoxStripCommentsAndTrailingCommas(NSString *text) {
    if(!text.length)return nil;
    NSUInteger len=text.length;
    NSMutableString *out=[NSMutableString stringWithCapacity:len];
    BOOL inString=NO;
    BOOL escaped=NO;
    NSUInteger i=0;
    while(i<len){
        unichar c=[text characterAtIndex:i];
        if(inString){
            [out appendFormat:@"%C",c];
            if(escaped){
                escaped=NO;
            }else if(c=='\\'){
                escaped=YES;
            }else if(c=='"'){
                inString=NO;
            }
            i++;
            continue;
        }
        if(c=='"'){
            inString=YES;
            [out appendFormat:@"%C",c];
            i++;
            continue;
        }
        if(c=='/'&&i+1<len){
            unichar next=[text characterAtIndex:i+1];
            if(next=='/'){
                i+=2;
                while(i<len){
                    unichar nl=[text characterAtIndex:i];
                    if(nl=='\n'||nl=='\r')break;
                    i++;
                }
                continue;
            }else if(next=='*'){
                i+=2;
                while(i+1<len){
                    if([text characterAtIndex:i]=='*'&&[text characterAtIndex:i+1]=='/'){
                        i+=2;
                        break;
                    }
                    i++;
                }
                continue;
            }
        }
        [out appendFormat:@"%C",c];
        i++;
    }
    // Strip trailing commas before } or ] outside strings
    NSMutableString *clean=[NSMutableString stringWithCapacity:out.length];
    inString=NO;escaped=NO;
    NSUInteger outLen=out.length;
    for(NSUInteger j=0;j<outLen;j++){
        unichar c=[out characterAtIndex:j];
        if(inString){
            [clean appendFormat:@"%C",c];
            if(escaped)escaped=NO;
            else if(c=='\\')escaped=YES;
            else if(c=='"')inString=NO;
            continue;
        }
        if(c=='"'){
            inString=YES;
            [clean appendFormat:@"%C",c];
            continue;
        }
        if(c==','){
            NSUInteger k=j+1;
            while(k<outLen){
                unichar ws=[out characterAtIndex:k];
                if(ws==' '||ws=='\t'||ws=='\r'||ws=='\n')k++;
                else break;
            }
            if(k<outLen&&([out characterAtIndex:k]=='}'||[out characterAtIndex:k]==']')){
                continue;
            }
        }
        [clean appendFormat:@"%C",c];
    }
    return [clean dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *TVBoxTryDecryptHex2423Payload(NSString *text) {
    NSString *trimmed=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(![trimmed.lowercaseString hasPrefix:@"2423"]||trimmed.length<64||(trimmed.length%2)!=0)return nil;
    NSRange keyEnd=[trimmed.lowercaseString rangeOfString:@"2324" options:0 range:NSMakeRange(4,MIN((NSUInteger)64,trimmed.length-4))];
    if(keyEnd.location==NSNotFound)return nil;
    NSString *keyHex=[trimmed substringWithRange:NSMakeRange(4,keyEnd.location-4)];
    NSMutableData *keyRaw=[NSMutableData data];
    for(NSUInteger i=0;i+1<keyHex.length;i+=2){
        unsigned int b=0;
        if([[NSScanner scannerWithString:[keyHex substringWithRange:NSMakeRange(i,2)]] scanHexInt:&b]){
            uint8_t byte=(uint8_t)b;
            [keyRaw appendBytes:&byte length:1];
        }
    }
    NSString *keyStr=[[NSString alloc] initWithData:keyRaw encoding:NSUTF8StringEncoding]?:@"";
    while(keyStr.length<16)keyStr=[keyStr stringByAppendingString:@"0"];
    if(keyStr.length>16)keyStr=[keyStr substringToIndex:16];
    NSString *ivHex=trimmed.length>=32?[trimmed substringFromIndex:trimmed.length-32]:@"";
    NSMutableData *ivRaw=[NSMutableData data];
    for(NSUInteger i=0;i+1<ivHex.length;i+=2){
        unsigned int b=0;
        if([[NSScanner scannerWithString:[ivHex substringWithRange:NSMakeRange(i,2)]] scanHexInt:&b]){
            uint8_t byte=(uint8_t)b;
            [ivRaw appendBytes:&byte length:1];
        }
    }
    NSString *ivStr=[[NSString alloc] initWithData:ivRaw encoding:NSUTF8StringEncoding]?:@"";
    while(ivStr.length<16)ivStr=[ivStr stringByAppendingString:@"0"];
    if(ivStr.length>16)ivStr=[ivStr substringToIndex:16];
    NSUInteger cipherStart=NSMaxRange(keyEnd);
    if(trimmed.length<=cipherStart+32)return nil;
    NSString *cipherHex=[trimmed substringWithRange:NSMakeRange(cipherStart,trimmed.length-cipherStart-32)];
    NSMutableData *cipherData=[NSMutableData dataWithCapacity:cipherHex.length/2];
    for(NSUInteger i=0;i+1<cipherHex.length;i+=2){
        unsigned int b=0;
        if(![[NSScanner scannerWithString:[cipherHex substringWithRange:NSMakeRange(i,2)]] scanHexInt:&b])return nil;
        uint8_t byte=(uint8_t)b;
        [cipherData appendBytes:&byte length:1];
    }
    if(!cipherData.length)return nil;
    NSData *keyBytes=[keyStr dataUsingEncoding:NSUTF8StringEncoding];
    NSData *ivBytes=[ivStr dataUsingEncoding:NSUTF8StringEncoding];
    size_t bufSize=cipherData.length+kCCBlockSizeAES128;
    void *buf=malloc(bufSize);
    if(!buf)return nil;
    size_t decLen=0;
    CCCryptorStatus st=CCCrypt(kCCDecrypt,kCCAlgorithmAES128,kCCOptionPKCS7Padding,keyBytes.bytes,kCCKeySizeAES128,ivBytes.bytes,cipherData.bytes,cipherData.length,buf,bufSize,&decLen);
    if(st==kCCSuccess&&decLen>0){
        return [NSData dataWithBytesNoCopy:buf length:decLen freeWhenDone:YES];
    }
    free(buf);
    return nil;
}

static NSData *TVBoxSanitizeJSONData(NSData *data) {
    if(!data.length)return data;
    // Strip UTF-8 BOM if present
    if(data.length>=3&&memcmp(data.bytes,"\xEF\xBB\xBF",3)==0){
        data=[data subdataWithRange:NSMakeRange(3,data.length-3)];
    }
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if(!text.length)text=[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if(!text.length)return data;
    NSString *trimmed=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // 1. Check TVBox ** Base64 wrapper (e.g. header**eyJ...)
    NSRange starRange=[trimmed rangeOfString:@"**"];
    if(starRange.location!=NSNotFound&&NSMaxRange(starRange)<trimmed.length){
        NSString *b64Part=[[trimmed substringFromIndex:NSMaxRange(starRange)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSData *b64Decoded=[[NSData alloc] initWithBase64EncodedString:b64Part options:NSDataBase64DecodingIgnoreUnknownCharacters];
        NSString *b64Text=b64Decoded.length?[[NSString alloc] initWithData:b64Decoded encoding:NSUTF8StringEncoding]:nil;
        if(b64Text.length&&([b64Text containsString:@"{"]||[b64Text containsString:@"["])){
            text=b64Text;
            trimmed=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        }
    }
    // 2. Check TVBox 2423 ($#...#$) Hex AES-128-CBC wrapper
    if([trimmed.lowercaseString hasPrefix:@"2423"]){
        NSData *dec2423=TVBoxTryDecryptHex2423Payload(trimmed);
        NSString *decText=dec2423.length?[[NSString alloc] initWithData:dec2423 encoding:NSUTF8StringEncoding]:nil;
        if(decText.length&&([decText containsString:@"{"]||[decText containsString:@"["])){
            text=decText;
            trimmed=[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        }
    }
    // 3. Check pure Base64 JSON config
    if(![trimmed hasPrefix:@"{"]&&![trimmed hasPrefix:@"["]&&![trimmed hasPrefix:@"/"]&&trimmed.length>=24){
        NSData *b64Decoded=[[NSData alloc] initWithBase64EncodedString:trimmed options:NSDataBase64DecodingIgnoreUnknownCharacters];
        NSString *b64Text=b64Decoded.length?[[NSString alloc] initWithData:b64Decoded encoding:NSUTF8StringEncoding]:nil;
        if(b64Text.length){
            NSString *b64Trim=[b64Text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if([b64Trim hasPrefix:@"{"]||[b64Trim hasPrefix:@"["]||[b64Trim hasPrefix:@"//"]||[b64Trim hasPrefix:@"/*"]){
                text=b64Text;
                trimmed=b64Trim;
            }
        }
    }
    // 4. Strip // and /* */ comments and trailing commas outside string literals
    NSData *cleaned=TVBoxStripCommentsAndTrailingCommas(text);
    return cleaned.length?cleaned:data;
}

static NSString *TVBoxExportFilename(NSString *name) {
    NSString *base=[name isKindOfClass:NSString.class]?name:@"资源合集";
    base=[base stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>\n\r"];
    NSMutableString *safe=[NSMutableString string];
    [base enumerateSubstringsInRange:NSMakeRange(0,base.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *substring,NSRange substringRange,NSRange enclosingRange,BOOL *stop){
        [safe appendString:([substring rangeOfCharacterFromSet:invalid].location==NSNotFound&&[substring rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound)?substring:@"_"];
        if(safe.length>=64)*stop=YES;
    }];
    base=[safe stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!base.length)base=@"资源合集";
    return base;
}

static void TVBoxAppendLE16(NSMutableData *data,uint16_t value) {uint8_t bytes[2]={(uint8_t)value,(uint8_t)(value>>8)};[data appendBytes:bytes length:sizeof(bytes)];}
static void TVBoxAppendLE32(NSMutableData *data,uint32_t value) {uint8_t bytes[4]={(uint8_t)value,(uint8_t)(value>>8),(uint8_t)(value>>16),(uint8_t)(value>>24)};[data appendBytes:bytes length:sizeof(bytes)];}
static uint16_t TVBoxReadLE16(const uint8_t *b,NSUInteger n){return (uint16_t)b[n]|((uint16_t)b[n+1]<<8);}
static uint32_t TVBoxReadLE32(const uint8_t *b,NSUInteger n){return (uint32_t)TVBoxReadLE16(b,n)|((uint32_t)TVBoxReadLE16(b,n+2)<<16);}
static uint16_t TVBoxReadBE16(const uint8_t *b,NSUInteger n){return (uint16_t)((b[n]<<8)|b[n+1]);}

static NSDictionary<NSString *,NSData *> *TVBoxExtractZIPEntries(NSData *archiveData) {
    if(!archiveData.length||archiveData.length<22||archiveData.length>32*1024*1024)return nil;
    const uint8_t *b=(const uint8_t *)archiveData.bytes;
    NSUInteger length=archiveData.length;
    if(memcmp(b,"PK\003\004",4)!=0)return nil;
    NSUInteger eocd=NSNotFound,minimum=length>65557?length-65557:0;
    for(NSUInteger p=length-22;;p--){
        if(TVBoxReadLE32(b,p)==0x06054b50&&p+22+TVBoxReadLE16(b,p+20)<=length){eocd=p;break;}
        if(p==minimum)break;
    }
    if(eocd==NSNotFound)return nil;
    NSUInteger count=TVBoxReadLE16(b,eocd+10),size=TVBoxReadLE32(b,eocd+12),offset=TVBoxReadLE32(b,eocd+16);
    if(!count||count>2048||offset+size>eocd)return nil;
    NSMutableDictionary<NSString *,NSData *> *entries=[NSMutableDictionary dictionary];
    NSUInteger p=offset,totalExpanded=0;
    for(NSUInteger idx=0;idx<count;idx++){
        if(p+46>offset+size||TVBoxReadLE32(b,p)!=0x02014b50)return nil;
        NSUInteger flags=TVBoxReadLE16(b,p+8),method=TVBoxReadLE16(b,p+10),compressed=TVBoxReadLE32(b,p+20),expanded=TVBoxReadLE32(b,p+24),nameLen=TVBoxReadLE16(b,p+28),extra=TVBoxReadLE16(b,p+30),comment=TVBoxReadLE16(b,p+32),local=TVBoxReadLE32(b,p+42);
        if(p+46+nameLen+extra+comment>offset+size||!nameLen||(flags&1)||(method!=0&&method!=8)||expanded>24*1024*1024||totalExpanded+expanded>48*1024*1024||local>=offset)return nil;
        NSData *nameData=[archiveData subdataWithRange:NSMakeRange(p+46,nameLen)];
        NSString *name=[[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding];
        if(!name.length)name=[[NSString alloc] initWithData:nameData encoding:NSISOLatin1StringEncoding];
        p+=46+nameLen+extra+comment;
        if(!name.length||[name hasSuffix:@"/"]||[name hasPrefix:@"/"]||[name containsString:@".."]||[name containsString:@"__MACOSX"]||[name.lastPathComponent hasPrefix:@"."])continue;
        if(local+30>offset||TVBoxReadLE32(b,local)!=0x04034b50)return nil;
        NSUInteger localName=TVBoxReadLE16(b,local+26),localExtra=TVBoxReadLE16(b,local+28),body=local+30+localName+localExtra;
        if(body>offset||compressed>offset-body)return nil;
        NSMutableData *out=[NSMutableData dataWithLength:expanded];
        if(method==0){
            if(compressed!=expanded)continue;
            if(expanded)memcpy(out.mutableBytes,b+body,expanded);
        }else{
            uint8_t dummy=0;
            z_stream strm={0};
            strm.next_in=(Bytef *)(b+body);
            strm.avail_in=(uInt)compressed;
            strm.next_out=expanded?out.mutableBytes:&dummy;
            strm.avail_out=(uInt)MAX(expanded,(NSUInteger)1);
            if(inflateInit2(&strm,-MAX_WBITS)!=Z_OK)continue;
            int zres=inflate(&strm,Z_FINISH);
            inflateEnd(&strm);
            if(zres!=Z_STREAM_END||strm.total_out!=expanded)continue;
        }
        totalExpanded+=expanded;
        entries[name]=out;
    }
    return entries.count?entries:nil;
}

static NSDictionary<NSString *,NSDictionary *> *TVBoxExtractClassConfigsFromJAR(NSData *jarData) {
    NSDictionary<NSString *,NSData *> *entries=TVBoxExtractZIPEntries(jarData);
    if(!entries.count)return @{};
    NSMutableDictionary<NSString *,NSDictionary *> *result=[NSMutableDictionary dictionary];
    for(NSString *entryName in entries){
        if(![entryName hasPrefix:@"com/github/catvod/spider/"]||![entryName hasSuffix:@".class"]||[entryName containsString:@"$"])continue;
        NSString *clsName=[[entryName lastPathComponent] stringByDeletingPathExtension];
        if(!clsName.length)continue;
        NSData *clsData=entries[entryName];
        if(clsData.length<16)continue;
        const uint8_t *b=(const uint8_t *)clsData.bytes;
        if(b[0]!=0xCA||b[1]!=0xFE||b[2]!=0xBA||b[3]!=0xBE)continue;
        uint16_t cpCount=TVBoxReadBE16(b,8);
        NSUInteger pos=10;
        uint16_t idx=1;
        NSMutableArray<NSString *> *urls=[NSMutableArray array];
        NSMutableArray<NSString *> *keys=[NSMutableArray array];
        while(idx<cpCount&&pos<clsData.length){
            uint8_t tag=b[pos++];
            if(tag==1){
                if(pos+2>clsData.length)break;
                uint16_t uLen=TVBoxReadBE16(b,pos);
                pos+=2;
                if(pos+uLen>clsData.length)break;
                NSString *s=[[NSString alloc] initWithBytes:b+pos length:uLen encoding:NSUTF8StringEncoding];
                pos+=uLen;
                if(s.length){
                    NSString *clean=[s stringByReplacingOccurrencesOfString:@"\x01" withString:@""];
                    clean=[clean stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    NSString *low=clean.lowercaseString;
                    if(([low hasPrefix:@"http://"]||[low hasPrefix:@"https://"])&&clean.length>=11&&clean.length<=256&&![low containsString:@"127.0.0.1"]&&![low containsString:@"error.com"]&&![low containsString:@"google.com"]&&![low containsString:@"baidu.con"]&&![low containsString:@"servicewechat.com"]&&![low containsString:@"x.com/api"]&&![low containsString:@"gtimg.com"]&&![low containsString:@"image.tmdb.org"]){
                        if(![urls containsObject:clean])[urls addObject:clean];
                    }else if((s.length==16||s.length==32)&&![s hasPrefix:@"http"]&&![s containsString:@"/"]&&![s containsString:@"."]&&![s isEqualToString:@"0123456789abcdef"]&&![s isEqualToString:@"0123456789ABCDEF"]&&![s isEqualToString:@"0000000000000000"]&&![s isEqualToString:@"00000000000000000000000000000000"]&&![s isEqualToString:@"BootstrapMethods"]&&![s isEqualToString:@"setRequestMethod"]&&![s isEqualToString:@"equalsIgnoreCase"]&&![s isEqualToString:@"getParameterSpec"]&&![s isEqualToString:@"FALLBACK_PLAYERS"]&&![s isEqualToString:@"FALLBACK_PARSERS"]&&![s isEqualToString:@"P_MAINTITLE_ATTR"]&&![s isEqualToString:@"sec_device_token"]&&![s isEqualToString:@"video_definition"]&&![s isEqualToString:@"application/json"]&&![s isEqualToString:@"com.phoenix.read"]&&![s isEqualToString:@"action-adventure"]&&![s isEqualToString:@"AUDIO_CONFIG_BOX"]&&![s isEqualToString:@"HongGuoSign.java"]&&![s isEqualToString:@"hg-stream-worker"]&&![s isEqualToString:@"Content-Length: "]&&![s isEqualToString:@"x-requested-with"]&&![s isEqualToString:@"X-Requested-With"]&&![s isEqualToString:@"com.exxammpea.a1"]&&![s isEqualToString:@"synchronizedList"]&&![s isEqualToString:@"awaitTermination"]&&![s isEqualToString:@"quoteReplacement"]&&![s isEqualToString:@"x-ai-movie-nonce"]&&![s isEqualToString:@"normalized_title"]&&![s isEqualToString:@"fetchAllEpisodes"]&&![s isEqualToString:@"resolve_required"]&&![s isEqualToString:@"PROTOCOL_VERSION"]&&![s isEqualToString:@"App-Version-Code"]&&![s isEqualToString:@"filter_type_list"]&&![s isEqualToString:@"player_source_id"]&&![s isEqualToString:@"platform-version"]&&![s isEqualToString:@"getSocketFactory"]){
                        if([s rangeOfString:@"^[A-Za-z0-9!@#$%^&*()_+=-]{16,32}$" options:NSRegularExpressionSearch].location!=NSNotFound){
                            if(![keys containsObject:s])[keys addObject:s];
                        }
                    }
                }
            }else if(tag==7||tag==8||tag==16||tag==19||tag==20){
                pos+=2;
            }else if(tag==3||tag==4||tag==9||tag==10||tag==11||tag==12||tag==17||tag==18){
                pos+=4;
            }else if(tag==5||tag==6){
                pos+=8;
                idx++;
            }else if(tag==15){
                pos+=3;
            }else{
                break;
            }
            idx++;
        }
        if(urls.count){
            NSMutableDictionary *cfg=[@{@"url":urls.firstObject,@"sites":urls} mutableCopy];
            if(keys.count>=1)cfg[@"dataKey"]=keys[0];
            if(keys.count>=2)cfg[@"dataIv"]=keys[1];
            result[[@"csp_" stringByAppendingString:clsName].lowercaseString]=cfg.copy;
        }
    }
    return result.copy;
}

static NSData *TVBoxZIPData(NSDictionary<NSString *,NSData *> *files,NSError **error) {
    NSMutableData *archive=[NSMutableData data],*central=[NSMutableData data];NSUInteger entryCount=0;
    NSArray<NSString *> *paths=[[files allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for(NSString *path in paths){
        if(![path isKindOfClass:NSString.class]||!path.length||[path hasPrefix:@"/"]||[path containsString:@".."]||[path containsString:@"\\"]||[path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound){if(error)*error=TVBoxError(@"ZIP 文件路径无效");return nil;}
        NSData *plain=files[path];NSData *name=[path dataUsingEncoding:NSUTF8StringEncoding];if(!plain||!name.length||name.length>UINT16_MAX||plain.length>UINT32_MAX){if(error)*error=TVBoxError(@"资源 ZIP 中有文件超过格式限制");return nil;}
        z_stream stream={0};if(deflateInit2(&stream,Z_DEFAULT_COMPRESSION,Z_DEFLATED,-MAX_WBITS,8,Z_DEFAULT_STRATEGY)!=Z_OK){if(error)*error=TVBoxError(@"无法初始化 ZIP 压缩");return nil;}
        NSMutableData *compressed=[NSMutableData dataWithLength:MAX(64,compressBound((uLong)plain.length))];stream.next_in=(Bytef *)plain.bytes;stream.avail_in=(uInt)plain.length;stream.next_out=compressed.mutableBytes;stream.avail_out=(uInt)compressed.length;int zresult=deflate(&stream,Z_FINISH);if(zresult!=Z_STREAM_END){deflateEnd(&stream);if(error)*error=TVBoxError(@"压缩资源 ZIP 失败");return nil;}compressed.length=stream.total_out;deflateEnd(&stream);
        if(compressed.length>UINT32_MAX||archive.length>UINT32_MAX||central.length>UINT32_MAX){if(error)*error=TVBoxError(@"资源 ZIP 超过 4 GiB 格式限制");return nil;}
        uint32_t crc=(uint32_t)crc32(0,plain.bytes,(uInt)plain.length),offset=(uint32_t)archive.length;
        TVBoxAppendLE32(archive,0x04034b50);TVBoxAppendLE16(archive,20);TVBoxAppendLE16(archive,0x0800);TVBoxAppendLE16(archive,8);TVBoxAppendLE16(archive,0);TVBoxAppendLE16(archive,0x0021);TVBoxAppendLE32(archive,crc);TVBoxAppendLE32(archive,(uint32_t)compressed.length);TVBoxAppendLE32(archive,(uint32_t)plain.length);TVBoxAppendLE16(archive,(uint16_t)name.length);TVBoxAppendLE16(archive,0);[archive appendData:name];[archive appendData:compressed];
        TVBoxAppendLE32(central,0x02014b50);TVBoxAppendLE16(central,20);TVBoxAppendLE16(central,20);TVBoxAppendLE16(central,0x0800);TVBoxAppendLE16(central,8);TVBoxAppendLE16(central,0);TVBoxAppendLE16(central,0x0021);TVBoxAppendLE32(central,crc);TVBoxAppendLE32(central,(uint32_t)compressed.length);TVBoxAppendLE32(central,(uint32_t)plain.length);TVBoxAppendLE16(central,(uint16_t)name.length);TVBoxAppendLE16(central,0);TVBoxAppendLE16(central,0);TVBoxAppendLE16(central,0);TVBoxAppendLE16(central,0);TVBoxAppendLE32(central,0);TVBoxAppendLE32(central,offset);[central appendData:name];entryCount++;
    }
    if(entryCount>UINT16_MAX||archive.length>UINT32_MAX||central.length>UINT32_MAX){if(error)*error=TVBoxError(@"资源 ZIP 超过经典 ZIP 格式限制");return nil;}
    uint32_t centralOffset=(uint32_t)archive.length;[archive appendData:central];TVBoxAppendLE32(archive,0x06054b50);TVBoxAppendLE16(archive,0);TVBoxAppendLE16(archive,0);TVBoxAppendLE16(archive,(uint16_t)entryCount);TVBoxAppendLE16(archive,(uint16_t)entryCount);TVBoxAppendLE32(archive,(uint32_t)central.length);TVBoxAppendLE32(archive,centralOffset);TVBoxAppendLE16(archive,0);return archive;
}

static NSString *TVBoxBasicAuthorization(NSURLComponents *parts) {
    if (!parts.user.length && !parts.password.length) return nil;
    NSString *user = parts.percentEncodedUser.stringByRemovingPercentEncoding ?: @"";
    NSString *password = parts.percentEncodedPassword.stringByRemovingPercentEncoding ?: @"";
    NSData *credentials = [[NSString stringWithFormat:@"%@:%@", user, password] dataUsingEncoding:NSUTF8StringEncoding];
    return credentials.length ? [@"Basic " stringByAppendingString:[credentials base64EncodedStringWithOptions:0]] : nil;
}

static BOOL TVBoxSupportedJARClass(NSString *api) {
    if(![api isKindOfClass:NSString.class])return NO;
    NSString *low=api.lowercaseString;
    static NSSet *set;static dispatch_once_t once;
    dispatch_once(&once,^{
        set=[NSSet setWithArray:@[
            @"csp_xbpq", @"csp_xyqhiker", @"csp_xpath", @"csp_music1",
            @"csp_appget", @"csp_appdrama", @"csp_appysv2", @"csp_apprj",
            @"csp_app99", @"csp_app3q", @"csp_appqi", @"csp_appsy", @"csp_appyqk",
            @"csp_bili", @"csp_biliys", @"csp_panwebshare", @"csp_wogg", @"csp_pansearch",
            @"csp_hxq", @"csp_sp360", @"csp_tvyb", @"csp_pianku8", @"csp_feiyu",
            @"csp_duboku", @"csp_czsapp", @"csp_xlys", @"csp_wwys", @"csp_fengye",
            @"csp_ikanbot", @"csp_web1905", @"csp_tuxiaobei", @"csp_beilehu",
            @"csp_yst", @"csp_qimaodj", @"csp_hemadj", @"csp_weiguandj",
            @"csp_haokandj", @"csp_xingyadj", @"csp_miaowu", @"csp_modu",
            @"csp_kanqiu", @"csp_qiutongty", @"csp_guazity",
            @"csp_kafeity", @"csp_919ty", @"csp_firstaid", @"csp_djuu",
            @"csp_djlh", @"csp_qingtingfm", @"csp_tingshijie", @"csp_apply",
            @"csp_gz360", @"csp_saohuo", @"csp_jpys",
            @"csp_panali", @"csp_panquark", @"csp_panuc", @"csp_panbaidu",
            @"csp_config",
            // 初忆 (cycod/tvbox) & 刺桐 (cttv.vip/ctys.json) 专属爬虫类
            @"csp_hongguo", @"csp_sikv4k", @"csp_gz", @"csp_duoduo", @"csp_gulu",
            @"csp_hetun", @"csp_huayi", @"csp_juzhi", @"csp_piandi", @"csp_yingtan",
            @"csp_fengye4k", @"csp_juxiafan", @"csp_shanzha4k", @"csp_daishu",
            @"csp_dongmanbashi", @"csp_dbku", @"csp_fandazi", @"csp_fourkmp",
            @"csp_jbd", @"csp_jianpian", @"csp_nongmin", @"csp_rejutv", @"csp_tegou",
            @"csp_yunbo", @"csp_wftv", @"csp_yingxiang", @"csp_zjdr", @"csp_zhuiying",
            @"csp_luoxuetv", @"csp_kishuto", @"csp_ttian", @"csp_xdai", @"csp_qiji",
            @"csp_qiao2", @"csp_muou", @"csp_nmvod", @"csp_bdys01", @"csp_lib",
            @"csp_zxzj", @"csp_ddrk", @"csp_kuaikan", @"csp_auete", @"csp_dygang",
            @"csp_shark", @"csp_hudie", @"csp_ai"
        ]];
    });
    if([set containsObject:low])return YES;
    return [low hasPrefix:@"csp_"]&&![low isEqualToString:@"csp_doudou"]&&![low isEqualToString:@"csp_douban"]&&![low isEqualToString:@"csp_example"];
}

static NSString *TVBoxInferredCatalogPrefixName(NSArray *sites) {
    if(![sites isKindOfClass:NSArray.class]||!sites.count)return nil;
    NSCountedSet *prefixes=[NSCountedSet set];
    for(id item in sites){
        if(![item isKindOfClass:NSDictionary.class])continue;
        NSString *sName=[item[@"name"] isKindOfClass:NSString.class]?item[@"name"]:@"";
        for(NSString *sep in @[@"┃",@"｜",@"|",@"•",@"·"]){
            NSRange r=[sName rangeOfString:sep];
            if(r.location!=NSNotFound&&r.location>=2&&r.location<=8){
                NSString *p=[[sName substringToIndex:r.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if(p.length>=2)[prefixes addObject:p];
                break;
            }
        }
    }
    NSString *best=nil;NSUInteger bestCount=0;
    for(NSString *p in prefixes){
        NSUInteger c=[prefixes countForObject:p];
        if(c>bestCount&&c>=2){bestCount=c;best=p;}
    }
    return best.length?[NSString stringWithFormat:@"%@ · TVBox 合集",best]:nil;
}

static void TVBoxNotifyAdaptationMonitorCatalog(NSString *name, NSString *sourceURL, NSUInteger siteCount, NSUInteger supportedCount, NSUInteger liveCount, NSString *bundleType, BOOL jarVerified, NSString *notes) {
    Class cls=NSClassFromString(@"MediaAdaptationMonitor");
    if(!cls)return;
    SEL sharedSel=NSSelectorFromString(@"shared");
    if(![cls respondsToSelector:sharedSel])return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id monitor=[cls performSelector:sharedSel];
#pragma clang diagnostic pop
    SEL recordSel=NSSelectorFromString(@"recordCatalogEventWithName:sourceURL:siteCount:supportedCount:liveCount:bundleType:jarVerified:notes:");
    if(monitor&&[monitor respondsToSelector:recordSel]){
        ((void (*)(id, SEL, NSString *, NSString *, NSUInteger, NSUInteger, NSUInteger, NSString *, BOOL, NSString *))objc_msgSend)(monitor, recordSel, name?:@"资源合集", sourceURL?:@"", siteCount, supportedCount, liveCount, bundleType?:@"tvbox-json", jarVerified, notes?:@"");
    }
}

@implementation TVBoxCatalogStore

+ (nullable NSData *)sanitizeJSONData:(NSData *)data {
    return TVBoxSanitizeJSONData(data);
}

+ (nullable NSString *)decodeQiaojiExtString:(NSString *)rawExt {
    return TVBoxDecodeQiaojiExt(rawExt);
}

+ (NSDictionary *)catalogWithMacCMSAPIURL:(NSString *)apiURL name:(NSString *)name error:(NSError **)error {
    NSString *trimmed=[apiURL stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!TVBoxWebURL(trimmed)){if(error)*error=TVBoxError(@"MacCMS 接口必须是有效的 HTTP/HTTPS 地址，且不能包含用户名或密码");return nil;}
    NSURLComponents *parts=[NSURLComponents componentsWithString:trimmed];
    if(parts.fragment.length){if(error)*error=TVBoxError(@"接口 URL 不能包含片段标记 #");return nil;}
    NSString *displayName=[name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!displayName.length)displayName=parts.host?:@"MacCMS 影视源";
    if(displayName.length>256){if(error)*error=TVBoxError(@"来源名称不能超过 256 个字符");return nil;}
    NSString *siteKey=[NSString stringWithFormat:@"maccms-%@",NSUUID.UUID.UUIDString.lowercaseString];
    NSDictionary *site=@{@"key":siteKey,@"name":displayName,@"api":trimmed,@"type":@"maccms",@"apiKind":@"maccms-api",@"supported":@YES,@"status":@"尚未验证 · 选中后读取",@"maccmsFormat":@"auto"};
    return @{@"id":NSUUID.UUID.UUIDString.lowercaseString,@"name":displayName,@"sites":@[site],@"lives":@[],@"url":trimmed,@"updatedAt":@(NSDate.date.timeIntervalSince1970),@"catalogKind":@"maccms"};
}

+ (nullable NSDictionary *)parseBundleEntries:(NSDictionary<NSString *,NSData *> *)entries bundleTitle:(nullable NSString *)bundleTitle sourceURL:(nullable NSString *)sourceURL error:(NSError **)error {
    if(!entries.count)return nil;
    // Strip common top-level folder prefix if all entries are inside e.g. "tvbox-local/"
    NSMutableSet<NSString *> *topDirs=[NSMutableSet set];
    for(NSString *path in entries){
        NSArray<NSString *> *parts=path.pathComponents;
        if(parts.count>1)[topDirs addObject:parts.firstObject];
        else [topDirs addObject:@""];
    }
    NSDictionary<NSString *,NSData *> *normalizedEntries=entries;
    if(topDirs.count==1&&![topDirs.anyObject isEqualToString:@""]){
        NSString *prefix=[topDirs.anyObject stringByAppendingString:@"/"];
        NSMutableDictionary<NSString *,NSData *> *stripped=[NSMutableDictionary dictionaryWithCapacity:entries.count];
        for(NSString *path in entries){
            NSString *rel=[path hasPrefix:prefix]?[path substringFromIndex:prefix.length]:path;
            if(rel.length)stripped[rel]=entries[path];
        }
        if(stripped.count)normalizedEntries=stripped;
    }
    // Locate primary TVBox JSON config
    NSArray<NSString *> *preferredConfigs=@[@"api.json",@"config.json",@"tvbox.json",@"jsm.json",@"ctys.json",@"index.json",@"main.json"];
    NSString *mainConfigKey=nil;
    NSDictionary *mainConfigDict=nil;
    NSData *mainSanitizedData=nil;
    NSMutableArray<NSString *> *candidateKeys=[NSMutableArray array];
    for(NSString *pref in preferredConfigs){
        for(NSString *k in normalizedEntries){
            if([k.lowercaseString isEqualToString:pref]){[candidateKeys addObject:k];}
        }
    }
    for(NSString *k in [normalizedEntries.allKeys sortedArrayUsingSelector:@selector(compare:)]){
        NSString *low=k.lowercaseString;
        if([low hasSuffix:@".json"]&&![candidateKeys containsObject:k]&&![low hasSuffix:@".original.json"]&&![low isEqualToString:@"package.json"]&&![low isEqualToString:@"cctvhost.json"]&&![low isEqualToString:@"source-manifest.json"]&&![low containsString:@"/"]){
            [candidateKeys addObject:k];
        }
    }
    for(NSString *k in candidateKeys){
        NSData *raw=normalizedEntries[k];
        NSData *sanitized=TVBoxSanitizeJSONData(raw);
        id obj=sanitized.length?[NSJSONSerialization JSONObjectWithData:sanitized options:NSJSONReadingFragmentsAllowed error:NULL]:nil;
        if([obj isKindOfClass:NSDictionary.class]){
            NSDictionary *d=(NSDictionary *)obj;
            if([d[@"sites"] isKindOfClass:NSArray.class]||[d[@"lives"] isKindOfClass:NSArray.class]||[d[@"urls"] isKindOfClass:NSArray.class]||[d[@"storeHouse"] isKindOfClass:NSArray.class]){
                mainConfigKey=k;
                mainConfigDict=d;
                mainSanitizedData=sanitized;
                break;
            }
        }
    }
    if(!mainConfigDict||!mainConfigKey)return nil;

    // Inspect api.original.json and make_local.py / README.md for upstream origin and spider URLs
    NSDictionary *originalConfigDict=nil;
    for(NSString *k in normalizedEntries){
        if([k.lowercaseString hasSuffix:@"original.json"]){
            NSData *sanitizedOrig=TVBoxSanitizeJSONData(normalizedEntries[k]);
            id obj=sanitizedOrig.length?[NSJSONSerialization JSONObjectWithData:sanitizedOrig options:NSJSONReadingFragmentsAllowed error:NULL]:nil;
            if([obj isKindOfClass:NSDictionary.class]){originalConfigDict=obj;break;}
        }
    }
    NSString *inferredOrigin=sourceURL.length?sourceURL:@"";
    if(!TVBoxWebURL(inferredOrigin)){
        for(NSString *helperName in @[@"make_local.py",@"README.md",@"README.txt"]){
            NSData *hData=normalizedEntries[helperName];
            NSString *hText=hData.length?[[NSString alloc] initWithData:hData encoding:NSUTF8StringEncoding]:nil;
            if(!hText.length)continue;
            NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"https?://[^\\s\"'<>\\)]+\\.json" options:NSRegularExpressionCaseInsensitive error:NULL];
            NSTextCheckingResult *m=[re firstMatchInString:hText options:0 range:NSMakeRange(0,hText.length)];
            if(m){
                NSString *found=[hText substringWithRange:m.range];
                if(TVBoxWebURL(found)&&![found containsString:@"127.0.0.1"]&&![found containsString:@"localhost"]){
                    inferredOrigin=found;
                    break;
                }
            }
        }
    }
    if(!TVBoxWebURL(inferredOrigin)&&[originalConfigDict[@"spider"] isKindOfClass:NSString.class]){
        NSString *origSpider=[originalConfigDict[@"spider"] componentsSeparatedByString:@";"].firstObject;
        if(TVBoxWebURL(origSpider)){
            NSURL *sURL=[NSURL URLWithString:origSpider];
            NSURL *apiURL=[NSURL URLWithString:@"api.json" relativeToURL:sURL].absoluteURL;
            if(TVBoxWebURL(apiURL.absoluteString))inferredOrigin=apiURL.absoluteString;
        }
    }
    NSString *catalogID=NSUUID.UUID.UUIDString;
    NSString *effectiveOrigin=TVBoxWebURL(inferredOrigin)?inferredOrigin:[NSString stringWithFormat:@"https://local.tvbox.bundle/%@/api.json",catalogID.lowercaseString];

    // Locate bundled .jar (e.g. spider.jar) and extract class constants
    NSData *jarData=nil;
    NSString *jarEntryName=nil;
    NSString *spiderField=[mainConfigDict[@"spider"] isKindOfClass:NSString.class]?mainConfigDict[@"spider"]:@"";
    NSString *spiderRel=[[spiderField componentsSeparatedByString:@";"].firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if([spiderRel hasPrefix:@"./"])spiderRel=[spiderRel substringFromIndex:2];
    if(spiderRel.length&&normalizedEntries[spiderRel]){
        jarData=normalizedEntries[spiderRel];
        jarEntryName=spiderRel;
    }
    if(!jarData){
        for(NSString *k in normalizedEntries){
            if([k.pathExtension.lowercaseString isEqualToString:@"jar"]){
                jarData=normalizedEntries[k];
                jarEntryName=k;
                break;
            }
        }
    }
    NSDictionary<NSString *,NSDictionary *> *jarClassConfigs=jarData.length?TVBoxExtractClassConfigsFromJAR(jarData):@{};

    // Merge local config with original remote references & JAR class constants
    NSMutableDictionary *mergedJSON=[mainConfigDict mutableCopy];
    NSString *origSpider=[originalConfigDict[@"spider"] isKindOfClass:NSString.class]?originalConfigDict[@"spider"]:@"";
    NSString *resolvedSpiderURL=@"";
    NSString *declaredMD5=@"";
    NSArray<NSString *> *spiderParts=[spiderField componentsSeparatedByString:@";md5;"];
    if(spiderParts.count==2)declaredMD5=[spiderParts[1] lowercaseString];
    if(origSpider.length&&TVBoxWebURL([origSpider componentsSeparatedByString:@";"].firstObject)){
        mergedJSON[@"spider"]=origSpider;
        resolvedSpiderURL=[origSpider componentsSeparatedByString:@";"].firstObject;
        NSArray<NSString *> *origParts=[origSpider componentsSeparatedByString:@";md5;"];
        if(!declaredMD5.length&&origParts.count==2)declaredMD5=[origParts[1] lowercaseString];
    }else if(spiderField.length){
        NSDictionary *jarRef=MediaJARReference(spiderField,effectiveOrigin);
        if(jarRef[@"url"])resolvedSpiderURL=jarRef[@"url"];
    }
    BOOL jarMD5Verified=NO;
    if(jarData.length){
        NSString *actualMD5=TVBoxHashHex(jarData,YES);
        jarMD5Verified=!declaredMD5.length||[actualMD5 isEqualToString:declaredMD5];
        if(resolvedSpiderURL.length){
            TVBoxPreseedJARRuntimeCache(jarData,resolvedSpiderURL,declaredMD5.length?declaredMD5:actualMD5);
        }
    }

    // Enrich sites in mergedJSON with local bundle ext files or extracted JAR class configs
    if([mergedJSON[@"sites"] isKindOfClass:NSArray.class]){
        NSMutableArray *enrichedSites=[NSMutableArray array];
        for(id rawSite in (NSArray *)mergedJSON[@"sites"]){
            if(![rawSite isKindOfClass:NSDictionary.class]){[enrichedSites addObject:rawSite];continue;}
            NSMutableDictionary *mSite=[rawSite mutableCopy];
            NSString *sApi=[mSite[@"api"] isKindOfClass:NSString.class]?mSite[@"api"]:@"";
            id sExt=mSite[@"ext"];
            if([sExt isKindOfClass:NSString.class]){
                NSString *extStr=[(NSString *)sExt stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                NSString *relExt=[extStr hasPrefix:@"./"]?[extStr substringFromIndex:2]:extStr;
                if(relExt.length&&normalizedEntries[relExt]){
                    NSString *inlineText=[[NSString alloc] initWithData:normalizedEntries[relExt] encoding:NSUTF8StringEncoding];
                    if(inlineText.length&&inlineText.length<=65536)mSite[@"ext"]=inlineText;
                }
            }else if((!sExt||sExt==NSNull.null||(![sExt isKindOfClass:NSDictionary.class]&&![sExt isKindOfClass:NSArray.class]&&![(NSString *)sExt length]))&&jarClassConfigs[sApi.lowercaseString]){
                mSite[@"ext"]=jarClassConfigs[sApi.lowercaseString];
            }
            [enrichedSites addObject:mSite];
        }
        mergedJSON[@"sites"]=enrichedSites;
    }

    // Persist companion files under Bundles/<catalogID>/
    NSString *bundleDir=[TVBoxCatalogBundlesDirectory() stringByAppendingPathComponent:catalogID];
    [NSFileManager.defaultManager createDirectoryAtPath:bundleDir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSMutableArray<NSString *> *savedFiles=[NSMutableArray array];
    for(NSString *relPath in normalizedEntries){
        NSString *dest=[bundleDir stringByAppendingPathComponent:relPath];
        [NSFileManager.defaultManager createDirectoryAtPath:dest.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
        if([normalizedEntries[relPath] writeToFile:dest options:NSDataWritingAtomic error:NULL]){
            [savedFiles addObject:relPath];
        }
    }

    NSData *mergedData=[NSJSONSerialization dataWithJSONObject:mergedJSON options:0 error:NULL]?:mainSanitizedData;
    NSMutableDictionary *catalog=[[self parseData:mergedData sourceURL:effectiveOrigin error:error] mutableCopy];
    if(!catalog)return nil;
    catalog[@"id"]=catalogID;
    catalog[@"_sourceConfigData"]=mainSanitizedData;
    if(!mergedJSON[@"name"]&&!mergedJSON[@"title"]){
        NSString *inferredPrefix=TVBoxInferredCatalogPrefixName(mergedJSON[@"sites"]);
        if(bundleTitle.length&&![bundleTitle.lowercaseString isEqualToString:@"api"]&&![bundleTitle.lowercaseString isEqualToString:@"config"]&&![bundleTitle.lowercaseString isEqualToString:@"tvbox-local"]){
            catalog[@"name"]=bundleTitle;
        }else if(inferredPrefix.length){
            catalog[@"name"]=inferredPrefix;
        }
    }
    catalog[@"catalogKind"]=@"tvbox-local-bundle";
    NSMutableDictionary *bundleMeta=[@{
        @"isLocalBundle":@YES,
        @"bundleDirectory":bundleDir,
        @"mainConfigFile":mainConfigKey,
        @"companionFiles":savedFiles.copy,
        @"hasOriginalConfig":@(originalConfigDict!=nil),
        @"jarBundled":@(jarData.length>0),
        @"jarMD5Verified":@(jarMD5Verified),
        @"jarExtractedClassCount":@(jarClassConfigs.count)
    } mutableCopy];
    if(jarEntryName.length)bundleMeta[@"jarFile"]=jarEntryName;
    if(declaredMD5.length)bundleMeta[@"jarMD5"]=declaredMD5;
    if(resolvedSpiderURL.length)bundleMeta[@"resolvedSpiderURL"]=resolvedSpiderURL;
    catalog[@"bundleMetadata"]=bundleMeta.copy;

    NSUInteger supportedCount=0;
    for(NSDictionary *s in catalog[@"sites"]?:@[])if([s[@"supported"] boolValue])supportedCount++;
    TVBoxNotifyAdaptationMonitorCatalog(catalog[@"name"], effectiveOrigin, [catalog[@"sites"] count], supportedCount, [catalog[@"lives"] count], @"tvbox-local-bundle", jarMD5Verified, [NSString stringWithFormat:@"本地集合包 · JAR 校验:%@ · 提取常量类:%lu", jarMD5Verified?@"通过":@"未声明", (unsigned long)jarClassConfigs.count]);
    return catalog.copy;
}

+ (nullable NSDictionary *)parseBundleArchiveData:(NSData *)data fileURL:(nullable NSURL *)fileURL sourceURL:(nullable NSString *)sourceURL error:(NSError **)error {
    NSDictionary<NSString *,NSData *> *entries=TVBoxExtractZIPEntries(data);
    if(!entries.count)return nil;
    NSString *title=fileURL.lastPathComponent.stringByDeletingPathExtension;
    return [self parseBundleEntries:entries bundleTitle:title sourceURL:sourceURL error:error];
}

+ (nullable NSDictionary *)parseBundleDirectoryAtURL:(NSURL *)directoryURL error:(NSError **)error {
    if(!directoryURL.isFileURL)return nil;
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *rootPath=directoryURL.path;
    BOOL isDir=NO;
    if(![fm fileExistsAtPath:rootPath isDirectory:&isDir]||!isDir)return nil;
    NSDirectoryEnumerator *enumerator=[fm enumeratorAtURL:directoryURL includingPropertiesForKeys:@[NSURLIsRegularFileKey,NSURLFileSizeKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *url,NSError *err){return YES;}];
    NSMutableDictionary<NSString *,NSData *> *entries=[NSMutableDictionary dictionary];
    NSUInteger totalBytes=0;
    for(NSURL *fileURL in enumerator){
        NSNumber *regular=nil,*size=nil;
        [fileURL getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];
        [fileURL getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
        if(!regular.boolValue||size.unsignedLongLongValue>24*1024*1024||totalBytes+size.unsignedLongLongValue>48*1024*1024)continue;
        NSString *fullPath=fileURL.path;
        if(![fullPath hasPrefix:rootPath])continue;
        NSString *rel=[fullPath substringFromIndex:rootPath.length];
        while([rel hasPrefix:@"/"])rel=[rel substringFromIndex:1];
        if(!rel.length||[rel containsString:@"__MACOSX"])continue;
        NSData *d=[NSData dataWithContentsOfURL:fileURL options:NSDataReadingMappedIfSafe error:NULL];
        if(d){entries[rel]=d;totalBytes+=d.length;}
    }
    if(!entries.count)return nil;
    return [self parseBundleEntries:entries bundleTitle:directoryURL.lastPathComponent sourceURL:nil error:error];
}

+ (NSDictionary *)parseData:(NSData *)data sourceURL:(NSString *)sourceURL error:(NSError **)error {
    if (!data.length) { if(error)*error=TVBoxError(@"TVBox 配置为空或超过 8 MiB"); return nil; }
    // Detect TVBox Local Collection Bundle ZIP archives (e.g. 初忆本地包1110.zip)
    if (data.length >= 4 && memcmp(data.bytes, "PK\003\004", 4) == 0) {
        if (data.length <= 32*1024*1024) {
            NSDictionary *bundleCatalog=[self parseBundleArchiveData:data fileURL:nil sourceURL:sourceURL error:error];
            if (bundleCatalog) return bundleCatalog;
        }
        if(error&&!*error)*error=TVBoxError(@"TVBox 配置必须是 JSON 对象");
        return nil;
    }
    if (data.length > 8*1024*1024) { if(error)*error=TVBoxError(@"TVBox 配置为空或超过 8 MiB"); return nil; }
    NSError *jsonError=nil;
    BOOL usedSanitized=NO;
    id rawJSON=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:&jsonError];
    NSData *sanitizedData=data;
    if (!rawJSON) {
        sanitizedData=TVBoxSanitizeJSONData(data);
        if (sanitizedData.length) {
            jsonError=nil;
            rawJSON=[NSJSONSerialization JSONObjectWithData:sanitizedData options:NSJSONReadingFragmentsAllowed error:&jsonError];
            if (rawJSON) usedSanitized=YES;
        }
    }
    NSDictionary *json=[rawJSON isKindOfClass:NSDictionary.class]?rawJSON:nil;
    if (!json && [rawJSON isKindOfClass:NSArray.class] && [(NSArray *)rawJSON count]) {
        json=@{@"name":([sourceURL.lowercaseString containsString:@"webox"]?@"WeBox 影视源合集":@"资源合集"),@"sites":rawJSON};
    }
    if (![json isKindOfClass:NSDictionary.class]) { if(error)*error=jsonError?:TVBoxError(@"TVBox 配置必须是 JSON 对象"); return nil; }
    if (![json[@"sites"] isKindOfClass:NSArray.class] && [json[@"data"] isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *merged=[json mutableCopy];
        [merged addEntriesFromDictionary:(NSDictionary *)json[@"data"]];
        json=merged.copy;
    }
    NSArray *sites=[json[@"sites"] isKindOfClass:NSArray.class]?json[@"sites"]:@[];
    // MacCMS content lists are not site indexes, even though both use "list".
    if(!sites.count && [json[@"list"] isKindOfClass:NSArray.class]){
        for(id row in json[@"list"])if([row isKindOfClass:NSDictionary.class] && (row[@"vod_id"]||row[@"vod_name"]||row[@"vod_play_url"])){
            if(error)*error=TVBoxError(@"这是 MacCMS 内容接口，不是 TVBox 合集");return nil;
        }
    }
    if (!sites.count) {
        for (NSString *altKey in @[@"sources",@"plugins",@"items",@"list",@"packages",@"modules",@"scripts",@"data"]) {
            if ([json[altKey] isKindOfClass:NSArray.class] && [json[altKey] count]) { sites=json[altKey]; break; }
        }
    }
    // Support TVBox multi-depot (urls / storeHouse / depots) repository index JSONs
    NSArray *depotList=nil;
    if (!sites.count) {
        for (NSString *depotKey in @[@"urls",@"storeHouse",@"depots"]) {
            if ([json[depotKey] isKindOfClass:NSArray.class] && [json[depotKey] count]) {
                depotList=json[depotKey];
                break;
            }
        }
    }
    NSArray *lives=[json[@"lives"] isKindOfClass:NSArray.class]?json[@"lives"]:@[];
    if (!sites.count && !lives.count && !depotList.count) { if(error)*error=TVBoxError(@"配置中没有可识别的 sites 或 lives"); return nil; }
    if (sites.count>2000 || lives.count>500) { if(error)*error=TVBoxError(@"站点或直播源数量超过 2000 / 500 项限制"); return nil; }
    NSMutableArray *cleanSites=[NSMutableArray array]; NSMutableSet *keys=[NSMutableSet set];NSUInteger siteIndex=0;
    NSUInteger qiaojiDecodedCount=0;
    for(id rawValue in sites) {
        siteIndex++;
        NSDictionary *value=[rawValue isKindOfClass:NSDictionary.class]?rawValue:nil;
        if (!value && [rawValue isKindOfClass:NSString.class] && [(NSString *)rawValue length]) {
            NSString *str=(NSString *)rawValue;
            NSString *itemName=[[str.lastPathComponent stringByRemovingPercentEncoding]?:str.lastPathComponent stringByDeletingPathExtension];
            if([itemName.lowercaseString hasSuffix:@".webox"])itemName=[itemName substringToIndex:itemName.length-6];
            value=@{@"name":itemName.length?itemName:[NSString stringWithFormat:@"站点 %lu",(unsigned long)siteIndex],@"api":str,@"type":@3};
        }
        if (![value isKindOfClass:NSDictionary.class]) continue;
        NSString *key=TVBoxString(value[@"key"] ?: value[@"id"],256), *name=TVBoxString(value[@"name"] ?: value[@"title"],256);
        NSString *rawApiField=TVBoxString(value[@"api"],8192);NSString *altUrlField=TVBoxString(value[@"url"] ?: value[@"script"] ?: value[@"scriptUrl"] ?: value[@"sourceUrl"] ?: value[@"entry"] ?: value[@"endpoint"] ?: value[@"file"] ?: value[@"path"] ?: value[@"downloadUrl"] ?: value[@"src"],8192);if(altUrlField.length&&(!rawApiField.length||[rawApiField rangeOfString:@"^\\d+(?:\\.\\d+)*$" options:NSRegularExpressionSearch].location!=NSNotFound))rawApiField=altUrlField;NSString *api=rawApiField;
        if(!key.length)key=[NSString stringWithFormat:@"site-%lu",(unsigned long)siteIndex];
        if(!name.length && api.length){
            NSString *inferred=[[api.lastPathComponent stringByRemovingPercentEncoding]?:api.lastPathComponent stringByDeletingPathExtension];
            if([inferred.lowercaseString hasSuffix:@".webox"])inferred=[inferred substringToIndex:inferred.length-6];
            if([inferred.lowercaseString hasSuffix:@".hjs"])inferred=[inferred substringToIndex:inferred.length-4];
            if(inferred.length)name=inferred;
        }
        if(!name.length)name=[NSString stringWithFormat:@"未命名站点 %lu",(unsigned long)siteIndex];
        if(api.length&&!MediaJARClass(api).length&&!TVBoxWebURL(api)&&TVBoxWebURL(sourceURL)){
            NSURL *base=[NSURL URLWithString:sourceURL];
            NSURL *resolved=[NSURL URLWithString:api relativeToURL:base].absoluteURL;
            if(!resolved){
                NSString *encodedApi=[api stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
                if(encodedApi.length)resolved=[NSURL URLWithString:encodedApi relativeToURL:base].absoluteURL;
            }
            if(TVBoxWebURL(resolved.absoluteString))api=resolved.absoluteString;
        }
        if(api.length&&!TVBoxWebURL(api)&&[api.lowercaseString hasSuffix:@".webox.js"]){
            NSURL *base=[NSURL URLWithString:@"https://ddgksf2013.top/webox/index.json"];
            NSString *encodedApi=[api stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]?:api;
            NSURL *resolved=[NSURL URLWithString:encodedApi relativeToURL:base].absoluteURL;
            if(TVBoxWebURL(resolved.absoluteString))api=resolved.absoluteString;
        }
        if([keys containsObject:key])key=[NSString stringWithFormat:@"%@-%lu",key,(unsigned long)siteIndex];
        [keys addObject:key];
        NSMutableDictionary *safeHeaders=[NSMutableDictionary dictionary];
        if([value[@"header"] isKindOfClass:NSDictionary.class]){NSUInteger headerCount=0;for(id headerKey in value[@"header"]){id headerValue=value[@"header"][headerKey];if(headerCount++>=24)break;if([headerKey isKindOfClass:NSString.class]&&[headerValue isKindOfClass:NSString.class]&&[headerKey length]<=128&&[headerValue length]<=4096)safeHeaders[headerKey]=headerValue;}}
        NSURLComponents *apiParts=TVBoxURLComponents(api?:@"");
        NSString *basicAuthorization=TVBoxBasicAuthorization(apiParts);
        if(basicAuthorization.length){apiParts.user=nil;apiParts.password=nil;api=apiParts.URL.absoluteString;BOOL hasAuthorization=NO;for(NSString *headerName in safeHeaders)if([headerName caseInsensitiveCompare:@"Authorization"]==NSOrderedSame){hasAuthorization=YES;break;}if(!hasAuthorization)safeHeaders[@"Authorization"]=basicAuthorization;}
        NSString *ext=TVBoxString(value[@"ext"],8192); id extObject=value[@"ext"];
        if ([extObject isKindOfClass:NSDictionary.class] || [extObject isKindOfClass:NSArray.class]) {
            NSData *encoded=[NSJSONSerialization dataWithJSONObject:extObject options:0 error:NULL];
            if (encoded.length<=65536) ext=[[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding]; else ext=nil;
        }
        if (ext.length && [ext.lowercaseString hasPrefix:@"7lj763gg"]) {
            NSString *decodedExt=TVBoxDecodeQiaojiExt(ext);
            if (decodedExt.length) qiaojiDecodedCount++;
        }
        apiParts=TVBoxURLComponents(api?:@"");
        NSString *path=apiParts.path.lowercaseString;
        if ([path hasSuffix:@".md5"]) path=[path stringByDeletingPathExtension];
        NSString *siteType=TVBoxString(value[@"type"],32)?:@"";BOOL scriptFile=[@[@"js",@"hjs",@"mjs",@"cjs",@"py",@"zip"] containsObject:path.pathExtension.lowercaseString];BOOL jarFile=[path.pathExtension.lowercaseString isEqual:@"jar"];BOOL jarSpiderClass=MediaJARClass(api).length>0;BOOL apiKindDouban=[siteType isEqual:@"3"]&&[api.lowercaseString isEqual:@"csp_doudou"];if([siteType isEqual:@"3"]&&[api.lowercaseString isEqual:@"csp_douban"])apiKindDouban=YES;BOOL apiKindJARBridge=[siteType isEqual:@"3"]&&!apiKindDouban&&(TVBoxSupportedJARClass(api)||[MediaJARClass(api) hasPrefix:@"com.github.catvod.spider."]);
        BOOL apiKindMacCMS=!scriptFile&&!jarFile&&TVBoxWebURL(api)&&[siteType isEqual:@"0"];
        BOOL apiKindTVBox=!scriptFile&&!jarFile&&TVBoxWebURL(api)&&([siteType isEqual:@"1"]||[siteType isEqual:@"4"]);
        BOOL direct=TVBoxWebURL(api)&&scriptFile;
        BOOL supported=direct||apiKindTVBox||apiKindMacCMS||apiKindDouban||apiKindJARBridge;
        NSString *reason=@"站点地址无效；保留在合集中";
        if(apiKindDouban)reason=@"豆瓣影视索引 · iOS 原生适配 · 影片需跨点播源搜索播放";
        else if(apiKindMacCMS)reason=@"TVBox type 0 · MacCMS JSON/XML API · 选中后请求";
        else if(apiKindTVBox)reason=[NSString stringWithFormat:@"TVBox type %@ JSON API · 选中后请求，尚未验证",siteType];
        else if(direct)reason=@"可导入 · 将由现有脚本适配器检查";
        else if(apiKindJARBridge)reason=@"站点接口适配 · 待读取验证";
        else if([siteType isEqual:@"0"])reason=@"TVBox type 0 为 JS 爬虫，需脚本文件地址；iOS 不支持此地址形式";
        else if([siteType isEqual:@"3"])reason=(jarFile||jarSpiderClass)?@"需要 Android/JAR 运行时；iOS 不支持":@"脚本地址无法识别；保留在合集中";
        else if([apiParts.scheme.lowercaseString isEqual:@"http"]||[apiParts.scheme.lowercaseString isEqual:@"https"])reason=@"此脚本类型需 Android/JAR 运行时；iOS 不支持";
        NSString *apiKind=apiKindDouban?@"douban-index":(apiKindMacCMS?@"maccms-api":(apiKindTVBox?@"tvbox-api":(direct?@"script":(apiKindJARBridge?@"jar-bridge":@"unsupported"))));
        NSMutableDictionary *site=[@{@"key":key,@"name":name,@"api":api?:@"",@"ext":ext?:@"",@"type":siteType,@"supported":@(supported),@"status":reason,@"apiKind":apiKind,@"sourceIndex":@(siteIndex-1)} mutableCopy];
        if([value[@"jar"] isKindOfClass:NSString.class]&&[value[@"jar"] length]<=8192)site[@"jar"]=value[@"jar"];
        if(safeHeaders.count)site[@"header"]=safeHeaders;
        if([value[@"playUrl"] isKindOfClass:NSString.class]&&[value[@"playUrl"] length]<=4096)site[@"playUrl"]=value[@"playUrl"];
        [cleanSites addObject:site];
    }
    NSMutableArray *cleanLives=[NSMutableArray array];NSUInteger liveIndex=0;
    for(id value in lives) {
        liveIndex++;NSString *name=nil,*url=nil,*type=@"0",*userAgent=nil,*epg=nil,*logo=nil;
        if ([value isKindOfClass:NSString.class]) { url=value; name=[NSURL URLWithString:value].host ?: @"TVBox 直播源"; }
        else if ([value isKindOfClass:NSDictionary.class]) {
            name=TVBoxString(value[@"name"],256);
            url=TVBoxString(value[@"url"],8192);
            // Preserve all inline channels and all their alternative URLs.
            if(!url.length&&[value[@"channels"] isKindOfClass:NSArray.class]){
                NSMutableString *playlist=[NSMutableString stringWithString:@"#EXTM3U\n"];NSUInteger count=0;
                for(id ch in value[@"channels"]){
                    if(![ch isKindOfClass:NSDictionary.class]||![ch[@"urls"] isKindOfClass:NSArray.class])continue;
                    NSString *channelName=TVBoxString(ch[@"name"],256)?:@"频道";channelName=[[channelName stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
                    NSString *groupName=TVBoxString(value[@"group"]?:value[@"name"],256)?:@"合集";groupName=[[[groupName stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByReplacingOccurrencesOfString:@"\r" withString:@" "] stringByReplacingOccurrencesOfString:@"\"" withString:@"'"];
                    for(id raw in ch[@"urls"]){if(count>=5000)break;NSString *address=TVBoxString(raw,8192);NSURL *target=[NSURL URLWithString:address];if(!target.host.length||![@[@"http",@"https",@"rtmp",@"rtmps"] containsObject:target.scheme.lowercaseString]||[address rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)continue;
                        [playlist appendFormat:@"#EXTINF:-1 group-title=\"%@\",%@\n%@\n",groupName,channelName,address];count++;
                    }
                }
                if(count){NSString *identity=[NSString stringWithFormat:@"%@|%@|%lu",sourceURL?:@"local",name?:@"",(unsigned long)liveIndex];NSData *input=[identity dataUsingEncoding:NSUTF8StringEncoding];unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(input.bytes,(CC_LONG)input.length,digest);NSMutableString *key=[NSMutableString string];for(NSUInteger i=0;i<sizeof(digest);i++)[key appendFormat:@"%02x",digest[i]];
                    url=[@"https://inline.cctvhost.invalid/" stringByAppendingString:key];
                    [cleanLives addObject:@{@"name":name?:@"内嵌频道",@"url":url,@"type":@"0",@"supported":@YES,@"status":[NSString stringWithFormat:@"内嵌直播 · %lu 条线路",(unsigned long)count],@"inlinePlaylist":playlist.copy,@"sourceIndex":@(liveIndex-1)}];continue;
                }
            }
            type=TVBoxString(value[@"type"],32)?:@"0";
            userAgent=TVBoxString(value[@"ua"]?:value[@"userAgent"],1024);
            epg=TVBoxString(value[@"epg"],2048);
            logo=TVBoxString(value[@"logo"],2048);
        }
        if(url.length&&!TVBoxWebURL(url)&&TVBoxWebURL(sourceURL)){NSURL *base=[NSURL URLWithString:sourceURL];NSURL *resolved=[NSURL URLWithString:url relativeToURL:base].absoluteURL;if(TVBoxWebURL(resolved.absoluteString))url=resolved.absoluteString;}
        if (!name.length) name=[NSString stringWithFormat:@"TVBox 直播源 %lu",(unsigned long)liveIndex];
        BOOL validURL=TVBoxWebURL(url);BOOL supported=validURL&&[type isEqual:@"0"];
        NSString *status=supported?@"可订阅 · M3U/TXT 清单（刷新时应用 UA）":([type isEqual:@"3"]?@"需要 Android/JAR 运行时；直播项保留但不能直接订阅":@"直播地址无效或类型暂不支持；已保留");
        NSMutableDictionary *live=[@{@"name":name,@"url":url?:@"",@"type":type,@"supported":@(supported),@"status":status,@"sourceIndex":@(liveIndex-1)} mutableCopy];
        if(userAgent.length&&[userAgent rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]].location==NSNotFound)live[@"ua"]=userAgent;
        if(epg.length&&TVBoxWebURL([epg stringByReplacingOccurrencesOfString:@"{name}" withString:@"cctv1"]))live[@"epg"]=epg;
        if(logo.length&&TVBoxWebURL([logo stringByReplacingOccurrencesOfString:@"{name}" withString:@"cctv1"]))live[@"logo"]=logo;
        [cleanLives addObject:live];
    }
    NSString *lowSourceURL=sourceURL.lowercaseString?:@"";
    NSString *inferredPrefix=TVBoxInferredCatalogPrefixName(cleanSites);
    NSString *defaultCatalogName=[lowSourceURL containsString:@"webox"]?@"WeBox 影视源合集":([lowSourceURL containsString:@"duanju"]?@"蝴蝶影视 · 短剧专区":([lowSourceURL containsString:@"chigua"]?@"蝴蝶影视 · 吃瓜专区":(([lowSourceURL containsString:@".hawk"]||[lowSourceURL containsString:@"/hamo/"])?@"蝴蝶影视 · 资源合集":([lowSourceURL containsString:@"cycod/tvbox"]?@"初忆 · TVBox 合集":(([lowSourceURL containsString:@"cttv.vip"]||[lowSourceURL containsString:@"ctys.json"])?@"刺桐影视 · TVBox 合集":(inferredPrefix?:@"资源合集"))))));
    NSString *name=TVBoxString(json[@"name"],256) ?: TVBoxString(json[@"title"],256) ?: defaultCatalogName;
    NSMutableDictionary *catalog=[@{@"id":NSUUID.UUID.UUIDString,@"name":name,@"sites":cleanSites.copy,@"lives":cleanLives.copy,@"updatedAt":@(NSDate.date.timeIntervalSince1970)} mutableCopy];
    if(depotList.count){
        NSMutableArray *depots=[NSMutableArray array];
        for(id item in depotList){
            if([item isKindOfClass:NSDictionary.class]){
                NSString *dURL=TVBoxString(item[@"url"],4096);
                NSString *dName=TVBoxString(item[@"name"]?:item[@"title"],256)?:@"多仓线路";
                if(TVBoxWebURL(dURL))[depots addObject:@{@"name":dName,@"url":dURL}];
            }
        }
        if(depots.count)catalog[@"depots"]=depots.copy;
    }
    NSMutableDictionary *tvboxConfig=[NSMutableDictionary dictionary];NSMutableArray *omittedConfigFields=[NSMutableArray array];NSUInteger extraBytes=0;
    for(NSString *field in @[@"notice",@"spider",@"wallpaper",@"logo",@"danmaku",@"parses",@"rules",@"doh",@"flags",@"ijk",@"ads"]){id item=json[field];if(!item)continue;if(![NSJSONSerialization isValidJSONObject:item]&&![item isKindOfClass:NSString.class]&&![item isKindOfClass:NSNumber.class]){[omittedConfigFields addObject:field];continue;}NSData *encoded=[NSJSONSerialization dataWithJSONObject:@{field:item} options:0 error:NULL];if(!encoded.length||encoded.length>1024*1024-extraBytes){[omittedConfigFields addObject:field];continue;}tvboxConfig[field]=item;extraBytes+=encoded.length;}
    if(tvboxConfig.count)catalog[@"tvboxConfig"]=tvboxConfig.copy;
    if(omittedConfigFields.count)catalog[@"tvboxConfigOmittedFields"]=omittedConfigFields.copy;
    if (TVBoxWebURL(sourceURL)) catalog[@"url"]=sourceURL;
    // Keep the provider's original JSON as a sidecar when saved. Normalized
    // records drive browsing; exports still preserve every provider field.
    catalog[@"_sourceConfigData"]=usedSanitized?sanitizedData.copy:data.copy;

    NSUInteger supportedCount=0;
    for(NSDictionary *s in cleanSites)if([s[@"supported"] boolValue])supportedCount++;
    TVBoxNotifyAdaptationMonitorCatalog(name, sourceURL, cleanSites.count, supportedCount, cleanLives.count, usedSanitized?@"tvbox-sanitized-json":@"tvbox-json", NO, qiaojiDecodedCount>0?[NSString stringWithFormat:@"已自动解密 %lu 个 7lj763gg 混淆站点",(unsigned long)qiaojiDecodedCount]:@"标准 TVBox JSON 合集");
    return catalog;
}
// 内置 MacCMS 影视源：与 For-ADM 蜘蛛 ystj.py 同款 4 源（默认 lziapi）。
// 固定 id + 固定 siteKey，读取目录时幂等补入；用户删除后下次读取会重新补回
//（与 ServiceStore 内置服务 builtin-ysp 同款约定）。直读 NSUserDefaults，
// 不经 +catalogs，避免递归。直链 m3u8 走 AVPlayer；share 播放页由 MacCMS
// play 路径判为网页走 WebView（WebView 会提取 video 地址回原生播放）。
+ (void)ensureBuiltInMacCMSCatalogs {
    @synchronized(self){
    NSArray *specs=@[
        @{@"id":@"builtin-maccms-lziapi",@"name":@"量子采集",@"api":@"https://cj.lziapi.com/api.php/provide/vod/",@"siteKey":@"maccms-builtin-lziapi"},
        @{@"id":@"builtin-maccms-dytt",@"name":@"电影天堂采集",@"api":@"https://caiji.dyttzyapi.com/api.php/provide/vod/",@"siteKey":@"maccms-builtin-dytt"},
        @{@"id":@"builtin-maccms-wujin",@"name":@"无尽采集",@"api":@"https://api.wujinapi.me/api.php/provide/vod/",@"siteKey":@"maccms-builtin-wujin"},
        @{@"id":@"builtin-maccms-ffzy",@"name":@"非凡采集",@"api":@"https://api.ffzyapi.com/api.php/provide/vod/",@"siteKey":@"maccms-builtin-ffzy"},
    ];
    NSArray *rows=[NSUserDefaults.standardUserDefaults arrayForKey:@"tvboxCatalogs"];
    NSMutableArray *mutable=[NSMutableArray array];
    for(id row in [rows isKindOfClass:NSArray.class]?rows:@[])if([row isKindOfClass:NSDictionary.class]&&[row[@"id"] isKindOfClass:NSString.class]&&[row[@"id"] length])[mutable addObject:row];
    NSMutableSet *ids=[NSMutableSet set];
    for(NSDictionary *row in mutable) if([row[@"id"] isKindOfClass:NSString.class]) [ids addObject:row[@"id"]];
    BOOL changed=mutable.count!=rows.count;
    for(NSDictionary *spec in specs) {
        if([ids containsObject:spec[@"id"]]) continue;
        NSDictionary *site=@{@"key":spec[@"siteKey"],@"name":spec[@"name"],@"api":spec[@"api"],@"type":@"maccms",@"apiKind":@"maccms-api",@"supported":@YES,@"status":@"内置 · 选中后读取",@"maccmsFormat":@"auto"};
        [mutable addObject:@{@"id":spec[@"id"],@"name":spec[@"name"],@"sites":@[site],@"lives":@[],@"url":spec[@"api"],@"updatedAt":@(NSDate.date.timeIntervalSince1970),@"catalogKind":@"maccms",@"builtin":@YES}];
        changed=YES;
    }
    if(changed) [NSUserDefaults.standardUserDefaults setObject:mutable forKey:@"tvboxCatalogs"];

    }
}
+ (NSArray<NSDictionary *> *)catalogs {
    @synchronized(self){
    [self ensureBuiltInMacCMSCatalogs];
    NSArray *rows=[NSUserDefaults.standardUserDefaults arrayForKey:@"tvboxCatalogs"];
    if(![rows isKindOfClass:NSArray.class])return @[];
    BOOL upgraded=NO;
    NSMutableArray *updatedCatalogs=[NSMutableArray arrayWithCapacity:rows.count];
    for(id rawCat in rows){
        if(![rawCat isKindOfClass:NSString.class]&&![rawCat isKindOfClass:NSDictionary.class]){continue;}
        if(![rawCat isKindOfClass:NSDictionary.class]||![rawCat[@"id"] isKindOfClass:NSString.class]||![rawCat[@"id"] length]){continue;}
        NSDictionary *cat=(NSDictionary *)rawCat;
        NSArray *sites=[cat[@"sites"] isKindOfClass:NSArray.class]?cat[@"sites"]:nil;
        if(!sites.count){[updatedCatalogs addObject:cat];continue;}
        BOOL catChanged=NO;
        NSMutableArray *updatedSites=[NSMutableArray arrayWithCapacity:sites.count];
        for(id rawSite in sites){
            if(![rawSite isKindOfClass:NSDictionary.class]){continue;}
            NSDictionary *site=(NSDictionary *)rawSite;
            NSString *siteType=[site[@"type"] description]?:@"";
            NSString *api=[site[@"api"] isKindOfClass:NSString.class]?site[@"api"]:@"";
            if([siteType isEqual:@"3"]&&!MediaJARClass(api).length&&MediaJARClass([NSURL URLWithString:api].lastPathComponent).length){
                NSMutableDictionary *restored=[site mutableCopy];api=[NSURL URLWithString:api].lastPathComponent;restored[@"api"]=api;site=restored;catChanged=YES;upgraded=YES;
            }
            NSURLComponents *siteParts=TVBoxURLComponents(api);
            NSString *sitePath=siteParts.path.lowercaseString?:@"";
            if([sitePath hasSuffix:@".md5"])sitePath=[sitePath stringByDeletingPathExtension];
            BOOL isScriptURL=TVBoxWebURL(api)&&[@[@"js",@"hjs",@"mjs",@"cjs",@"py",@"zip"] containsObject:sitePath.pathExtension.lowercaseString];
            BOOL isDoubanClass=[siteType isEqual:@"3"]&&([api.lowercaseString isEqual:@"csp_doudou"]||[api.lowercaseString isEqual:@"csp_douban"]);
            if(isDoubanClass&&(![site[@"supported"] boolValue]||![site[@"apiKind"] isEqual:@"douban-index"])){
                NSMutableDictionary *mSite=[site mutableCopy];
                mSite[@"supported"]=@YES;
                mSite[@"apiKind"]=@"douban-index";
                mSite[@"status"]=@"豆瓣影视索引 · iOS 原生适配 · 影片需跨点播源搜索播放";
                [updatedSites addObject:mSite.copy];
                catChanged=YES;upgraded=YES;
            }else if([siteType isEqual:@"3"]&&TVBoxSupportedJARClass(api)&&(![site[@"supported"] boolValue]||![site[@"apiKind"] isEqual:@"jar-bridge"]||[site[@"status"] isEqual:@"Android/JAR 适配引擎 · iOS 原生执行"])){
                NSMutableDictionary *mSite=[site mutableCopy];
                mSite[@"supported"]=@YES;
                mSite[@"apiKind"]=@"jar-bridge";
                mSite[@"status"]=@"站点接口适配 · 待读取验证";
                [updatedSites addObject:mSite.copy];
                catChanged=YES;upgraded=YES;
            }else if(isScriptURL&&(![site[@"supported"] boolValue]||![site[@"apiKind"] isEqual:@"script"])){
                NSMutableDictionary *mSite=[site mutableCopy];
                mSite[@"supported"]=@YES;
                mSite[@"apiKind"]=@"script";
                mSite[@"status"]=@"可导入 · 将由现有脚本适配器检查";
                [updatedSites addObject:mSite.copy];
                catChanged=YES;upgraded=YES;
            }else{
                [updatedSites addObject:site];
            }
        }
        if(catChanged){
            NSMutableDictionary *mCat=[cat mutableCopy];
            mCat[@"sites"]=updatedSites.copy;
            [updatedCatalogs addObject:mCat.copy];
        }else{
            [updatedCatalogs addObject:cat];
        }
    }
    if(upgraded)[NSUserDefaults.standardUserDefaults setObject:updatedCatalogs forKey:@"tvboxCatalogs"];
    return updatedCatalogs.copy;

    }
}
+ (NSArray<NSDictionary *> *)playbackParsers {
    return [self playbackParsersForCatalogID:nil];
}
+ (NSArray<NSDictionary *> *)playbackParsersForCatalogID:(NSString *)catalogID {
    catalogID=[catalogID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // Parser endpoints belong to their importing collection. With no known
    // collection there is no safe fallback, so never borrow another package's.
    if(!catalogID.length)return @[];
    NSMutableArray<NSDictionary *> *result=[NSMutableArray array];
    for(id rawCatalog in [[self catalogs] reverseObjectEnumerator]){
        if(![rawCatalog isKindOfClass:NSDictionary.class])continue;
        NSDictionary *catalog=rawCatalog;
        NSString *currentID=[catalog[@"id"] isKindOfClass:NSString.class]?catalog[@"id"]:@"";
        if(![currentID isEqual:catalogID])continue;
        NSDictionary *config=[catalog[@"tvboxConfig"] isKindOfClass:NSDictionary.class]?catalog[@"tvboxConfig"]:@{};
        NSArray *parses=[config[@"parses"] isKindOfClass:NSArray.class]?config[@"parses"]:@[];
        NSUInteger limit=MIN(parses.count,(NSUInteger)32);
        for(NSUInteger index=0;index<limit;index++){
            id value=parses[index];
            if(result.count>=64)break;
            NSDictionary *row=[value isKindOfClass:NSDictionary.class]?value:nil;
            NSString *url=[value isKindOfClass:NSString.class]?value:([row[@"url"] isKindOfClass:NSString.class]?row[@"url"]:@"");
            url=[url stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if(!url.length||url.length>8192)continue;
            NSString *probe=[[[url stringByReplacingOccurrencesOfString:@"{url}" withString:@"fixture"] stringByReplacingOccurrencesOfString:@"$url" withString:@"fixture"] stringByReplacingOccurrencesOfString:@"%s" withString:@"fixture"];
            NSURLComponents *parts=[NSURLComponents componentsWithString:probe];
            if((!parts.scheme.length||!parts.host.length)&&[catalog[@"url"] isKindOfClass:NSString.class]){
                NSString *marker=@"__TVBOX_MEDIA_URL_PLACEHOLDER__",*template=url;
                for(NSString *placeholder in @[@"{url}",@"$url",@"%s"])template=[template stringByReplacingOccurrencesOfString:placeholder withString:marker];
                NSURL *baseURL=[NSURL URLWithString:catalog[@"url"]],*absolute=[[NSURL URLWithString:template relativeToURL:baseURL] absoluteURL];
                if(absolute){url=[absolute.absoluteString stringByReplacingOccurrencesOfString:marker withString:@"{url}"];probe=[[[url stringByReplacingOccurrencesOfString:@"{url}" withString:@"fixture"] stringByReplacingOccurrencesOfString:@"$url" withString:@"fixture"] stringByReplacingOccurrencesOfString:@"%s" withString:@"fixture"];parts=[NSURLComponents componentsWithString:probe];}
            }
            if(!parts||![@[@"http",@"https"] containsObject:parts.scheme.lowercaseString]||!parts.host.length||parts.user.length||parts.password.length)continue;
            id rawType=row[@"type"];id type=([rawType isKindOfClass:NSString.class]||[rawType isKindOfClass:NSNumber.class])?rawType:@0;
            NSString *name=[row[@"name"] isKindOfClass:NSString.class]?[(NSString *)row[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]:@"";
            if(name.length>256)name=[name substringToIndex:256];if(!name.length)name=@"资源合集解析";
            NSString *identifier=[NSString stringWithFormat:@"%@:%lu",currentID.length?currentID:@"legacy",(unsigned long)index];
            NSMutableDictionary *parser=[NSMutableDictionary dictionaryWithDictionary:@{@"id":identifier,@"url":url,@"name":name,@"type":type,@"index":@(index),@"catalogID":currentID}];
            if([row[@"header"] isKindOfClass:NSDictionary.class])parser[@"header"]=row[@"header"];
            if([row[@"ext"] isKindOfClass:NSDictionary.class]||[row[@"ext"] isKindOfClass:NSArray.class]||[row[@"ext"] isKindOfClass:NSString.class])parser[@"ext"]=row[@"ext"];
            if([row[@"flag"] isKindOfClass:NSString.class])parser[@"flag"]=row[@"flag"];
            parser[@"catalogName"]=[catalog[@"name"] isKindOfClass:NSString.class]?catalog[@"name"]:@"资源合集";
            [result addObject:parser.copy];
        }
    }
    return result.copy;
}
+ (void)saveCatalog:(NSDictionary *)catalog {
    @synchronized(self){
    if(![catalog isKindOfClass:NSDictionary.class]||![catalog[@"id"] isKindOfClass:NSString.class]||![catalog[@"id"] length])return;
    NSString *identifier=[catalog[@"id"] isKindOfClass:NSString.class]?catalog[@"id"]:@"";
    NSData *sourceData=[catalog[@"_sourceConfigData"] isKindOfClass:NSData.class]?catalog[@"_sourceConfigData"]:nil;
    NSMutableDictionary *storedCatalog=[catalog mutableCopy];
    if(sourceData.length){BOOL saved=NO;if(TVBoxSafeCatalogID(identifier)){NSString *path=[TVBoxCatalogStorageDirectory() stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"json"]];saved=[sourceData writeToFile:path options:NSDataWritingAtomic error:NULL];}if(saved)[storedCatalog removeObjectForKey:@"_sourceConfigData"];else storedCatalog[@"_sourceConfigData"]=sourceData;}
    else [storedCatalog removeObjectForKey:@"_sourceConfigData"];
    NSMutableArray *rows=[[self catalogs] mutableCopy];
    for(NSUInteger i=0;i<rows.count;i++) if([rows[i][@"id"] isEqual:identifier]) { NSMutableDictionary *merged=[rows[i] mutableCopy]; [merged addEntriesFromDictionary:storedCatalog]; rows[i]=merged; [NSUserDefaults.standardUserDefaults setObject:rows forKey:@"tvboxCatalogs"]; return; }
    [rows addObject:storedCatalog];
    // 有界：最多保留 64 个目录，按 updatedAt 丢弃最旧（无时间戳的视为最旧）。
    while(rows.count>64){NSUInteger oldest=0;for(NSUInteger i=1;i<rows.count;i++)if([rows[i][@"updatedAt"] doubleValue]<[rows[oldest][@"updatedAt"] doubleValue])oldest=i;[rows removeObjectAtIndex:oldest];}
    [NSUserDefaults.standardUserDefaults setObject:rows forKey:@"tvboxCatalogs"];

    }
}
+ (NSDictionary *)catalogForID:(NSString *)identifier { for(NSDictionary *row in [self catalogs])if([row[@"id"] isEqual:identifier])return row; return nil; }
+ (void)removeCatalog:(NSString *)identifier {
    @synchronized(self){ NSMutableArray *rows=[[self catalogs] mutableCopy]; NSIndexSet *remove=[rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *row,NSUInteger idx,BOOL *stop){return [row[@"id"] isEqual:identifier];}]; [rows removeObjectsAtIndexes:remove]; [NSUserDefaults.standardUserDefaults setObject:rows forKey:@"tvboxCatalogs"];if(TVBoxSafeCatalogID(identifier)){NSString *path=[TVBoxCatalogStorageDirectory() stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"json"]];[NSFileManager.defaultManager removeItemAtPath:path error:NULL];NSString *bundleDir=[TVBoxCatalogBundlesDirectory() stringByAppendingPathComponent:identifier];[NSFileManager.defaultManager removeItemAtPath:bundleDir error:NULL];}
    }
}
+ (NSArray<NSDictionary *> *)liveSourcesInCatalog:(NSDictionary *)catalog { return [catalog[@"lives"] isKindOfClass:NSArray.class]?catalog[@"lives"]:@[]; }
+ (NSDictionary *)reconstructedConfigForCatalog:(NSDictionary *)catalog {
    NSMutableDictionary *config=[NSMutableDictionary dictionary];NSString *name=[catalog[@"name"] isKindOfClass:NSString.class]?catalog[@"name"]:@"资源合集";config[@"name"]=name;
    NSMutableArray *sites=[NSMutableArray array];for(NSDictionary *site in [catalog[@"sites"] isKindOfClass:NSArray.class]?catalog[@"sites"]:@[]){NSMutableDictionary *row=[NSMutableDictionary dictionary];for(NSString *key in @[@"key",@"name",@"api",@"type",@"header",@"playUrl"]){id value=site[key];if(value)row[key]=value;}NSString *ext=[site[@"ext"] isKindOfClass:NSString.class]?site[@"ext"]:@"";if(ext.length){id value=[NSJSONSerialization JSONObjectWithData:[ext dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:NULL];row[@"ext"]=value?:ext;}if(row.count)[sites addObject:row];}
    NSMutableArray *lives=[NSMutableArray array];for(NSDictionary *live in [catalog[@"lives"] isKindOfClass:NSArray.class]?catalog[@"lives"]:@[]){NSMutableDictionary *row=[NSMutableDictionary dictionary];for(NSString *key in @[@"name",@"url",@"type",@"ua",@"epg",@"logo"]){id value=live[key];if(value)row[key]=value;}if(row.count)[lives addObject:row];}config[@"sites"]=sites;config[@"lives"]=lives;
    NSDictionary *extras=[catalog[@"tvboxConfig"] isKindOfClass:NSDictionary.class]?catalog[@"tvboxConfig"]:@{};[config addEntriesFromDictionary:extras];return config;
}
+ (nullable NSDictionary *)originalConfigForCatalogID:(NSString *)identifier catalog:(NSDictionary **)catalogOut error:(NSError **)error {
    NSDictionary *catalog=[self catalogForID:identifier];if(!catalog){if(error)*error=TVBoxError(@"找不到此资源合集");return nil;}if(catalogOut)*catalogOut=catalog;
    NSData *data=nil;if(TVBoxSafeCatalogID(identifier)){NSString *path=[TVBoxCatalogStorageDirectory() stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"json"]];data=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];}
    if(!data.length&&[catalog[@"_sourceConfigData"] isKindOfClass:NSData.class])data=catalog[@"_sourceConfigData"];
    NSDictionary *config=nil;if(data.length){id value=[NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:NULL];if(!value){NSData *sanitized=TVBoxSanitizeJSONData(data);if(sanitized.length)value=[NSJSONSerialization JSONObjectWithData:sanitized options:NSJSONReadingFragmentsAllowed error:NULL];}if([value isKindOfClass:NSDictionary.class])config=value;}
    return config?:[self reconstructedConfigForCatalog:catalog];
}
+ (nullable NSData *)exportDataForCatalogID:(NSString *)identifier error:(NSError **)error {
    NSDictionary *catalog=nil,*config=[self originalConfigForCatalogID:identifier catalog:&catalog error:error];if(!config)return nil;
    NSData *preserved=nil;if(TVBoxSafeCatalogID(identifier)){NSString *path=[TVBoxCatalogStorageDirectory() stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"json"]];preserved=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];}if(!preserved.length&&[catalog[@"_sourceConfigData"] isKindOfClass:NSData.class])preserved=catalog[@"_sourceConfigData"];if(preserved.length){id original=[NSJSONSerialization JSONObjectWithData:preserved options:NSJSONReadingFragmentsAllowed error:NULL];if([original isKindOfClass:NSDictionary.class])return preserved;}
    NSData *result=[NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:error];if(!result&&error&&!*error)*error=TVBoxError(@"无法生成资源合集 JSON");return result;
}
+ (nullable NSData *)exportSingleResourceForCatalogID:(NSString *)identifier kind:(NSString *)kind index:(NSUInteger)index error:(NSError **)error {
    NSDictionary *catalog=nil,*original=[self originalConfigForCatalogID:identifier catalog:&catalog error:error];if(!original||!catalog)return nil;
    BOOL isLive=[kind isEqual:@"live"];if(!isLive&&![kind isEqual:@"site"]){if(error)*error=TVBoxError(@"未知的资源类型");return nil;}
    NSArray *rows=[catalog[isLive?@"lives":@"sites"] isKindOfClass:NSArray.class]?catalog[isLive?@"lives":@"sites"]:@[];if(index>=rows.count){if(error)*error=TVBoxError(@"找不到要导出的资源");return nil;}NSDictionary *selected=rows[index];
    NSString *sourceKey=isLive?@"lives":@"sites";NSArray *originalRows=[original[sourceKey] isKindOfClass:NSArray.class]?original[sourceKey]:@[];NSUInteger sourceIndex=[selected[@"sourceIndex"] respondsToSelector:@selector(unsignedIntegerValue)]?[selected[@"sourceIndex"] unsignedIntegerValue]:index;
    id raw=sourceIndex<originalRows.count?originalRows[sourceIndex]:nil;
    if(!raw){NSMutableDictionary *fallback=[NSMutableDictionary dictionary];for(NSString *key in (isLive?@[@"name",@"url",@"type",@"ua"]:@[@"key",@"name",@"api",@"ext",@"type",@"header",@"playUrl"]))if(selected[key])fallback[key]=selected[key];raw=fallback;}
    if(isLive&&[raw isKindOfClass:NSString.class])raw=selected[@"url"]?:raw;
    else if([raw isKindOfClass:NSDictionary.class]){NSMutableDictionary *resolved=[raw mutableCopy];NSString *urlKey=isLive?@"url":@"api";if([selected[urlKey] isKindOfClass:NSString.class]&&[selected[urlKey] length])resolved[urlKey]=selected[urlKey];raw=resolved;}
    NSMutableDictionary *single=[original mutableCopy];single[@"sites"]=isLive?@[]:@[raw];single[@"lives"]=isLive?@[raw]:@[];
    NSData *data=[NSJSONSerialization dataWithJSONObject:single options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:error];if(!data&&error&&!*error)*error=TVBoxError(@"无法生成单资源 JSON");return data;
}
+ (nullable NSURL *)writeZIPArchiveForCatalogID:(NSString *)identifier files:(NSDictionary<NSString *,NSData *> *)files error:(NSError **)error {
    if(![self catalogForID:identifier]){if(error)*error=TVBoxError(@"找不到此资源合集");return nil;}NSMutableDictionary *contents=[files mutableCopy]?:[NSMutableDictionary dictionary];if(!contents[@"config.json"]){NSData *json=[self exportDataForCatalogID:identifier error:error];if(!json)return nil;contents[@"config.json"]=json;}
    NSDictionary *catalog=[self catalogForID:identifier];NSString *name=TVBoxExportFilename(catalog[@"name"]);if(!contents[@"README.txt"]){NSString *readme=[NSString stringWithFormat:@"%@\n\n本 ZIP 包含完整 TVBox JSON 配置，以及可下载的内部 PY/JS 文件。source-manifest.json 记录文件与站点的对应关系和未能获取的项目。\n",name];contents[@"README.txt"]=[readme dataUsingEncoding:NSUTF8StringEncoding];}NSData *archive=TVBoxZIPData(contents,error);if(!archive)return nil;
    NSString *filename=[NSString stringWithFormat:@"%@-%@.zip",name,NSUUID.UUID.UUIDString.lowercaseString];NSURL *url=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:filename]];if(![archive writeToURL:url options:NSDataWritingAtomic error:error])return nil;return url;
}
+ (nullable NSURL *)writeZIPArchiveForCatalogID:(NSString *)identifier error:(NSError **)error {return [self writeZIPArchiveForCatalogID:identifier files:nil error:error];}
@end
