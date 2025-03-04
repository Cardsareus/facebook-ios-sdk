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

#import "FBSDKCodelessIndexer.h"

#import <UIKit/UIKit.h>

#import <FBSDKCoreKit_Basics/FBSDKCoreKit_Basics.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

#import "FBSDKAdvertiserIDProviding.h"
#import "FBSDKAppEventsUtility.h"
#import "FBSDKDataPersisting.h"
#import "FBSDKGraphRequestConnecting.h"
#import "FBSDKGraphRequestConnectionFactoryProtocol.h"
#import "FBSDKGraphRequestFactoryProtocol.h"
#import "FBSDKGraphRequestHTTPMethod.h"
#import "FBSDKGraphRequestProtocol.h"
#import "FBSDKInternalUtility+Internal.h"
#import "FBSDKObjectDecoding.h"
#import "FBSDKServerConfiguration.h"
#import "FBSDKServerConfigurationManager.h"
#import "FBSDKServerConfigurationProviding.h"
#import "FBSDKSettings+Internal.h"
#import "FBSDKSettingsProtocol.h"
#import "FBSDKSwizzling.h"
#import "FBSDKUnarchiverProvider.h"
#import "FBSDKUtility.h"
#import "FBSDKViewHierarchy.h"
#import "FBSDKViewHierarchyMacros.h"

@interface FBSDKCodelessIndexer ()

@property (class, nullable, nonatomic, readonly) id<FBSDKGraphRequestFactory> graphRequestFactory;
@property (class, nullable, nonatomic, readonly) id<FBSDKServerConfigurationProviding> serverConfigurationProvider;
@property (class, nullable, nonatomic, readonly) id<FBSDKDataPersisting> store;
@property (class, nullable, nonatomic, readonly, copy) id<FBSDKGraphRequestConnectionFactory> graphRequestConnectionFactory;
@property (class, nullable, nonatomic, readonly, copy) Class<FBSDKSwizzling> swizzler;
@property (class, nullable, nonatomic, readonly) id<FBSDKSettings> settings;
@property (class, nullable, nonatomic, readonly) id<FBSDKAdvertiserIDProviding> advertiserIDProvider;

@end

@implementation FBSDKCodelessIndexer

static BOOL _isCodelessIndexing;
static BOOL _isCheckingSession;
static BOOL _isCodelessIndexingEnabled;
static BOOL _isGestureSet;

static NSMutableDictionary<NSString *, id> *_codelessSetting;
static const NSTimeInterval kTimeout = 4.0;

static NSString *_deviceSessionID;
static NSTimer *_appIndexingTimer;
static NSString *_lastTreeHash;
static id<FBSDKGraphRequestFactory> _graphRequestFactory;
static id<FBSDKServerConfigurationProviding> _serverConfigurationProvider;
static id<FBSDKDataPersisting> _store;
static id<FBSDKGraphRequestConnectionFactory> _graphRequestConnectionFactory;
static Class<FBSDKSwizzling> _swizzler;
static id<FBSDKSettings> _settings;
static id<FBSDKAdvertiserIDProviding> _advertiserIDProvider;
static id<FBSDKSettings> _settings;

+ (void)configureWithGraphRequestFactory:(id<FBSDKGraphRequestFactory>)graphRequestFactory
             serverConfigurationProvider:(id<FBSDKServerConfigurationProviding>)serverConfigurationProvider
                                   store:(id<FBSDKDataPersisting>)store
           graphRequestConnectionFactory:(id<FBSDKGraphRequestConnectionFactory>)graphRequestConnectionFactory
                                swizzler:(Class<FBSDKSwizzling>)swizzler
                                settings:(id<FBSDKSettings>)settings
                    advertiserIDProvider:(id<FBSDKAdvertiserIDProviding>)advertiserIDProvider
{
  if (self == FBSDKCodelessIndexer.class) {
    _graphRequestFactory = graphRequestFactory;
    _serverConfigurationProvider = serverConfigurationProvider;
    _store = store;
    _graphRequestConnectionFactory = graphRequestConnectionFactory;
    _swizzler = swizzler;
    _settings = settings;
    _advertiserIDProvider = advertiserIDProvider;
  }
}

+ (id<FBSDKGraphRequestFactory>)graphRequestFactory
{
  return _graphRequestFactory;
}

+ (id<FBSDKServerConfigurationProviding>)serverConfigurationProvider
{
  return _serverConfigurationProvider;
}

+ (id<FBSDKDataPersisting>)store
{
  return _store;
}

+ (id<FBSDKGraphRequestConnectionFactory>)graphRequestConnectionFactory
{
  return _graphRequestConnectionFactory;
}

+ (Class<FBSDKSwizzling>)swizzler
{
  return _swizzler;
}

+ (id<FBSDKSettings>)settings
{
  return _settings;
}

+ (id<FBSDKAdvertiserIDProviding>)advertiserIDProvider
{
  return _advertiserIDProvider;
}

+ (void)enable
{
  if (_isGestureSet) {
    return;
  }

  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
  #if TARGET_OS_SIMULATOR
    [self setupGesture];
  #else
    [self loadCodelessSettingWithCompletionBlock:^(BOOL isCodelessSetupEnabled, NSError *error) {
      if (isCodelessSetupEnabled) {
        [self setupGesture];
      }
    }];
  #endif
  });
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
// DO NOT call this function, it is only called once in the enable function
+ (void)loadCodelessSettingWithCompletionBlock:(FBSDKCodelessSettingLoadBlock)completionBlock
{
  NSString *appID = [self.settings appID];
  if (appID == nil) {
    return;
  }

  [self.serverConfigurationProvider loadServerConfigurationWithCompletionBlock:^(FBSDKServerConfiguration *serverConfiguration, NSError *serverConfigurationLoadingError) {
    if (!serverConfiguration.isCodelessEventsEnabled) {
      return;
    }

    // load the defaults
    NSString *defaultKey = [NSString stringWithFormat:CODELESS_SETTING_KEY, appID];
    NSData *data = [self.store objectForKey:defaultKey];
    if ([data isKindOfClass:NSData.class]) {
      NSMutableDictionary<NSString *, id> *codelessSetting = nil;
      id<FBSDKObjectDecoding> unarchiver = [FBSDKUnarchiverProvider createInsecureUnarchiverFor:data];
      @try {
        codelessSetting = [unarchiver decodeObjectOfClass:NSDictionary.class forKey:NSKeyedArchiveRootObjectKey];
      } @catch (NSException *ex) {
        // ignore decoding exceptions
      }
      if (codelessSetting) {
        _codelessSetting = codelessSetting;
      }
    }

    if (
      _codelessSetting
      && [self _codelessSetupTimestampIsValid:[FBSDKTypeUtility dictionary:_codelessSetting objectForKey:CODELESS_SETTING_TIMESTAMP_KEY ofType:NSObject.class]]
    ) {
      completionBlock([FBSDKTypeUtility boolValue:[FBSDKTypeUtility dictionary:_codelessSetting objectForKey:CODELESS_SETUP_ENABLED_KEY ofType:NSObject.class]], nil);
    } else {
      _codelessSetting = [NSMutableDictionary new];
      id<FBSDKGraphRequest> request = [self requestToLoadCodelessSetup:appID];
      if (request == nil) {
        return;
      }
      id<FBSDKGraphRequestConnecting> requestConnection = [self.graphRequestConnectionFactory createGraphRequestConnection];
      requestConnection.timeout = kTimeout;
      [requestConnection addRequest:request completion:^(id<FBSDKGraphRequestConnecting> connection, id result, NSError *codelessLoadingError) {
        if (codelessLoadingError) {
          return;
        }

        NSDictionary<NSString *, id> *resultDictionary = [FBSDKTypeUtility dictionaryValue:result];
        if (resultDictionary) {
          BOOL isCodelessSetupEnabled = [FBSDKTypeUtility boolValue:resultDictionary[CODELESS_SETUP_ENABLED_FIELD]];
          [FBSDKTypeUtility dictionary:_codelessSetting setObject:@(isCodelessSetupEnabled) forKey:CODELESS_SETUP_ENABLED_KEY];
          [FBSDKTypeUtility dictionary:_codelessSetting setObject:[NSDate date] forKey:CODELESS_SETTING_TIMESTAMP_KEY];
          // update the cached copy in user defaults
          [self.store setObject:[NSKeyedArchiver archivedDataWithRootObject:_codelessSetting] forKey:defaultKey];
          completionBlock(isCodelessSetupEnabled, codelessLoadingError);
        }
      }];
      [requestConnection start];
    }
  }];
}

#pragma clang diagnostic pop

+ (id<FBSDKGraphRequest>)requestToLoadCodelessSetup:(NSString *)appID
{
  NSString *advertiserID = self.advertiserIDProvider.advertiserID;
  if (!advertiserID) {
    return nil;
  }

  NSDictionary<NSString *, NSString *> *parameters = @{
    @"fields" : CODELESS_SETUP_ENABLED_FIELD,
    @"advertiser_id" : advertiserID
  };
  id<FBSDKGraphRequest> request = [self.graphRequestFactory createGraphRequestWithGraphPath:appID
                                                                                 parameters:parameters
                                                                                tokenString:nil
                                                                                 HTTPMethod:nil
                                                                                      flags:FBSDKGraphRequestFlagSkipClientToken | FBSDKGraphRequestFlagDisableErrorRecovery];
  return request;
}

+ (BOOL)_codelessSetupTimestampIsValid:(NSDate *)timestamp
{
  return (timestamp != nil && [[NSDate date] timeIntervalSinceDate:timestamp] < CODELESS_SETTING_CACHE_TIMEOUT);
}

+ (void)setupGesture
{
  _isGestureSet = YES;
  UIApplication.sharedApplication.applicationSupportsShakeToEdit = YES;
  Class class = UIApplication.class;

  [self.swizzler swizzleSelector:@selector(motionBegan:withEvent:)
                         onClass:class
                       withBlock:^{
                         if (FBSDKServerConfigurationManager.shared.cachedServerConfiguration.isCodelessEventsEnabled) {
                           [self checkCodelessIndexingSession];
                         }
                       }
                           named:@"motionBegan"];
}

+ (void)checkCodelessIndexingSession
{
  if (_isCheckingSession) {
    return;
  }

  _isCheckingSession = YES;
  NSDictionary<NSString *, id> *parameters = @{
    CODELESS_INDEXING_SESSION_ID_KEY : [self currentSessionDeviceID],
    CODELESS_INDEXING_EXT_INFO_KEY : [self extInfo]
  };
  id<FBSDKGraphRequest> request = [_graphRequestFactory createGraphRequestWithGraphPath:[NSString stringWithFormat:@"%@/%@",
                                                                                         [self.settings appID],
                                                                                         CODELESS_INDEXING_SESSION_ENDPOINT]
                                                                             parameters:parameters
                                                                             HTTPMethod:FBSDKHTTPMethodPOST];
  [request startWithCompletion:^(id<FBSDKGraphRequestConnecting> connection, id result, NSError *error) {
    _isCheckingSession = NO;
    if ([result isKindOfClass:[NSDictionary<NSString *, id> class]]) {
      _isCodelessIndexingEnabled = [((NSDictionary<NSString *, id> *)result)[CODELESS_INDEXING_STATUS_KEY] boolValue];
      if (_isCodelessIndexingEnabled) {
        _lastTreeHash = nil;
        if (!_appIndexingTimer) {
          _appIndexingTimer = [NSTimer timerWithTimeInterval:CODELESS_INDEXING_UPLOAD_INTERVAL_IN_SECONDS
                                                      target:self
                                                    selector:@selector(startIndexing)
                                                    userInfo:nil
                                                     repeats:YES];
          [NSRunLoop.mainRunLoop addTimer:_appIndexingTimer forMode:NSDefaultRunLoopMode];
        }
      } else {
        _deviceSessionID = nil;
      }
    }
  }];
}

+ (NSString *)currentSessionDeviceID
{
  if (!_deviceSessionID) {
    _deviceSessionID = [NSUUID UUID].UUIDString;
  }
  return _deviceSessionID;
}

+ (NSString *)extInfo
{
  struct utsname systemInfo;
  uname(&systemInfo);
  NSString *machine = @(systemInfo.machine);
  NSString *advertiserID = [FBSDKAppEventsUtility.shared advertiserID] ?: @"";
  machine = machine ?: @"";
  NSString *debugStatus = [FBSDKAppEventsUtility isDebugBuild] ? @"1" : @"0";
#if TARGET_OS_SIMULATOR
  NSString *isSimulator = @"1";
#else
  NSString *isSimulator = @"0";
#endif
  NSLocale *locale = NSLocale.currentLocale;
  NSString *languageCode = [locale objectForKey:NSLocaleLanguageCode];
  NSString *countryCode = [locale objectForKey:NSLocaleCountryCode];
  NSString *localeString = locale.localeIdentifier;
  if (languageCode && countryCode) {
    localeString = [NSString stringWithFormat:@"%@_%@", languageCode, countryCode];
  }

  NSString *extinfo = [FBSDKBasicUtility JSONStringForObject:@[machine,
                                                               advertiserID,
                                                               debugStatus,
                                                               isSimulator,
                                                               localeString]
                                                       error:NULL
                                        invalidObjectHandler:NULL];

  return extinfo ?: @"";
}

+ (void)startIndexing
{
  if (!_isCodelessIndexingEnabled) {
    return;
  }

  if (UIApplicationStateActive != UIApplication.sharedApplication.applicationState) {
    return;
  }

  // If userAgentSuffix begins with Unity, trigger unity code to upload view hierarchy
  NSString *userAgentSuffix = FBSDKSettings.sharedSettings.userAgentSuffix;
  if (userAgentSuffix != nil && [userAgentSuffix hasPrefix:@"Unity"]) {
    Class FBUnityUtility = objc_lookUpClass("FBUnityUtility");
    SEL selector = NSSelectorFromString(@"triggerUploadViewHierarchy");
    if (FBUnityUtility && selector && [FBUnityUtility respondsToSelector:selector]) {
      #pragma clang diagnostic push
      #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      [FBUnityUtility performSelector:selector];
      #pragma clang diagnostic pop
    }
  } else {
    [self uploadIndexing];
  }
}

+ (void)uploadIndexing
{
  if (_isCodelessIndexing) {
    return;
  }

  NSString *tree = [FBSDKCodelessIndexer currentViewTree];

  [self uploadIndexing:tree];
}

+ (void)uploadIndexing:(NSString *)tree
{
  if (_isCodelessIndexing) {
    return;
  }

  if (!tree) {
    return;
  }

  NSString *currentTreeHash = [FBSDKUtility SHA256Hash:tree];
  if (_lastTreeHash && [_lastTreeHash isEqualToString:currentTreeHash]) {
    return;
  }

  _lastTreeHash = currentTreeHash;

  NSBundle *mainBundle = NSBundle.mainBundle;
  NSString *version = [mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
  id<FBSDKGraphRequest> request = [_graphRequestFactory createGraphRequestWithGraphPath:[NSString stringWithFormat:@"%@/%@",
                                                                                         [self.settings appID],
                                                                                         CODELESS_INDEXING_ENDPOINT]
                                                                             parameters:@{
                                     CODELESS_INDEXING_TREE_KEY : tree,
                                     CODELESS_INDEXING_APP_VERSION_KEY : version ?: @"",
                                     CODELESS_INDEXING_PLATFORM_KEY : @"iOS",
                                     CODELESS_INDEXING_SESSION_ID_KEY : [self currentSessionDeviceID]
                                   }
                                                                             HTTPMethod:FBSDKHTTPMethodPOST];
  _isCodelessIndexing = YES;
  [request startWithCompletion:^(id<FBSDKGraphRequestConnecting> connection, id result, NSError *error) {
    _isCodelessIndexing = NO;
    if ([result isKindOfClass:[NSDictionary<NSString *, id> class]]) {
      _isCodelessIndexingEnabled = [result[CODELESS_INDEXING_STATUS_KEY] boolValue];
      if (!_isCodelessIndexingEnabled) {
        _deviceSessionID = nil;
      }
    }
  }];
}

+ (NSString *)currentViewTree
{
  NSMutableArray *trees = [NSMutableArray array];

  NSArray *windows = UIApplication.sharedApplication.windows;
  for (UIWindow *window in windows) {
    NSDictionary<NSString *, id> *tree = [FBSDKViewHierarchy recursiveCaptureTreeWithCurrentNode:window
                                                                                      targetNode:nil
                                                                                   objAddressSet:nil
                                                                                            hash:YES];
    if (tree) {
      if (window.isKeyWindow) {
        [trees insertObject:tree atIndex:0];
      } else {
        [FBSDKTypeUtility array:trees addObject:tree];
      }
    }
  }

  if (0 == trees.count) {
    return nil;
  }

  NSArray *viewTrees = [trees reverseObjectEnumerator].allObjects;

  NSData *data = UIImageJPEGRepresentation([FBSDKCodelessIndexer screenshot], 0.5);
  NSString *screenshot = [data base64EncodedStringWithOptions:0];

  NSMutableDictionary<NSString *, id> *treeInfo = [NSMutableDictionary dictionary];

  [FBSDKTypeUtility dictionary:treeInfo setObject:viewTrees forKey:@"view"];
  [FBSDKTypeUtility dictionary:treeInfo setObject:screenshot ?: @"" forKey:@"screenshot"];

  NSString *tree = nil;
  data = [FBSDKTypeUtility dataWithJSONObject:treeInfo options:0 error:nil];
  if (data) {
    tree = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  }

  return tree;
}

+ (UIImage *)screenshot
{
  UIWindow *window = [FBSDKInternalUtility.sharedUtility findWindow];
  if (!window) {
    return nil;
  }

  UIGraphicsBeginImageContext(window.bounds.size);
  [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
  UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
  UIGraphicsEndImageContext();

  return image;
}

+ (NSDictionary<NSString *, NSNumber *> *)dimensionOf:(NSObject *)obj
{
  UIView *view = nil;

  if ([obj isKindOfClass:UIView.class]) {
    view = (UIView *)obj;
  } else if ([obj isKindOfClass:UIViewController.class]) {
    view = ((UIViewController *)obj).view;
  }

  CGRect frame = view.frame;
  CGPoint offset = CGPointZero;

  if ([view isKindOfClass:UIScrollView.class]) {
    offset = ((UIScrollView *)view).contentOffset;
  }

  return @{
    CODELESS_VIEW_TREE_TOP_KEY : @((int)frame.origin.y),
    CODELESS_VIEW_TREE_LEFT_KEY : @((int)frame.origin.x),
    CODELESS_VIEW_TREE_WIDTH_KEY : @((int)frame.size.width),
    CODELESS_VIEW_TREE_HEIGHT_KEY : @((int)frame.size.height),
    CODELESS_VIEW_TREE_OFFSET_X_KEY : @((int)offset.x),
    CODELESS_VIEW_TREE_OFFSET_Y_KEY : @((int)offset.y),
    CODELESS_VIEW_TREE_VISIBILITY_KEY : view.isHidden ? @4 : @0
  };
}

#if DEBUG
 #if FBTEST

+ (void)reset
{
  _isCheckingSession = NO;
  _isCodelessIndexing = NO;
  _isCodelessIndexingEnabled = NO;
  _isGestureSet = NO;
  _codelessSetting = nil;
  _graphRequestFactory = nil;
  _serverConfigurationProvider = nil;
  _store = nil;
  _graphRequestConnectionFactory = nil;
  _swizzler = nil;
  _settings = nil;
  _advertiserIDProvider = nil;
  _deviceSessionID = nil;
  _lastTreeHash = nil;
}

+ (void)resetIsCodelessIndexing
{
  _isCodelessIndexing = NO;
}

+ (BOOL)isCheckingSession
{
  return _isCheckingSession;
}

+ (NSTimer *)appIndexingTimer
{
  return _appIndexingTimer;
}

 #endif
#endif

@end

#endif
