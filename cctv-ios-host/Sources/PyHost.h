#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const PyHostRuntimeStateDidChangeNotification;

/// 内置 CPython 宿主：启动后在同一进程内运行 Python 插件脚本（如 ysp-live）
@interface PyHost : NSObject

@property (class, nonatomic, readonly) BOOL running;
@property (class, nonatomic, readonly) BOOL startedOnce;
@property (class, nonatomic, readonly) NSInteger port;
@property (class, nonatomic, readonly, nullable) NSError *startupError;
+ (nullable NSError *)startupErrorForServiceIdentifier:(NSString *)identifier;
/// Describes interpreter/process activity only. HTTP health must be checked separately.
@property (class, nonatomic, readonly) NSString *runtimeStatusDescription;
/// Describes only this service's runtime session; it never infers HTTP or playback health.
+ (NSString *)runtimeStatusDescriptionForServiceIdentifier:(NSString *)identifier;
/// True when this specific service ID owns a live Python or Node session.
+ (BOOL)isRunningServiceIdentifier:(NSString *)identifier;
/// True while a session is being initialized or is retained for cleanup after a lost reply.
+ (BOOL)isManagedServiceIdentifier:(NSString *)identifier;
+ (BOOL)isStartingServiceIdentifier:(NSString *)identifier;
+ (BOOL)hasUncertainSessionForServiceIdentifier:(NSString *)identifier;
+ (NSArray<NSString *> *)runningServiceIdentifiers;

/// stdout/stderr 回调（后台线程调用）
+ (void)setLogHandler:(nullable void (^)(NSString *line))handler;
+ (void)setLogHandler:(nullable void (^)(NSString *line))handler forServiceIdentifier:(NSString *)identifier;

/// 启动插件；scriptName 为 App 资源里的脚本文件名
+ (BOOL)startWithScript:(NSString *)scriptName
                   port:(NSInteger)port
                dataDir:(NSString *)dataDir
                  error:(NSError **)error;

+ (BOOL)startScriptAtPath:(NSString *)path port:(NSInteger)port dataDir:(NSString *)dataDir arguments:(nullable NSArray<NSString *> *)arguments error:(NSError **)error;
+ (BOOL)startScriptAtPath:(NSString *)path identifier:(NSString *)identifier port:(NSInteger)port dataDir:(NSString *)dataDir arguments:(nullable NSArray<NSString *> *)arguments error:(NSError **)error;

+ (BOOL)stopServiceIdentifier:(NSString *)identifier error:(NSError **)error;
+ (BOOL)stopWithError:(NSError **)error;
+ (void)stop;

@end

NS_ASSUME_NONNULL_END
