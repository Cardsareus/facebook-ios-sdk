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

#if !TARGET_OS_TV

#import "FBSDKLoginManagerLogger.h"

#import <FBSDKCoreKit_Basics/FBSDKCoreKit_Basics.h>

#import "FBSDKLoginError.h"
#import "FBSDKLoginManagerLoginResult+Internal.h"
#import "FBSDKLoginUtility.h"
#import "FBSDKMonotonicTime.h"

NSString *const FBSDKLoginManagerLoggerAuthMethod_Native = @"fb_application_web_auth";
NSString *const FBSDKLoginManagerLoggerAuthMethod_Browser = @"browser_auth";
NSString *const FBSDKLoginManagerLoggerAuthMethod_SFVC = @"sfvc_auth";
NSString *const FBSDKLoginManagerLoggerAuthMethod_Applink = @"applink_auth";

static NSString *const FBSDKLoginManagerLoggingClientStateKey = @"state";
static NSString *const FBSDKLoginManagerLoggingClientStateIsClientState = @"com.facebook.sdk_client_state";

static NSString *const FBSDKLoginManagerLoggerParamIdentifierKey = @"0_auth_logger_id";
static NSString *const FBSDKLoginManagerLoggerParamTimestampKey = @"1_timestamp_ms";
static NSString *const FBSDKLoginManagerLoggerParamResultKey = @"2_result";
static NSString *const FBSDKLoginManagerLoggerParamAuthMethodKey = @"3_method";
static NSString *const FBSDKLoginManagerLoggerParamErrorCodeKey = @"4_error_code";
static NSString *const FBSDKLoginManagerLoggerParamErrorMessageKey = @"5_error_message";
static NSString *const FBSDKLoginManagerLoggerParamExtrasKey = @"6_extras";
static NSString *const FBSDKLoginManagerLoggerParamLoggingTokenKey = @"7_logging_token";

static NSString *const FBSDKLoginManagerLoggerValueEmpty = @"";

static NSString *const FBSDKLoginManagerLoggerResultSuccessString = @"success";
static NSString *const FBSDKLoginManagerLoggerResultCancelString = @"cancelled";
static NSString *const FBSDKLoginManagerLoggerResultErrorString = @"error";
static NSString *const FBSDKLoginManagerLoggerResultSkippedString = @"skipped";

static NSString *const FBSDKLoginManagerLoggerTryNative = @"tryFBAppAuth";
static NSString *const FBSDKLoginManagerLoggerTryBrowser = @"trySafariAuth";

/** Use to log the result of the App Switch OS AlertView. Only available on OS >= iOS10 */
FBSDKAppEventName const FBSDKAppEventNameFBSessionFASLoginDialogResult = @"fb_mobile_login_fas_dialog_result";

/** Use to log the start of an auth request that cannot be fulfilled by the token cache */
FBSDKAppEventName const FBSDKAppEventNameFBSessionAuthStart = @"fb_mobile_login_start";

/** Use to log the end of an auth request that was not fulfilled by the token cache */
FBSDKAppEventName const FBSDKAppEventNameFBSessionAuthEnd = @"fb_mobile_login_complete";

/** Use to log the start of a specific auth method as part of an auth request */
FBSDKAppEventName const FBSDKAppEventNameFBSessionAuthMethodStart = @"fb_mobile_login_method_start";

/** Use to log the end of the last tried auth method as part of an auth request */
FBSDKAppEventName const FBSDKAppEventNameFBSessionAuthMethodEnd = @"fb_mobile_login_method_complete";

/** Use to log the post-login heartbeat event after  the end of an auth request*/
FBSDKAppEventName const FBSDKAppEventNameFBSessionAuthHeartbeat = @"fb_mobile_login_heartbeat";

@interface FBSDKLoginManagerLogger ()

@property (nonatomic) NSString *identifier;
@property (nonatomic) NSMutableDictionary<NSString *, id> *extras;
@property (nonatomic) NSString *lastResult;
@property (nonatomic) NSError *lastError;
@property (nonatomic) NSString *authMethod;
@property (nonatomic) NSString *loggingToken;

@end

@implementation FBSDKLoginManagerLogger

+ (FBSDKLoginManagerLogger *)loggerFromParameters:(NSDictionary<NSString *, id> *)parameters
                                         tracking:(FBSDKLoginTracking)tracking
{
  NSDictionary<id, id> *clientState = [FBSDKBasicUtility objectForJSONString:parameters[FBSDKLoginManagerLoggingClientStateKey] error:NULL];

  id isClientState = clientState[FBSDKLoginManagerLoggingClientStateIsClientState];
  if ([isClientState isKindOfClass:NSNumber.class] && [isClientState boolValue]) {
    FBSDKLoginManagerLogger *logger = [[self alloc] initWithLoggingToken:nil tracking:tracking];
    if (logger != nil) {
      logger->_identifier = clientState[FBSDKLoginManagerLoggerParamIdentifierKey];
      logger->_authMethod = clientState[FBSDKLoginManagerLoggerParamAuthMethodKey];
      logger->_loggingToken = clientState[FBSDKLoginManagerLoggerParamLoggingTokenKey];
      return logger;
    }
  }
  return nil;
}

- (instancetype)initWithLoggingToken:(NSString *)loggingToken
                            tracking:(FBSDKLoginTracking)tracking
{
  switch (tracking) {
    case FBSDKLoginTrackingEnabled:
      break;
    case FBSDKLoginTrackingLimited:
      return nil;
  }

  if ((self = [super init])) {
    _identifier = [NSUUID UUID].UUIDString;
    _extras = [NSMutableDictionary dictionary];
    _loggingToken = [loggingToken copy];
  }
  return self;
}

- (void)startSessionForLoginManager:(FBSDKLoginManager *)loginManager
{
  BOOL isReauthorize = ([FBSDKAccessToken currentAccessToken] != nil);
  BOOL willTryNative = NO;
  BOOL willTryBrowser = YES;
  NSString *behaviorString = @"FBSDKLoginBehaviorBrowser";

  [_extras addEntriesFromDictionary:@{
     FBSDKLoginManagerLoggerTryNative : @(willTryNative),
     FBSDKLoginManagerLoggerTryBrowser : @(willTryBrowser),
     @"isReauthorize" : @(isReauthorize),
     @"login_behavior" : behaviorString,
     @"default_audience" : [FBSDKLoginUtility stringForAudience:loginManager.defaultAudience],
     @"permissions" : [loginManager.requestedPermissions.allObjects componentsJoinedByString:@","] ?: @""
   }];

  [self logEvent:FBSDKAppEventNameFBSessionAuthStart params:[self _parametersForNewEvent]];
}

- (void)endSession
{
  [self logEvent:FBSDKAppEventNameFBSessionAuthEnd result:_lastResult error:_lastError];
  if (FBSDKAppEvents.flushBehavior != FBSDKAppEventsFlushBehaviorExplicitOnly) {
    [FBSDKAppEvents flush];
  }
}

- (void)startAuthMethod:(NSString *)authMethod
{
  _authMethod = [authMethod copy];
  [self logEvent:FBSDKAppEventNameFBSessionAuthMethodStart params:[self _parametersForNewEvent]];
}

- (void)endLoginWithResult:(FBSDKLoginManagerLoginResult *)result error:(NSError *)error
{
  NSString *resultString = @"";

  if (error != nil) {
    resultString = FBSDKLoginManagerLoggerResultErrorString;
  } else if (result.isCancelled) {
    resultString = FBSDKLoginManagerLoggerResultCancelString;
  } else if (result.isSkipped) {
    resultString = FBSDKLoginManagerLoggerResultSkippedString;
  } else if (result.token) {
    resultString = FBSDKLoginManagerLoggerResultSuccessString;
    if (result.declinedPermissions.count) {
      [FBSDKTypeUtility dictionary:_extras setObject:[result.declinedPermissions.allObjects componentsJoinedByString:@","] forKey:@"declined_permissions"];
    }
  }

  _lastResult = resultString;
  _lastError = error;
  [_extras addEntriesFromDictionary:result.loggingExtras];

  [self logEvent:FBSDKAppEventNameFBSessionAuthMethodEnd result:resultString error:error];
}

- (void)postLoginHeartbeat
{
  [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(heartbestTimerDidFire) userInfo:nil repeats:NO];
}

- (void)heartbestTimerDidFire
{
  [self logEvent:FBSDKAppEventNameFBSessionAuthHeartbeat result:_lastResult error:_lastError];
}

+ (NSDictionary<NSString *, id> *)parametersWithTimeStampAndClientState:(NSDictionary<NSString *, id> *)loginParams
                                                          forAuthMethod:(NSString *)authMethod
                                                                 logger:(FBSDKLoginManagerLogger *)logger
{
  NSMutableDictionary<NSString *, id> *params = [loginParams mutableCopy];

  NSTimeInterval timeValue = (NSTimeInterval)FBSDKMonotonicTimeGetCurrentSeconds();
  NSString *e2eTimestampString = [FBSDKBasicUtility JSONStringForObject:@{ @"init" : @(timeValue) }
                                                                  error:NULL
                                                   invalidObjectHandler:NULL];
  [FBSDKTypeUtility dictionary:params setObject:e2eTimestampString forKey:@"e2e"];

  NSDictionary<id, id> *existingState = [FBSDKBasicUtility objectForJSONString:params[FBSDKLoginManagerLoggingClientStateKey] error:NULL];
  [FBSDKTypeUtility dictionary:params
                     setObject:[FBSDKLoginManagerLogger clientStateForAuthMethod:authMethod
                                                                andExistingState:existingState
                                                                          logger:logger]
                        forKey:FBSDKLoginManagerLoggingClientStateKey];
  return params;
}

- (void)willAttemptAppSwitchingBehavior
{
  NSString *defaultUrlScheme = [NSString stringWithFormat:@"fb%@%@", FBSDKSettings.sharedSettings.appID, FBSDKSettings.sharedSettings.appURLSchemeSuffix ?: @""];
  BOOL isURLSchemeRegistered = [FBSDKInternalUtility.sharedUtility isRegisteredURLScheme:defaultUrlScheme];

  BOOL isFacebookAppCanOpenURLSchemeRegistered = [FBSDKInternalUtility.sharedUtility isRegisteredCanOpenURLScheme:FBSDK_CANOPENURL_FACEBOOK];
  BOOL isMessengerAppCanOpenURLSchemeRegistered = [FBSDKInternalUtility.sharedUtility isRegisteredCanOpenURLScheme:FBSDK_CANOPENURL_MESSENGER];

  [_extras addEntriesFromDictionary:@{
     @"isURLSchemeRegistered" : @(isURLSchemeRegistered),
     @"isFacebookAppCanOpenURLSchemeRegistered" : @(isFacebookAppCanOpenURLSchemeRegistered),
     @"isMessengerAppCanOpenURLSchemeRegistered" : @(isMessengerAppCanOpenURLSchemeRegistered),
   }];
}

- (void)logNativeAppDialogResult:(BOOL)result dialogDuration:(NSTimeInterval)dialogDuration
{
  NSOperatingSystemVersion iOS10Version = { .majorVersion = 10, .minorVersion = 0, .patchVersion = 0 };
  if ([NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:iOS10Version]) {
    [FBSDKTypeUtility dictionary:_extras setObject:@(dialogDuration) forKey:@"native_app_login_dialog_duration"];
    [FBSDKTypeUtility dictionary:_extras setObject:@(result) forKey:@"native_app_login_dialog_result"];
    [self logEvent:FBSDKAppEventNameFBSessionFASLoginDialogResult params:[self _parametersForNewEvent]];
  }
}

- (void)addSingleLoggingExtra:(id)extra forKey:(NSString *)key
{
  [FBSDKTypeUtility dictionary:_extras setObject:extra forKey:key];
}

#pragma mark - Private

- (NSString *)identifier
{
  return _identifier;
}

+ (NSString *)clientStateForAuthMethod:(NSString *)authMethod
                      andExistingState:(NSDictionary<NSString *, id> *)existingState
                                logger:(FBSDKLoginManagerLogger *)logger
{
  NSDictionary<NSString *, id> *clientState = @{
    FBSDKLoginManagerLoggerParamAuthMethodKey : authMethod ?: @"",
    FBSDKLoginManagerLoggerParamIdentifierKey : logger.identifier ?: NSUUID.UUID.UUIDString,
    FBSDKLoginManagerLoggingClientStateIsClientState : @YES,
  };

  if (existingState) {
    NSMutableDictionary<NSString *, id> *mutableState = [clientState mutableCopy];
    [mutableState addEntriesFromDictionary:existingState];
    clientState = mutableState;
  }

  return [FBSDKBasicUtility JSONStringForObject:clientState error:NULL invalidObjectHandler:NULL];
}

- (NSMutableDictionary<NSString *, id> *)_parametersForNewEvent
{
  NSMutableDictionary<NSString *, id> *eventParameters = [NSMutableDictionary new];

  // NOTE: We ALWAYS add all params to each event, to ensure predictable mapping on the backend.
  [FBSDKTypeUtility dictionary:eventParameters setObject:_identifier ?: FBSDKLoginManagerLoggerValueEmpty forKey:FBSDKLoginManagerLoggerParamIdentifierKey];
  [FBSDKTypeUtility dictionary:eventParameters setObject:@(round(1000 * [NSDate date].timeIntervalSince1970)) forKey:FBSDKLoginManagerLoggerParamTimestampKey];
  [FBSDKTypeUtility dictionary:eventParameters setObject:FBSDKLoginManagerLoggerValueEmpty forKey:FBSDKLoginManagerLoggerParamResultKey];
  [FBSDKTypeUtility dictionary:eventParameters setObject:_authMethod forKey:FBSDKLoginManagerLoggerParamAuthMethodKey];
  [FBSDKTypeUtility dictionary:eventParameters setObject:FBSDKLoginManagerLoggerValueEmpty forKey:FBSDKLoginManagerLoggerParamErrorCodeKey];
  [FBSDKTypeUtility dictionary:eventParameters setObject:FBSDKLoginManagerLoggerValueEmpty forKey:FBSDKLoginManagerLoggerParamErrorMessageKey];
  [FBSDKTypeUtility dictionary:eventParameters setObject:FBSDKLoginManagerLoggerValueEmpty forKey:FBSDKLoginManagerLoggerParamExtrasKey];
  [FBSDKTypeUtility dictionary:eventParameters setObject:_loggingToken ?: FBSDKLoginManagerLoggerValueEmpty forKey:FBSDKLoginManagerLoggerParamLoggingTokenKey];

  return eventParameters;
}

- (void)logEvent:(NSString *)eventName params:(NSMutableDictionary<NSString *, id> *)params
{
  if (_identifier) {
    NSString *extrasJSONString = [FBSDKBasicUtility JSONStringForObject:_extras
                                                                  error:NULL
                                                   invalidObjectHandler:NULL];
    if (extrasJSONString) {
      [FBSDKTypeUtility dictionary:params setObject:extrasJSONString forKey:FBSDKLoginManagerLoggerParamExtrasKey];
    }
    [_extras removeAllObjects];

    [FBSDKAppEvents logInternalEvent:eventName
                          parameters:params
                  isImplicitlyLogged:YES];
  }
}

- (void)logEvent:(NSString *)eventName result:(NSString *)result error:(NSError *)error
{
  NSMutableDictionary<NSString *, id> *params = [self _parametersForNewEvent];

  [FBSDKTypeUtility dictionary:params setObject:result forKey:FBSDKLoginManagerLoggerParamResultKey];

  if ([error.domain isEqualToString:FBSDKErrorDomain] || [error.domain isEqualToString:FBSDKLoginErrorDomain]) {
    // tease apart the structure.

    // first see if there is an explicit message in the error's userInfo. If not, default to the reason,
    // which is less useful.
    NSString *value = error.userInfo[@"error_message"] ?: error.userInfo[FBSDKErrorLocalizedDescriptionKey];
    [FBSDKTypeUtility dictionary:params setObject:value forKey:FBSDKLoginManagerLoggerParamErrorMessageKey];

    value = error.userInfo[FBSDKGraphRequestErrorGraphErrorCodeKey] ?: [NSString stringWithFormat:@"%ld", (long)error.code];
    [FBSDKTypeUtility dictionary:params setObject:value forKey:FBSDKLoginManagerLoggerParamErrorCodeKey];

    NSError *innerError = error.userInfo[NSUnderlyingErrorKey];
    if (innerError != nil) {
      value = innerError.userInfo[@"error_message"] ?: innerError.userInfo[NSLocalizedDescriptionKey];
      [FBSDKTypeUtility dictionary:_extras setObject:value forKey:@"inner_error_message"];

      value = innerError.userInfo[FBSDKGraphRequestErrorGraphErrorCodeKey] ?: [NSString stringWithFormat:@"%ld", (long)innerError.code];
      [FBSDKTypeUtility dictionary:_extras setObject:value forKey:@"inner_error_code"];
    }
  } else if (error) {
    [FBSDKTypeUtility dictionary:params setObject:@(error.code) forKey:FBSDKLoginManagerLoggerParamErrorCodeKey];
    [FBSDKTypeUtility dictionary:params setObject:error.localizedDescription forKey:FBSDKLoginManagerLoggerParamErrorMessageKey];
  }

  [self logEvent:eventName params:params];
}

@end

#endif
