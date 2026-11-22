#import <Foundation/Foundation.h>
#import <Security/Security.h>

// Each service has its own keychain item. Device-only accessibility prevents
// secrets from silently moving to another device through a system backup.
static inline NSDictionary *HostSecureStoreQuery(NSString *scope, NSString *identifier) {
    return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService:[@"CCTVHost." stringByAppendingString:scope],
             (__bridge id)kSecAttrAccount:identifier};
}
static inline BOOL HostSecureStoreWrite(NSString *scope, NSString *identifier, NSData *data) {
    if(!scope.length || !identifier.length || !data)return NO;
    NSDictionary *query=HostSecureStoreQuery(scope,identifier);
    NSDictionary *values=@{(__bridge id)kSecValueData:data,
                            (__bridge id)kSecAttrAccessible:(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus status=SecItemUpdate((__bridge CFDictionaryRef)query,(__bridge CFDictionaryRef)values);
    if(status==errSecItemNotFound){NSMutableDictionary *item=[query mutableCopy];[item addEntriesFromDictionary:values];status=SecItemAdd((__bridge CFDictionaryRef)item,NULL);}
    return status==errSecSuccess;
}
static inline NSData *HostSecureStoreRead(NSString *scope, NSString *identifier, OSStatus *outStatus) {
    NSMutableDictionary *query=[HostSecureStoreQuery(scope,identifier) mutableCopy];
    query[(__bridge id)kSecReturnData]=@YES;
    query[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
    CFTypeRef value=NULL;OSStatus status=SecItemCopyMatching((__bridge CFDictionaryRef)query,&value);
    if(outStatus)*outStatus=status;
    return status==errSecSuccess?CFBridgingRelease(value):nil;
}
static inline void HostSecureStoreDelete(NSString *scope, NSString *identifier) {
    if(scope.length && identifier.length)SecItemDelete((__bridge CFDictionaryRef)HostSecureStoreQuery(scope,identifier));
}
