#import "TOSURLProtocolStub.h"

@interface TOSURLProtocolStubResponse ()

@property (nonatomic, assign, readwrite) NSInteger statusCode;
@property (nonatomic, copy, readwrite) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, copy, readwrite) NSData *body;

@end

@implementation TOSURLProtocolStubResponse

+ (instancetype)responseWithStatusCode:(NSInteger)statusCode
                               headers:(NSDictionary<NSString *, NSString *> *)headers
                                  body:(NSData *)body {
    TOSURLProtocolStubResponse *response = [TOSURLProtocolStubResponse new];
    response.statusCode = statusCode;
    response.headers = headers;
    response.body = body;
    return response;
}

@end

@implementation TOSURLProtocolStub

static TOSURLProtocolStubHandler _handler;
static NSMutableArray<NSURLRequest *> *_capturedRequests;

+ (void)initialize {
    if (self == [TOSURLProtocolStub class]) {
        _capturedRequests = [NSMutableArray array];
    }
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString *host = request.URL.host.lowercaseString;
    return [host isEqualToString:@"tos-unit.test"] || [host hasSuffix:@".tos-unit.test"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

+ (void)setHandler:(TOSURLProtocolStubHandler)handler {
    @synchronized(self) {
        _handler = [handler copy];
    }
}

+ (NSArray<NSURLRequest *> *)capturedRequests {
    @synchronized(self) {
        return [_capturedRequests copy];
    }
}

+ (void)reset {
    @synchronized(self) {
        _handler = nil;
        [_capturedRequests removeAllObjects];
    }
}

- (void)startLoading {
    TOSURLProtocolStubHandler handler = nil;
    NSURLRequest *request = [self.request copy];
    @synchronized([TOSURLProtocolStub class]) {
        [_capturedRequests addObject:request];
        handler = [_handler copy];
    }

    if (!handler) {
        NSError *error =
            [NSError errorWithDomain:@"com.volcengine.tos.tests.URLProtocolStub"
                                code:1
                            userInfo:@{NSLocalizedDescriptionKey : @"No response fixture registered"}];
        [self.client URLProtocol:self didFailWithError:error];
        return;
    }

    TOSURLProtocolStubResponse *stubResponse = handler(request);
    if (!stubResponse) {
        NSError *error =
            [NSError errorWithDomain:@"com.volcengine.tos.tests.URLProtocolStub"
                                code:2
                            userInfo:@{NSLocalizedDescriptionKey : @"Response fixture rejected request"}];
        [self.client URLProtocol:self didFailWithError:error];
        return;
    }

    NSHTTPURLResponse *response =
        [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                   statusCode:stubResponse.statusCode
                                  HTTPVersion:@"HTTP/1.1"
                                 headerFields:stubResponse.headers];
    [self.client URLProtocol:self
          didReceiveResponse:response
          cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (stubResponse.body.length > 0) {
        [self.client URLProtocol:self didLoadData:stubResponse.body];
    }
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
}

@end
