#import <XCTest/XCTest.h>
#import <VeTOSiOSSDK/VeTOSiOSSDK.h>

#import "TOSURLProtocolStub.h"

@interface TOSClient (ProtocolRegressionTesting)

@property (nonatomic, strong) TOSNetworking *networking;

@end

@interface TOSClientProtocolRegressionTests : XCTestCase

@property (nonatomic, strong) TOSClient *client;
@property (nonatomic, strong) NSURLSession *stubSession;

@end

@implementation TOSClientProtocolRegressionTests

- (void)setUp {
    [super setUp];
    [TOSURLProtocolStub reset];

    TOSEndpoint *endpoint =
        [[TOSEndpoint alloc] initWithURLString:@"https://tos-unit.test"
                                   withRegion:@"cn-beijing"];
    TOSCredential *credential =
        [[TOSCredential alloc] initWithAccessKey:@"test-access-key"
                                      secretKey:@"test-secret-key"];
    TOSClientConfiguration *configuration =
        [[TOSClientConfiguration alloc] initWithEndpoint:endpoint credential:credential];
    configuration.maxRetryCount = 0;
    self.client = [[TOSClient alloc] initWithConfiguration:configuration];

    TOSNetworking *networking = self.client.networking;
    NSURLSession *originalSession = networking.session;
    NSURLSessionConfiguration *sessionConfiguration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    sessionConfiguration.protocolClasses = @[[TOSURLProtocolStub class]];
    self.stubSession =
        [NSURLSession sessionWithConfiguration:sessionConfiguration
                                      delegate:networking
                                 delegateQueue:nil];
    networking.session = self.stubSession;
    [originalSession invalidateAndCancel];
}

- (void)tearDown {
    [self.stubSession invalidateAndCancel];
    self.stubSession = nil;
    self.client = nil;
    [TOSURLProtocolStub reset];
    [super tearDown];
}

- (void)registerJSONResponse:(NSString *)JSON {
    NSData *body = [JSON dataUsingEncoding:NSUTF8StringEncoding];
    [TOSURLProtocolStub setHandler:^TOSURLProtocolStubResponse *(NSURLRequest *request) {
        return [TOSURLProtocolStubResponse
            responseWithStatusCode:200
                           headers:@{
                               @"Content-Type" : @"application/json",
                               @"x-tos-request-id" : @"request-id",
                           }
                              body:body];
    }];
}

- (BOOL)waitForTask:(TOSTask *)task operation:(NSString *)operation {
    XCTestExpectation *completion =
        [self expectationWithDescription:
            [NSString stringWithFormat:@"%@ completed", operation]];
    [task continueWithBlock:^id(TOSTask *completedTask) {
        [completion fulfill];
        return nil;
    }];
    [self waitForExpectations:@[completion] timeout:10.0];
    XCTAssertTrue(task.completed, @"%@ did not complete within 10 seconds",
                  operation);
    return task.completed;
}

- (void)testTransportRunsThroughPublicClient {
    NSString *JSON =
        @"{"
         "\"Bucket\":\"example-bucket\","
         "\"Key\":\"video.mp4\","
         "\"UploadId\":\"upload-id\","
         "\"PartNumberMarker\":0,"
         "\"NextPartNumberMarker\":0,"
         "\"MaxParts\":1000,"
         "\"IsTruncated\":false,"
         "\"StorageClass\":\"STANDARD\","
         "\"Owner\":{\"ID\":\"owner-id\",\"DisplayName\":\"owner-name\"},"
         "\"Parts\":[]"
        "}";
    NSData *body = [JSON dataUsingEncoding:NSUTF8StringEncoding];
    [TOSURLProtocolStub setHandler:^TOSURLProtocolStubResponse *(NSURLRequest *request) {
        return [TOSURLProtocolStubResponse
            responseWithStatusCode:200
                           headers:@{
                               @"Content-Type" : @"application/json",
                               @"x-tos-request-id" : @"request-id",
                           }
                              body:body];
    }];

    TOSListPartsInput *input = [TOSListPartsInput new];
    input.tosBucket = @"example-bucket";
    input.tosKey = @"video.mp4";
    input.tosUploadID = @"upload-id";
    input.tosMaxParts = 1000;

    TOSTask *task = [self.client listParts:input];
    if (![self waitForTask:task operation:NSStringFromSelector(_cmd)]) {
        return;
    }

    XCTAssertNil(task.error);
    XCTAssertTrue([task.result isKindOfClass:[TOSListPartsOutput class]]);
    TOSListPartsOutput *output = task.result;
    XCTAssertEqual(output.tosStatusCode, 200);
    XCTAssertEqualObjects(output.tosRequestID, @"request-id");

    NSArray<NSURLRequest *> *capturedRequests = [TOSURLProtocolStub capturedRequests];
    XCTAssertEqual(capturedRequests.count, 1);
    NSURLRequest *request = capturedRequests.firstObject;
    XCTAssertEqualObjects(request.HTTPMethod, @"GET");
    XCTAssertEqualObjects(request.URL.host, @"example-bucket.tos-unit.test");
    NSURLComponents *components =
        [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    NSMutableDictionary<NSString *, NSString *> *query = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        query[item.name] = item.value ?: @"";
    }
    XCTAssertEqualObjects(query[@"uploadId"], @"upload-id");
    XCTAssertEqualObjects(query[@"max-parts"], @"1000");
}

- (void)testPublicClientUsesReleaseUserAgent {
    [self registerJSONResponse:
        @"{"
         "\"Buckets\":[],"
         "\"Owner\":{\"ID\":\"owner-id\",\"DisplayName\":\"owner-name\"}"
        "}"];

    TOSTask *task = [self.client listBuckets:[TOSListBucketsInput new]];
    if (![self waitForTask:task operation:NSStringFromSelector(_cmd)]) {
        return;
    }

    XCTAssertNil(task.error);
    NSURLRequest *request = [TOSURLProtocolStub capturedRequests].firstObject;
    NSString *userAgent = [request valueForHTTPHeaderField:@"User-Agent"];
    XCTAssertTrue([userAgent hasPrefix:@"ve-tos-iOS-sdk/2.1.8 "],
                  @"Unexpected User-Agent: %@", userAgent);
}

- (void)testDefaultNetworkingInterceptorUsesReleaseUserAgent {
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://tos-unit.test"]];
    TOSNetworkingRequestInterceptor *interceptor = [TOSNetworkingRequestInterceptor new];

    TOSTask *task = [interceptor interceptRequest:request];

    XCTAssertNil(task.error);
    NSString *userAgent = [request valueForHTTPHeaderField:@"User-Agent"];
    XCTAssertTrue([userAgent hasPrefix:@"tos-sdk-iOS/2.1.8 "],
                  @"Unexpected User-Agent: %@", userAgent);
}

- (void)testListPartsReturnsPartsAndOwnerThroughPublicClient {
    [self registerJSONResponse:
        @"{"
         "\"Bucket\":\"example-bucket\","
         "\"Key\":\"video.mp4\","
         "\"UploadId\":\"upload-id\","
         "\"PartNumberMarker\":0,"
         "\"NextPartNumberMarker\":2,"
         "\"MaxParts\":1000,"
         "\"IsTruncated\":false,"
         "\"StorageClass\":\"STANDARD\","
         "\"Owner\":{\"ID\":\"owner-id\",\"DisplayName\":\"owner-name\"},"
         "\"Parts\":["
           "{\"PartNumber\":1,\"LastModified\":\"2021-08-20T06:43:36.000Z\","
            "\"ETag\":\"etag-1\",\"Size\":4194304},"
           "{\"PartNumber\":2,\"LastModified\":\"2021-08-20T06:43:37.000Z\","
            "\"ETag\":\"etag-2\",\"Size\":1024}"
         "]"
        "}"];

    TOSListPartsInput *input = [TOSListPartsInput new];
    input.tosBucket = @"example-bucket";
    input.tosKey = @"video.mp4";
    input.tosUploadID = @"upload-id";
    input.tosMaxParts = 1000;

    TOSTask *task = [self.client listParts:input];
    if (![self waitForTask:task operation:NSStringFromSelector(_cmd)]) {
        return;
    }

    XCTAssertNil(task.error);
    TOSListPartsOutput *output = task.result;
    XCTAssertEqual(output.tosParts.count, 2);
    XCTAssertEqualObjects(output.tosParts[0].tosETag, @"etag-1");
    XCTAssertEqualObjects(output.tosOwner.tosID, @"owner-id");
    XCTAssertEqualObjects(output.tosOwner.tosDisplayName, @"owner-name");
    XCTAssertEqualWithAccuracy(output.tosParts[0].tosLastModified.timeIntervalSince1970,
                               1629441816, 0.001);
}

- (void)testGetObjectACLReturnsOwnerThroughPublicClient {
    [self registerJSONResponse:
        @"{"
         "\"Owner\":{\"ID\":\"owner-id\",\"DisplayName\":\"owner-name\"},"
         "\"Grants\":[]"
        "}"];

    TOSGetObjectACLInput *input = [TOSGetObjectACLInput new];
    input.tosBucket = @"example-bucket";
    input.tosKey = @"video.mp4";

    TOSTask *task = [self.client getObjectAcl:input];
    if (![self waitForTask:task operation:NSStringFromSelector(_cmd)]) {
        return;
    }

    XCTAssertNil(task.error);
    TOSGetObjectACLOutput *output = task.result;
    XCTAssertNotNil(output.tosOwner);
    XCTAssertEqualObjects(output.tosOwner.tosID, @"owner-id");
    XCTAssertEqualObjects(output.tosOwner.tosDisplayName, @"owner-name");
}

- (void)testListObjectsReturnsEachContentOwnerThroughPublicClient {
    [self registerJSONResponse:
        @"{"
         "\"Name\":\"example-bucket\","
         "\"MaxKeys\":1000,"
         "\"IsTruncated\":false,"
         "\"Contents\":[{"
           "\"Key\":\"video.mp4\","
           "\"LastModified\":\"2021-08-20T06:43:36.000Z\","
           "\"ETag\":\"etag-1\","
           "\"Size\":4194304,"
           "\"StorageClass\":\"STANDARD\","
           "\"Owner\":{\"ID\":\"owner-id\",\"DisplayName\":\"owner-name\"}"
         "}]"
        "}"];

    TOSListObjectsInput *input = [TOSListObjectsInput new];
    input.tosBucket = @"example-bucket";

    TOSTask *task = [self.client listObjects:input];
    if (![self waitForTask:task operation:NSStringFromSelector(_cmd)]) {
        return;
    }

    XCTAssertNil(task.error);
    TOSListObjectsOutput *output = task.result;
    XCTAssertEqual(output.tosContents.count, 1);
    XCTAssertEqualObjects(output.tosContents[0].tosOwner.tosID, @"owner-id");
    XCTAssertEqualObjects(output.tosContents[0].tosOwner.tosDisplayName, @"owner-name");
    XCTAssertEqualWithAccuracy(output.tosContents[0].tosLastModified.timeIntervalSince1970,
                               1629441816, 0.001);
}

- (void)testListMultipartUploadsReturnsOwnerAndPrefixThroughPublicClient {
    [self registerJSONResponse:
        @"{"
         "\"Bucket\":\"example-bucket\","
         "\"MaxUploads\":1000,"
         "\"IsTruncated\":false,"
         "\"Uploads\":[{"
           "\"Key\":\"video.mp4\","
           "\"UploadId\":\"upload-id\","
           "\"StorageClass\":\"STANDARD\","
           "\"Initiated\":\"2021-08-20T06:43:36.000Z\","
           "\"Owner\":{\"ID\":\"owner-id\",\"DisplayName\":\"owner-name\"}"
         "}],"
         "\"CommonPrefixes\":[{\"Prefix\":\"videos/\"}]"
        "}"];

    TOSListMultipartUploadsInput *input = [TOSListMultipartUploadsInput new];
    input.tosBucket = @"example-bucket";

    TOSTask *task = [self.client listMultipartUploads:input];
    if (![self waitForTask:task operation:NSStringFromSelector(_cmd)]) {
        return;
    }

    XCTAssertNil(task.error);
    TOSListMultipartUploadsOutput *output = task.result;
    XCTAssertEqual(output.tosUploads.count, 1);
    XCTAssertEqualObjects(output.tosUploads[0].tosOwner.tosID, @"owner-id");
    XCTAssertEqualObjects(output.tosUploads[0].tosOwner.tosDisplayName, @"owner-name");
    XCTAssertEqual(output.tosCommonPrefixes.count, 1);
    XCTAssertTrue([output.tosCommonPrefixes[0].tosPrefix isKindOfClass:[NSString class]]);
    XCTAssertEqualObjects(output.tosCommonPrefixes[0].tosPrefix, @"videos/");
    XCTAssertEqualWithAccuracy(output.tosUploads[0].tosInitiated.timeIntervalSince1970,
                               1629441816, 0.001);
}

- (void)testCopyObjectSendsVersionIDInCopySourceHeaderThroughPublicClient {
    [self registerJSONResponse:
        @"{"
         "\"ETag\":\"copied-etag\","
         "\"LastModified\":\"2021-08-20T06:43:36.000Z\""
        "}"];

    TOSCopyObjectInput *input = [TOSCopyObjectInput new];
    input.tosBucket = @"destination-bucket";
    input.tosKey = @"destination.mp4";
    input.tosSrcBucket = @"source-bucket";
    input.tosSrcKey = @"source.mp4";
    input.tosSrcVersionID = @"version-1";
    input.tosCopySourceIfModifiedSince = [NSDate dateWithTimeIntervalSince1970:1629441816];
    input.tosCopySourceIfUnmodifiedSince = [NSDate dateWithTimeIntervalSince1970:1629441816];

    TOSTask *task = [self.client copyObject:input];
    if (![self waitForTask:task operation:NSStringFromSelector(_cmd)]) {
        return;
    }

    XCTAssertNil(task.error);
    TOSCopyObjectOutput *output = task.result;
    XCTAssertEqualWithAccuracy(output.tosLastModified.timeIntervalSince1970,
                               1629441816, 0.001);
    NSArray<NSURLRequest *> *capturedRequests = [TOSURLProtocolStub capturedRequests];
    XCTAssertEqual(capturedRequests.count, 1);
    NSURLRequest *request = capturedRequests.firstObject;
    XCTAssertEqualObjects(request.HTTPMethod, @"PUT");
    XCTAssertEqualObjects([request valueForHTTPHeaderField:@"x-tos-copy-source"],
                          @"/source-bucket/source.mp4?versionId=version-1");
    XCTAssertEqualObjects([request valueForHTTPHeaderField:@"x-tos-copy-source-if-modified-since"],
                          @"Fri, 20 Aug 2021 06:43:36 GMT");
    XCTAssertEqualObjects([request valueForHTTPHeaderField:@"x-tos-copy-source-if-unmodified-since"],
                          @"Fri, 20 Aug 2021 06:43:36 GMT");
}

- (void)testListMultipartUploadsSendsEncodingTypeQueryThroughPublicClient {
    [self registerJSONResponse:
        @"{"
         "\"Bucket\":\"example-bucket\","
         "\"MaxUploads\":1000,"
         "\"IsTruncated\":false,"
         "\"Uploads\":[],"
         "\"CommonPrefixes\":[]"
        "}"];

    TOSListMultipartUploadsInput *input = [TOSListMultipartUploadsInput new];
    input.tosBucket = @"example-bucket";
    input.tosEncodingType = @"url";

    TOSTask *task = [self.client listMultipartUploads:input];
    if (![self waitForTask:task operation:NSStringFromSelector(_cmd)]) {
        return;
    }

    XCTAssertNil(task.error);
    NSURLRequest *request = [TOSURLProtocolStub capturedRequests].firstObject;
    NSURLComponents *components =
        [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    NSMutableDictionary<NSString *, NSString *> *query = [NSMutableDictionary dictionary];
    for (NSURLQueryItem *item in components.queryItems) {
        query[item.name] = item.value ?: @"";
    }
    XCTAssertEqualObjects(query[@"encoding-type"], @"url");
    XCTAssertNil(query[@"encodint-type"]);
}

- (void)testPutObjectSendsRawRFC1123ExpiresWithoutChangingMetadataEncoding {
    [self registerJSONResponse:@"{}"];

    TOSPutObjectInput *input = [TOSPutObjectInput new];
    input.tosBucket = @"example-bucket";
    input.tosKey = @"video.mp4";
    input.tosContent = [@"video" dataUsingEncoding:NSUTF8StringEncoding];
    input.tosExpires = [NSDate dateWithTimeIntervalSince1970:1629441816];
    input.tosMeta = @{@"compatibility" : @"value with spaces"};

    TOSTask *task = [self.client putObject:input];
    if (![self waitForTask:task operation:NSStringFromSelector(_cmd)]) {
        return;
    }

    XCTAssertNil(task.error);
    NSURLRequest *request = [TOSURLProtocolStub capturedRequests].firstObject;
    XCTAssertEqualObjects([request valueForHTTPHeaderField:@"Expires"],
                          @"Fri, 20 Aug 2021 06:43:36 GMT");
    XCTAssertEqualObjects([request valueForHTTPHeaderField:@"x-tos-meta-compatibility"],
                          @"value%20with%20spaces");
}

- (void)testGetObjectParsesRFC1123LastModifiedThroughPublicClient {
    NSData *body = [@"video-bytes" dataUsingEncoding:NSUTF8StringEncoding];
    [TOSURLProtocolStub setHandler:^TOSURLProtocolStubResponse *(NSURLRequest *request) {
        return [TOSURLProtocolStubResponse
            responseWithStatusCode:200
                           headers:@{
                               @"Content-Type" : @"video/mp4",
                               @"Content-Length" : [NSString stringWithFormat:@"%lu",
                                                                                (unsigned long)body.length],
                               @"Last-Modified" : @"Fri, 20 Aug 2021 06:43:36 GMT",
                               @"x-tos-request-id" : @"request-id",
                           }
                              body:body];
    }];

    TOSGetObjectInput *input = [TOSGetObjectInput new];
    input.tosBucket = @"example-bucket";
    input.tosKey = @"video.mp4";
    input.tosIfModifiedSince = [NSDate dateWithTimeIntervalSince1970:1629441816];
    input.tosIfUnmodifiedSince = [NSDate dateWithTimeIntervalSince1970:1629441816];
    input.tosResponseExpires = [NSDate dateWithTimeIntervalSince1970:1629441816];

    TOSTask *task = [self.client getObject:input];
    if (![self waitForTask:task operation:NSStringFromSelector(_cmd)]) {
        return;
    }

    XCTAssertNil(task.error);
    TOSGetObjectOutput *output = task.result;
    XCTAssertTrue([output.tosLastModified isKindOfClass:[NSDate class]]);
    if ([output.tosLastModified isKindOfClass:[NSDate class]]) {
        XCTAssertEqualWithAccuracy(output.tosLastModified.timeIntervalSince1970,
                                   1629441816, 0.001);
    }
    NSURLRequest *request = [TOSURLProtocolStub capturedRequests].firstObject;
    XCTAssertEqualObjects([request valueForHTTPHeaderField:@"If-Modified-Since"],
                          @"Fri, 20 Aug 2021 06:43:36 GMT");
    XCTAssertEqualObjects([request valueForHTTPHeaderField:@"If-Unmodified-Since"],
                          @"Fri, 20 Aug 2021 06:43:36 GMT");
    NSURLComponents *components =
        [NSURLComponents componentsWithURL:request.URL resolvingAgainstBaseURL:NO];
    NSString *responseExpires = nil;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"response-expires"]) {
            responseExpires = item.value;
        }
    }
    XCTAssertEqualObjects(responseExpires, @"Fri, 20 Aug 2021 06:43:36 GMT");
}

- (void)testHeadObjectSendsRFC1123ConditionDatesThroughPublicClient {
    [TOSURLProtocolStub setHandler:^TOSURLProtocolStubResponse *(NSURLRequest *request) {
        return [TOSURLProtocolStubResponse
            responseWithStatusCode:200
                           headers:@{
                               @"Content-Length" : @"10",
                               @"Last-Modified" : @"Fri, 20 Aug 2021 06:43:36 GMT",
                               @"x-tos-request-id" : @"request-id",
                           }
                              body:[NSData data]];
    }];

    TOSHeadObjectInput *input = [TOSHeadObjectInput new];
    input.tosBucket = @"example-bucket";
    input.tosKey = @"video.mp4";
    input.tosIfModifiedSince = [NSDate dateWithTimeIntervalSince1970:1629441816];
    input.tosIfUnmodifiedSince = [NSDate dateWithTimeIntervalSince1970:1629441816];

    TOSTask *task = [self.client headObject:input];
    if (![self waitForTask:task operation:NSStringFromSelector(_cmd)]) {
        return;
    }

    XCTAssertNil(task.error);
    NSURLRequest *request = [TOSURLProtocolStub capturedRequests].firstObject;
    XCTAssertEqualObjects(request.HTTPMethod, @"HEAD");
    XCTAssertEqualObjects([request valueForHTTPHeaderField:@"If-Modified-Since"],
                          @"Fri, 20 Aug 2021 06:43:36 GMT");
    XCTAssertEqualObjects([request valueForHTTPHeaderField:@"If-Unmodified-Since"],
                          @"Fri, 20 Aug 2021 06:43:36 GMT");
}

@end
