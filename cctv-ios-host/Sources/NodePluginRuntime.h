#import <Foundation/Foundation.h>

@interface NodePluginRuntime : NSObject
+ (instancetype)shared;
@property(atomic, readonly) BOOL hasActivePlugin;
/// Confirmed sessions only; a timed-out start is not reported as running.
@property(atomic, readonly) NSArray<NSString *> *activeSessionIdentifiers;
/// Sessions still owned by the host, including starts whose reply was lost.
@property(atomic, readonly) NSArray<NSString *> *managedServiceIdentifiers;
- (BOOL)isRunningSession:(NSString *)identifier;
- (BOOL)isManagedSession:(NSString *)identifier;
- (BOOL)isRunningServiceIdentifier:(NSString *)identifier;
- (BOOL)isStartingServiceIdentifier:(NSString *)identifier;
- (BOOL)hasUncertainSessionForServiceIdentifier:(NSString *)identifier;
@property(nonatomic, copy) void (^logHandler)(NSString *message);
- (void)setLogHandler:(nullable void (^)(NSString *message))handler forServiceIdentifier:(NSString *)identifier;
- (NSString *)callOperation:(NSString *)operation json:(NSString *)json error:(NSError **)error;
- (BOOL)stopWithError:(NSError **)error;
- (BOOL)stopSession:(NSString *)identifier error:(NSError **)error;
- (BOOL)stopSessionsForServiceIdentifier:(NSString *)identifier error:(NSError **)error;
@end
