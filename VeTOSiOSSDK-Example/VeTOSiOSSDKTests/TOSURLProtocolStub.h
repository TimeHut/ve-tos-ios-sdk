#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TOSURLProtocolStubResponse : NSObject

@property (nonatomic, assign, readonly) NSInteger statusCode;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, copy, readonly) NSData *body;

+ (instancetype)responseWithStatusCode:(NSInteger)statusCode
                               headers:(NSDictionary<NSString *, NSString *> *)headers
                                  body:(NSData *)body;

@end

typedef TOSURLProtocolStubResponse *_Nullable (^TOSURLProtocolStubHandler)(NSURLRequest *request);

@interface TOSURLProtocolStub : NSURLProtocol

+ (void)setHandler:(nullable TOSURLProtocolStubHandler)handler;
+ (NSArray<NSURLRequest *> *)capturedRequests;
+ (void)reset;

@end

NS_ASSUME_NONNULL_END
