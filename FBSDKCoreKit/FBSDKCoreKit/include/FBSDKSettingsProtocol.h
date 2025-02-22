// Copyright (c) 2014-present, Facebook, Inc. All rights reserved.
//
// You are hereby granted a non-exclusive, worldwide, royalty-free license to use,
// copy, modify, and distribute this software in source code or binary form for use
// in connection with the web services and APIs provided by Facebook.
//
// As with any software that integrates with the Facebook platform, your use of
// this software is subject to the Facebook Developer Principles and Policies
// [http://developers.facebook.com/policy/]. This copyright notice shall be
// included in all copies or substantial portions of the software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import "FBSDKAdvertisingTrackingStatus.h"
#import "FBSDKLoggingBehavior.h"

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_NAME(SettingsProtocol)
@protocol FBSDKSettings

@property (nullable, nonatomic, copy) NSString *appID;
@property (nullable, nonatomic, copy) NSString *clientToken;
@property (nullable, nonatomic, copy) NSString *userAgentSuffix;
@property (nonatomic, readonly, copy) NSString *sdkVersion;
@property (nullable, nonatomic, copy) NSString *displayName;
@property (nullable, nonatomic, copy) NSString *facebookDomainPart;
@property (class, nonnull, nonatomic, copy) NSSet<FBSDKLoggingBehavior> *loggingBehaviors;
@property (nullable, nonatomic, copy) NSString *appURLSchemeSuffix;
@property (nonatomic, readonly) BOOL isDataProcessingRestricted;
@property (nonatomic, readonly) BOOL isAutoLogAppEventsEnabled;
@property (nonatomic, readonly) BOOL isSetATETimeExceedsInstallTime;
@property (nonatomic, readonly) BOOL isSKAdNetworkReportEnabled;
@property (nonnull, nonatomic, readonly) NSSet<FBSDKLoggingBehavior> *loggingBehaviors;
@property (nonatomic, readonly) FBSDKAdvertisingTrackingStatus advertisingTrackingStatus;
@property (nullable, nonatomic, readonly) NSDate *installTimestamp;
@property (nullable, nonatomic, readonly) NSDate *advertiserTrackingEnabledTimestamp;
@property (nonatomic, readonly) BOOL shouldLimitEventAndDataUsage;
@property (nonatomic) BOOL shouldUseTokenOptimizations;
@property (nonatomic, readonly, copy) NSString *_Nonnull graphAPIVersion;
@property (nonatomic, readonly) BOOL isGraphErrorRecoveryEnabled;
@property (nullable, nonatomic, readonly, copy) NSString *graphAPIDebugParamValue;
@end

NS_ASSUME_NONNULL_END
