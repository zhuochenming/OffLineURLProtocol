//
//  OffLineURLProtocol.m
//  OffLineURLProtocol
//  Created by Zhuochenming on 16/6/20.
//  Copyright © 2016年 Zhuochenming. All rights reserved.
//

#import "OffLineURLProtocol.h"
#import <CommonCrypto/CommonDigest.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <netdb.h>
#import <arpa/inet.h>

#define WORKAROUND_MUTABLE_COPY_LEAK 1
#if WORKAROUND_MUTABLE_COPY_LEAK
@interface NSURLRequest(MutableCopyWorkaround)

- (id) mutableCopyWorkaround;

@end
#endif

#if WORKAROUND_MUTABLE_COPY_LEAK
@implementation NSURLRequest(MutableCopyWorkaround)

- (id) mutableCopyWorkaround {
    NSMutableURLRequest *mutableURLRequest = [[NSMutableURLRequest alloc] initWithURL:[self URL]
                                                                          cachePolicy:[self cachePolicy]
                                                                      timeoutInterval:[self timeoutInterval]];
    [mutableURLRequest setAllHTTPHeaderFields:[self allHTTPHeaderFields]];
    if ([self HTTPBodyStream]) {
        [mutableURLRequest setHTTPBodyStream:[self HTTPBodyStream]];
    } else {
        [mutableURLRequest setHTTPBody:[self HTTPBody]];
    }
    [mutableURLRequest setHTTPMethod:[self HTTPMethod]];
    
    return mutableURLRequest;
}

@end
#endif


#pragma mark - NSString扩展方法
@interface NSString (UUShaString)

- (NSString *)sha1;

@end

@implementation NSString (UUShaString)

- (NSString *)sha1 {
    NSData *data = [self dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    
    CC_SHA1(data.bytes, (int)data.length, digest);
    
    NSMutableString *output = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [output appendFormat:@"%02x", digest[i]];
    }
    
    return output;
}

@end


#pragma mark - 缓存数据
@interface OffLineCache : NSObject<NSCoding>

@property (nonatomic, readwrite, strong) NSData *data;

@property (nonatomic, readwrite, strong) NSURLResponse *response;

@property (nonatomic, readwrite, strong) NSURLRequest *redirectRequest;

@end

static NSString * const kDataKey = @"data";
static NSString * const kResponseKey = @"response";
static NSString * const kRedirectRequestKey = @"redirectRequest";

@implementation OffLineCache

- (void)encodeWithCoder:(NSCoder *)aCoder {
    [aCoder encodeObject:[self data] forKey:kDataKey];
    [aCoder encodeObject:[self response] forKey:kResponseKey];
    [aCoder encodeObject:[self redirectRequest] forKey:kRedirectRequestKey];
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super init];
    if (self != nil) {
        [self setData:[aDecoder decodeObjectForKey:kDataKey]];
        [self setResponse:[aDecoder decodeObjectForKey:kResponseKey]];
        [self setRedirectRequest:[aDecoder decodeObjectForKey:kRedirectRequestKey]];
    }
    return self;
}

@end



static NSString *UUCachingURLHeader = @"UUCachingURLHeader";

@interface OffLineURLProtocol ()<NSURLSessionDataDelegate>

@property (nonatomic, strong) NSURLSession *session;

@property (nonatomic, strong) NSURLSessionDataTask *downloadTask;

@property (nonatomic, readwrite, strong) NSMutableData *data;

@property (nonatomic, readwrite, strong) NSURLResponse *response;

- (void)appendData:(NSData *)newData;

@end

static NSObject *CachingSupportedSchemesMonitor;
static NSSet *CachingSupportedSchemes;

@implementation OffLineURLProtocol
@synthesize data = data_;
@synthesize response = response_;

- (NSURLSession *)session {
    if (!_session) {
        _session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration] delegate:self delegateQueue:nil];
    }
    return _session;
}

+ (void)initialize {
    if (self == [OffLineURLProtocol class]) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            CachingSupportedSchemesMonitor = [NSObject new];
        });
        [self setSupportedSchemes:[NSSet setWithObject:@"http"]];
    }
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([[self supportedSchemes] containsObject:[[request URL] scheme]] &&
        ([request valueForHTTPHeaderField:UUCachingURLHeader] == nil)) {
        return YES;
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (NSString *)cachePathForRequest:(NSURLRequest *)aRequest {
    NSString *cachesPath = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) lastObject];
    NSString *fileName = [[[aRequest URL] absoluteString] sha1];
    
    return [cachesPath stringByAppendingPathComponent:fileName];
}

- (BOOL)useCache {
    struct sockaddr_in zeroAddress;
    bzero(&zeroAddress, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;
    
    SCNetworkReachabilityRef defaultRouteReachability = SCNetworkReachabilityCreateWithAddress(NULL, (struct sockaddr *)&zeroAddress);
    SCNetworkReachabilityFlags flags;
    
    BOOL didRetrieveFlags = SCNetworkReachabilityGetFlags(defaultRouteReachability, &flags);
    CFRelease(defaultRouteReachability);
    
    if (!didRetrieveFlags) {
        printf("Error. Could not recover network reachability flags\n");
        return NO;
    }
    
    BOOL isReachable = ((flags & kSCNetworkFlagsReachable) != 0);
    BOOL needsConnection = ((flags & kSCNetworkFlagsConnectionRequired) != 0);
    return (isReachable && !needsConnection) ? YES : NO;
}

#pragma mark - 开始加载URL
- (void)startLoading {
    NSLog(@"%@\n%@", self.request.URL, [[NSString alloc] initWithData:self.request.HTTPBody encoding:NSUTF8StringEncoding]);
    
    if (![self useCache]) {
        NSMutableURLRequest *connectionRequest =
#if WORKAROUND_MUTABLE_COPY_LEAK
        [[self request] mutableCopyWorkaround];
#else
        [[self request] mutableCopy];
#endif
        
        [connectionRequest setValue:@"" forHTTPHeaderField:UUCachingURLHeader];
        self.downloadTask = [self.session dataTaskWithRequest:connectionRequest];
        [self.downloadTask resume];
        
    } else {
        OffLineCache *cache = [NSKeyedUnarchiver unarchiveObjectWithFile:[self cachePathForRequest:[self request]]];
        if (cache) {
            NSData *data = [cache data];
            NSURLResponse *response = [cache response];
            NSURLRequest *redirectRequest = [cache redirectRequest];
            if (redirectRequest) {
                [[self client] URLProtocol:self wasRedirectedToRequest:redirectRequest redirectResponse:response];
            } else {
                
                [[self client] URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed]; // we handle caching ourselves.
                [[self client] URLProtocol:self didLoadData:data];
                [[self client] URLProtocolDidFinishLoading:self];
            }
        } else {
            [[self client] URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:nil]];
        }
    }
}

#pragma mark - 停止加载URL
- (void)stopLoading {
    [self.downloadTask cancel];
    self.downloadTask = nil;
}

#pragma mark - NSURLSession代理
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    
    if (response != nil) {
        NSMutableURLRequest *redirectableRequest =
#if WORKAROUND_MUTABLE_COPY_LEAK
        [request mutableCopyWorkaround];
#else
        [request mutableCopy];
#endif
        [redirectableRequest setValue:nil forHTTPHeaderField:UUCachingURLHeader];
        
        NSString *cachePath = [self cachePathForRequest:[self request]];
        OffLineCache *cache = [OffLineCache new];
        [cache setResponse:response];
        [cache setData:[self data]];
        [cache setRedirectRequest:redirectableRequest];
        [NSKeyedArchiver archiveRootObject:cache toFile:cachePath];
        [[self client] URLProtocol:self wasRedirectedToRequest:redirectableRequest redirectResponse:response];
        completionHandler(redirectableRequest);
    } else {
        completionHandler(request);
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    // 允许处理服务器的响应，才会继续接收服务器返回的数据
    completionHandler(NSURLSessionResponseAllow);
    self.data = [NSMutableData data];
    self.response = response;
}

-  (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    //下载过程中
    [self.client URLProtocol:self didLoadData:data];
    [self.data appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    //    下载完成之后的处理
    if (error) {
        [self.client URLProtocol:self didFailWithError:error];
        self.data = nil;
        self.response = nil;
    } else {
        //将数据的缓存归档存入到本地文件中
        [[self client] URLProtocolDidFinishLoading:self];
        
        NSString *cachePath = [self cachePathForRequest:[self request]];
        OffLineCache *cache = [OffLineCache new];
        [cache setResponse:[self response]];
        [cache setData:[self data]];

        [NSKeyedArchiver archiveRootObject:cache toFile:cachePath];
        [self setData:nil];
        [self setResponse:nil];
    }
}

#pragma mark - 其他方法
- (void)appendData:(NSData *)newData {
    if ([self data] == nil) {
        [self setData:[newData mutableCopy]];
    } else {
        [[self data] appendData:newData];
    }
}

+ (NSSet *)supportedSchemes {
    NSSet *supportedSchemes;
    @synchronized(CachingSupportedSchemesMonitor) {
        supportedSchemes = CachingSupportedSchemes;
    }
    return supportedSchemes;
}

+ (void)setSupportedSchemes:(NSSet *)supportedSchemes {
    @synchronized(CachingSupportedSchemesMonitor) {
        CachingSupportedSchemes = supportedSchemes;
    }
}

@end
