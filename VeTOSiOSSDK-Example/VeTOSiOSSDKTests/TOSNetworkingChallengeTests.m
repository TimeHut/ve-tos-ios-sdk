#import <Security/Security.h>
#import <XCTest/XCTest.h>
#import <VeTOSiOSSDK/TOSNetworking.h>

@interface TOSChallengeProtectionSpaceStub : NSObject

@property (nonatomic, copy) NSString *authenticationMethod;
@property (nonatomic, assign) SecTrustRef serverTrust;

@end

@implementation TOSChallengeProtectionSpaceStub
@end

@interface TOSAuthenticationChallengeStub : NSObject

@property (nonatomic, strong) TOSChallengeProtectionSpaceStub *protectionSpace;

@end

@implementation TOSAuthenticationChallengeStub
@end

@interface TOSSessionTaskStub : NSObject

@property (nonatomic, strong) NSURLRequest *currentRequest;

@end

@implementation TOSSessionTaskStub
@end

@interface TOSNetworkingChallengeTests : XCTestCase
@end

@implementation TOSNetworkingChallengeTests

- (TOSAuthenticationChallengeStub *)challengeWithAuthenticationMethod:
    (NSString *)authenticationMethod
                                                        serverTrust:
    (SecTrustRef)serverTrust {
    TOSChallengeProtectionSpaceStub *protectionSpace =
        [TOSChallengeProtectionSpaceStub new];
    protectionSpace.authenticationMethod = authenticationMethod;
    protectionSpace.serverTrust = serverTrust;

    TOSAuthenticationChallengeStub *challenge =
        [TOSAuthenticationChallengeStub new];
    challenge.protectionSpace = protectionSpace;
    return challenge;
}

- (TOSSessionTaskStub *)testTask {
    TOSSessionTaskStub *task = [TOSSessionTaskStub new];
    task.currentRequest =
        [NSURLRequest requestWithURL:
            [NSURL URLWithString:@"https://tos-sdk-test.invalid"]];
    return task;
}

- (SecTrustRef)newTestServerTrust {
    NSString *certificateBase64 =
        @"MIIDHzCCAgegAwIBAgIUN/4A5PT5v4wR3n5G0Ge9MGbwD8QwDQYJKoZIhvcNAQELBQAwHzEdMBsGA1UEAwwUdG9zLXNkay10ZXN0LmludmFsaWQwHhcNMjYwNzMwMDMwNDExWhcNMjYwNzMxMDMwNDExWjAfMR0wGwYDVQQDDBR0b3Mtc2RrLXRlc3QuaW52YWxpZDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAOLRJBt47VAebixZEH/XRuIC2vvR7rMPzYJAs4JWo8t15KK7BduylRxhP6EdUx2rYLo5AdEWXwNBTsL2DA/97J1HzzNPvWQJioB7A5RjsLZGcyF4G6b4XL4u55s8f/NVuk0g33muza5G1pESWmfRF/Jrel6fQGYwzAvlkpg4CyVb5D7o94oBJtgdUh2FEluVcXSirtCNgjJvDfw+aMvJq1OFI3OGpqerIzWyLHwFS3dV/+MDV9kpBWT449W/jSTSFqtmqw1WslwjSZ/aDl6Q762PM4ebVQ1dKHvVvz8QtEg6cY+rnBWvA/72Lc9jIuWsiEZiK47in2cxS5Z0lKCxbZcCAwEAAaNTMFEwHQYDVR0OBBYEFOdoP36IiMXTp2fJpD1DFmtfLWFLMB8GA1UdIwQYMBaAFOdoP36IiMXTp2fJpD1DFmtfLWFLMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAMSZX7UZY6pRRtGLiFETJ0hX5SFtgMoM02/ZEO2H4oayKs1M8vQ4tn8QZ0qcUdRQOu/XNTlOkTRTIMg90UI2k09P7mvqSwmbnXH5SDreu0HDG0OQHlycgcndKoCGpB+FJwHZTLAreJtKTrDlI4j3k6kroj9d+5mPmvJrlSSArn017GQj42n5Eei84KI0DWd870y7HV1L5JWlyKkX42wnA2xasCy96FsujXJ0xGS/Rl1pRiCa6A4CVlmHlRAAeNgjulyzYzH5Zc83CHhNYDXTkrtALdRWZIcR2ecp1qJqAvXQ62uAOSF6/dqdE2AvDe+Z12CxPQ0MK1QUPQZhhE1hfSg=";
    NSData *certificateData =
        [[NSData alloc] initWithBase64EncodedString:certificateBase64 options:0];
    SecCertificateRef certificate =
        SecCertificateCreateWithData(kCFAllocatorDefault,
                                     (__bridge CFDataRef)certificateData);
    XCTAssertNotEqual(certificate, NULL);
    if (!certificate) {
        return NULL;
    }

    SecPolicyRef policy =
        SecPolicyCreateSSL(true, CFSTR("tos-sdk-test.invalid"));
    SecTrustRef trust = NULL;
    OSStatus status =
        SecTrustCreateWithCertificates(certificate, policy, &trust);
    CFRelease(policy);
    CFRelease(certificate);
    XCTAssertEqual(status, errSecSuccess);
    XCTAssertNotEqual(trust, NULL);
    return trust;
}

- (void)testServerTrustChallengeCompletesExactlyOnceWithDefaultHandling {
    SecTrustRef trust = [self newTestServerTrust];
    XCTAssertNotEqual(trust, NULL);
    if (!trust) {
        return;
    }

    TOSAuthenticationChallengeStub *challenge =
        [self challengeWithAuthenticationMethod:
                  NSURLAuthenticationMethodServerTrust
                                      serverTrust:trust];
    TOSSessionTaskStub *task = [self testTask];

    TOSNetworking *networking = [TOSNetworking new];
    NSMutableArray<NSNumber *> *dispositions = [NSMutableArray array];
    NSMutableArray *credentials = [NSMutableArray array];

    [networking URLSession:NSURLSession.sharedSession
                      task:(id)task
       didReceiveChallenge:(id)challenge
         completionHandler:
             ^(NSURLSessionAuthChallengeDisposition disposition,
               NSURLCredential *credential) {
                 [dispositions addObject:@(disposition)];
                 [credentials addObject:credential ?: NSNull.null];
             }];

    CFRelease(trust);
    XCTAssertEqual(dispositions.count, 1);
    XCTAssertEqual(dispositions.firstObject.integerValue,
                   NSURLSessionAuthChallengePerformDefaultHandling);
    XCTAssertEqualObjects(credentials.firstObject, NSNull.null);
}

- (void)testNonServerTrustChallengeCompletesExactlyOnceWithDefaultHandling {
    TOSAuthenticationChallengeStub *challenge =
        [self challengeWithAuthenticationMethod:
                  NSURLAuthenticationMethodHTTPBasic
                                      serverTrust:NULL];
    TOSNetworking *networking = [TOSNetworking new];
    __block NSUInteger callCount = 0;
    __block NSURLSessionAuthChallengeDisposition capturedDisposition =
        NSURLSessionAuthChallengeCancelAuthenticationChallenge;
    __block NSURLCredential *capturedCredential = nil;

    [networking URLSession:NSURLSession.sharedSession
                      task:(id)[self testTask]
       didReceiveChallenge:(id)challenge
         completionHandler:
             ^(NSURLSessionAuthChallengeDisposition disposition,
               NSURLCredential *credential) {
                 callCount++;
                 capturedDisposition = disposition;
                 capturedCredential = credential;
             }];

    XCTAssertEqual(callCount, 1);
    XCTAssertEqual(capturedDisposition,
                   NSURLSessionAuthChallengePerformDefaultHandling);
    XCTAssertNil(capturedCredential);
}

- (void)testConcurrentServerTrustChallengesCompleteExactlyOnceEach {
    SecTrustRef trust = [self newTestServerTrust];
    XCTAssertNotEqual(trust, NULL);
    if (!trust) {
        return;
    }

    TOSAuthenticationChallengeStub *challenge =
        [self challengeWithAuthenticationMethod:
                  NSURLAuthenticationMethodServerTrust
                                      serverTrust:trust];
    TOSSessionTaskStub *task = [self testTask];
    TOSNetworking *networking = [TOSNetworking new];
    NSMutableArray<NSNumber *> *callCounts = [NSMutableArray array];
    const NSUInteger invocationCount = 1000;

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue =
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    for (NSUInteger index = 0; index < invocationCount; index++) {
        dispatch_group_async(group, queue, ^{
            (void)index;
            __block NSUInteger callCount = 0;
            [networking URLSession:NSURLSession.sharedSession
                              task:(id)task
               didReceiveChallenge:(id)challenge
                 completionHandler:
                     ^(NSURLSessionAuthChallengeDisposition disposition,
                       NSURLCredential *credential) {
                         (void)disposition;
                         (void)credential;
                         callCount++;
                     }];
            @synchronized(callCounts) {
                [callCounts addObject:@(callCount)];
            }
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    CFRelease(trust);
    XCTAssertEqual(callCounts.count, invocationCount);
    NSPredicate *unexpectedCount =
        [NSPredicate predicateWithBlock:^BOOL(NSNumber *callCount,
                                              NSDictionary *bindings) {
            return callCount.unsignedIntegerValue != 1;
        }];
    XCTAssertEqual(
        [callCounts filteredArrayUsingPredicate:unexpectedCount].count, 0);
}

@end
