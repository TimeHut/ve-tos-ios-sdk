/**
 * Copyright 2026 Beijing Volcano Engine Technology Ltd.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "TOSInput+TransferInternal.h"
#import <VeTOSiOSSDK/TOSConstants.h>
#import <objc/runtime.h>

static NSError *TOSTransferInvalidRangeResponse(NSString *message) {
    return [NSError errorWithDomain:TOSClientErrorDomain
                               code:400
                           userInfo:@{TOSErrorMessageTOKEN: message}];
}

static id TOSTransferHeaderValue(NSHTTPURLResponse *response, NSString *name) {
    for (id key in response.allHeaderFields) {
        if ([[key description] caseInsensitiveCompare:name] == NSOrderedSame) {
            return response.allHeaderFields[key];
        }
    }
    return nil;
}

static BOOL TOSTransferParseInteger(NSString *value, int64_t *result) {
    if (value.length == 0) {
        return NO;
    }
    NSScanner *scanner = [NSScanner scannerWithString:value];
    long long parsed = 0;
    if (![scanner scanLongLong:&parsed] || !scanner.isAtEnd || parsed < 0) {
        return NO;
    }
    if (result) {
        *result = parsed;
    }
    return YES;
}

TOSTransferResponseValidator TOSTransferRangeResponseValidator(int64_t start, int64_t end) {
    return ^NSError *(NSHTTPURLResponse *response) {
        if (start < 0 || end < start || end - start == INT64_MAX) {
            return TOSTransferInvalidRangeResponse(@"下载分段范围无效");
        }
        if (response.statusCode != 206) {
            return TOSTransferInvalidRangeResponse([NSString stringWithFormat:@"下载分段响应状态码 %ld 不是 206",
                                                     (long)response.statusCode]);
        }

        NSString *contentRange = [[TOSTransferHeaderValue(response, @"Content-Range") description]
                                  stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        static NSRegularExpression *expression = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            expression = [NSRegularExpression regularExpressionWithPattern:@"^bytes ([0-9]+)-([0-9]+)/([0-9]+|\\*)$"
                                                                    options:NSRegularExpressionCaseInsensitive
                                                                      error:nil];
        });
        NSTextCheckingResult *match = [expression firstMatchInString:contentRange ?: @""
                                                               options:0
                                                                 range:NSMakeRange(0, contentRange.length)];
        if (!match) {
            return TOSTransferInvalidRangeResponse(@"下载分段响应缺少有效的 Content-Range");
        }

        int64_t actualStart = 0;
        int64_t actualEnd = 0;
        NSString *startValue = [contentRange substringWithRange:[match rangeAtIndex:1]];
        NSString *endValue = [contentRange substringWithRange:[match rangeAtIndex:2]];
        if (!TOSTransferParseInteger(startValue, &actualStart) ||
            !TOSTransferParseInteger(endValue, &actualEnd) ||
            actualStart != start || actualEnd != end) {
            return TOSTransferInvalidRangeResponse(@"下载分段响应的 Content-Range 与请求不一致");
        }

        NSString *totalValue = [contentRange substringWithRange:[match rangeAtIndex:3]];
        int64_t total = 0;
        if (![totalValue isEqualToString:@"*"] &&
            (!TOSTransferParseInteger(totalValue, &total) || total <= actualEnd)) {
            return TOSTransferInvalidRangeResponse(@"下载分段响应的对象大小无效");
        }

        id contentLengthHeader = TOSTransferHeaderValue(response, @"Content-Length");
        if (contentLengthHeader) {
            int64_t contentLength = 0;
            int64_t expectedLength = end - start + 1;
            if (!TOSTransferParseInteger([contentLengthHeader description], &contentLength) ||
                contentLength != expectedLength) {
                return TOSTransferInvalidRangeResponse(@"下载分段响应的 Content-Length 与请求不一致");
            }
        }
        return nil;
    };
}

@interface TOSTransferNetworkCancellation ()
@property (nonatomic, strong) NSLock *tos_lock;
@property (nonatomic, strong) NSHashTable<NSURLSessionTask *> *tos_tasks;
@property (nonatomic, assign, readwrite, getter=isCancelled) BOOL cancelled;
@end

static void *TOSTransferCancellationAssociationKey = &TOSTransferCancellationAssociationKey;
static void *TOSTransferHeadersAssociationKey = &TOSTransferHeadersAssociationKey;
static void *TOSTransferResponseValidatorAssociationKey = &TOSTransferResponseValidatorAssociationKey;
static void *TOSTransferResponseObserverAssociationKey = &TOSTransferResponseObserverAssociationKey;

@implementation TOSInput (TransferInternal)

- (void)setTos_transferCancellation:(TOSTransferNetworkCancellation *)cancellation {
    objc_setAssociatedObject(self,
                             TOSTransferCancellationAssociationKey,
                             cancellation,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (TOSTransferNetworkCancellation *)tos_transferCancellation {
    return objc_getAssociatedObject(self, TOSTransferCancellationAssociationKey);
}

- (void)setTos_transferHeaders:(NSDictionary<NSString *,NSString *> *)headers {
    objc_setAssociatedObject(self,
                             TOSTransferHeadersAssociationKey,
                             headers,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
}

- (NSDictionary<NSString *,NSString *> *)tos_transferHeaders {
    return objc_getAssociatedObject(self, TOSTransferHeadersAssociationKey);
}

- (void)setTos_responseValidator:(TOSTransferResponseValidator)validator {
    objc_setAssociatedObject(self,
                             TOSTransferResponseValidatorAssociationKey,
                             validator,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
}

- (TOSTransferResponseValidator)tos_responseValidator {
    return objc_getAssociatedObject(self, TOSTransferResponseValidatorAssociationKey);
}

- (void)setTos_responseObserver:(TOSTransferResponseObserver)observer {
    objc_setAssociatedObject(self,
                             TOSTransferResponseObserverAssociationKey,
                             observer,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
}

- (TOSTransferResponseObserver)tos_responseObserver {
    return objc_getAssociatedObject(self, TOSTransferResponseObserverAssociationKey);
}

@end

@implementation TOSTransferNetworkCancellation

- (instancetype)init {
    self = [super init];
    if (self) {
        _tos_lock = [NSLock new];
        _tos_tasks = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

- (void)registerTask:(NSURLSessionTask *)task {
    if (!task) {
        return;
    }
    [self.tos_lock lock];
    BOOL shouldCancel = self.isCancelled;
    if (!shouldCancel) {
        [self.tos_tasks addObject:task];
    }
    [self.tos_lock unlock];
    if (shouldCancel) {
        [task cancel];
    }
}

- (void)unregisterTask:(NSURLSessionTask *)task {
    if (!task) {
        return;
    }
    [self.tos_lock lock];
    [self.tos_tasks removeObject:task];
    [self.tos_lock unlock];
}

- (void)cancel {
    [self.tos_lock lock];
    if (self.isCancelled) {
        [self.tos_lock unlock];
        return;
    }
    self.cancelled = YES;
    NSArray<NSURLSessionTask *> *tasks = self.tos_tasks.allObjects;
    [self.tos_tasks removeAllObjects];
    [self.tos_lock unlock];

    for (NSURLSessionTask *task in tasks) {
        [task cancel];
    }
}

@end
