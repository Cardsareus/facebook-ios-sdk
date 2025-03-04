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

#import "FBSDKAppEventsDeviceInfo.h"

#import <sys/sysctl.h>
#import <sys/utsname.h>

#if !TARGET_OS_TV
 #import <CoreTelephony/CTCarrier.h>
 #import <CoreTelephony/CTTelephonyNetworkInfo.h>
#endif

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import <FBSDKCoreKit_Basics/FBSDKCoreKit_Basics.h>

#import "FBSDKAppEventsUtility.h"
#import "FBSDKDynamicFrameworkLoader.h"
#import "FBSDKInternalUtility+Internal.h"
#import "FBSDKSettings+Internal.h"

#define FB_ARRAY_COUNT(x) sizeof(x) / sizeof(x[0])

static const u_int FB_GROUP1_RECHECK_DURATION = 30 * 60; // seconds

// Apple reports storage in binary gigabytes (1024^3) in their About menus, etc.
static const u_int FB_GIGABYTE = 1024 * 1024 * 1024; // bytes

@interface FBSDKAppEventsDeviceInfo ()

// Ephemeral data, may change during the lifetime of an app.  We collect them in different
// 'group' frequencies - group1 may gets collected once every 30 minutes.

// group1
@property (nonatomic) NSString *carrierName;
@property (nonatomic) NSString *timeZoneAbbrev;
@property (nonatomic) unsigned long long remainingDiskSpaceGB;
@property (nonatomic) NSString *timeZoneName;

// Persistent data, but we maintain it to make rebuilding the device info as fast as possible.
@property (nonatomic) NSString *bundleIdentifier;
@property (nonatomic) NSString *longVersion;
@property (nonatomic) NSString *shortVersion;
@property (nonatomic) NSString *sysVersion;
@property (nonatomic) NSString *machine;
@property (nonatomic) NSString *language;
@property (nonatomic) unsigned long long totalDiskSpaceGB;
@property (nonatomic) unsigned long long coreCount;
@property (nonatomic) CGFloat width;
@property (nonatomic) CGFloat height;
@property (nonatomic) CGFloat density;

// Other state
@property (nonatomic) long lastGroup1CheckTime;
@property (nonatomic) BOOL isEncodingDirty;
@property (nonatomic) NSString *encodedDeviceInfo;
@end

@implementation FBSDKAppEventsDeviceInfo

@synthesize encodedDeviceInfo = _encodedDeviceInfo;

#pragma mark - Public Methods

+ (void)extendDictionaryWithDeviceInfo:(NSMutableDictionary<NSString *, id> *)dictionary
{
  [FBSDKTypeUtility dictionary:dictionary setObject:[self.sharedDeviceInfo encodedDeviceInfo] forKey:@"extinfo"];
}

#pragma mark - Internal Methods

+ (void)initialize
{
  if (self == FBSDKAppEventsDeviceInfo.class) {
    [self.sharedDeviceInfo _collectPersistentData];
  }
}

+ (instancetype)sharedDeviceInfo
{
  static FBSDKAppEventsDeviceInfo *_sharedDeviceInfo = nil;
  if (_sharedDeviceInfo == nil) {
    _sharedDeviceInfo = [FBSDKAppEventsDeviceInfo new];
  }
  return _sharedDeviceInfo;
}

- (instancetype)init
{
  if ((self = [super init])) {
    _isEncodingDirty = YES;
  }
  return self;
}

- (NSString *)encodedDeviceInfo
{
  @synchronized(self) {
    BOOL isGroup1Expired = [self _isGroup1Expired];
    BOOL isEncodingExpired = isGroup1Expired; // Can || other groups in if we add them

    // As long as group1 hasn't expired, we can just return the last generated value
    if (_encodedDeviceInfo && !isEncodingExpired) {
      return _encodedDeviceInfo;
    }

    if (isGroup1Expired) {
      [self _collectGroup1Data];
    }

    if (_isEncodingDirty) {
      self.encodedDeviceInfo = [self _generateEncoding];
      _isEncodingDirty = NO;
    }

    return _encodedDeviceInfo;
  }
}

- (void)setEncodedDeviceInfo:(NSString *)encodedDeviceInfo
{
  @synchronized(self) {
    if (![_encodedDeviceInfo isEqualToString:encodedDeviceInfo]) {
      _encodedDeviceInfo = [encodedDeviceInfo copy];
    }
  }
}

// This data need only be collected once.
- (void)_collectPersistentData
{
  // Bundle stuff
  NSBundle *mainBundle = NSBundle.mainBundle;
  _bundleIdentifier = mainBundle.bundleIdentifier;
  _longVersion = [mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
  _shortVersion = [mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];

  // Locale stuff
  _language = NSLocale.currentLocale.localeIdentifier;

  // Device stuff
  UIDevice *device = [UIDevice currentDevice];
  _sysVersion = device.systemVersion;
  _coreCount = [FBSDKAppEventsDeviceInfo _coreCount];

  UIScreen *sc = [UIScreen mainScreen];
  CGRect sr = sc.bounds;
  _width = sr.size.width;
  _height = sr.size.height;
  _density = sc.scale;

  struct utsname systemInfo;
  uname(&systemInfo);
  _machine = @(systemInfo.machine);

  // Disk space stuff
  float totalDiskSpace = [FBSDKAppEventsDeviceInfo _getTotalDiskSpace].floatValue;
  _totalDiskSpaceGB = (unsigned long long)round(totalDiskSpace / FB_GIGABYTE);
}

- (BOOL)_isGroup1Expired
{
  return ([self unixTimeNow] - _lastGroup1CheckTime) > FB_GROUP1_RECHECK_DURATION;
}

// This data is collected only once every GROUP1_RECHECK_DURATION.
- (void)_collectGroup1Data
{
  const BOOL shouldUseCachedValues = [FBSDKSettings shouldUseCachedValuesForExpensiveMetadata];

  if (!_carrierName || !shouldUseCachedValues) {
    NSString *newCarrierName = [FBSDKAppEventsDeviceInfo _getCarrier];
    if (!_carrierName || ![newCarrierName isEqualToString:_carrierName]) {
      _carrierName = newCarrierName;
      _isEncodingDirty = YES;
    }
  }

  if (!_timeZoneName || !_timeZoneAbbrev || !shouldUseCachedValues) {
    NSTimeZone *timeZone = NSTimeZone.systemTimeZone;
    NSString *timeZoneName = timeZone.name;
    if (!_timeZoneName || ![timeZoneName isEqualToString:_timeZoneName]) {
      _timeZoneName = timeZoneName;
      _timeZoneAbbrev = timeZone.abbreviation;
      _isEncodingDirty = YES;
    }
  }

  // Remaining disk space
  float remainingDiskSpace = [FBSDKAppEventsDeviceInfo _getRemainingDiskSpace].floatValue;
  unsigned long long newRemainingDiskSpaceGB = (unsigned long long)round(remainingDiskSpace / FB_GIGABYTE);
  if (_remainingDiskSpaceGB != newRemainingDiskSpaceGB) {
    _remainingDiskSpaceGB = newRemainingDiskSpaceGB;
    _isEncodingDirty = YES;
  }

  _lastGroup1CheckTime = [self unixTimeNow];
}

- (NSString *)_generateEncoding
{
  // Keep a bit of precision on density as it's the most likely to become non-integer.
  NSString *densityString = _density ? [NSString stringWithFormat:@"%.02f", _density] : @"";

  NSArray *arr = @[
    @"i2", // version - starts with 'i' for iOS, we'll use 'a' for Android
    _bundleIdentifier ?: @"",
    _longVersion ?: @"",
    _shortVersion ?: @"",
    _sysVersion ?: @"",
    _machine ?: @"",
    _language ?: @"",
    _timeZoneAbbrev ?: @"",
    _carrierName ?: @"",
    _width ? @((unsigned long)_width) : @"",
    _height ? @((unsigned long)_height) : @"",
    densityString,
    @(_coreCount) ?: @"",
    @(_totalDiskSpaceGB) ?: @"",
    @(_remainingDiskSpaceGB) ?: @"",
    _timeZoneName ?: @""
  ];

  return [FBSDKBasicUtility JSONStringForObject:arr error:NULL invalidObjectHandler:NULL];
}

#pragma mark - Helper Methods

- (NSTimeInterval)unixTimeNow
{
  return round([NSDate date].timeIntervalSince1970);
}

+ (NSNumber *)_getTotalDiskSpace
{
  NSDictionary<NSString *, id> *attrs = [[NSFileManager new] attributesOfFileSystemForPath:NSHomeDirectory()
                                                                                     error:nil];
  return attrs[NSFileSystemSize];
}

+ (NSNumber *)_getRemainingDiskSpace
{
  NSDictionary<NSString *, id> *attrs = [[NSFileManager new] attributesOfFileSystemForPath:NSHomeDirectory()
                                                                                     error:nil];
  return attrs[NSFileSystemFreeSize];
}

+ (uint)_coreCount
{
  return [FBSDKAppEventsDeviceInfo _readSysCtlUInt:CTL_HW type:HW_AVAILCPU];
}

+ (uint)_readSysCtlUInt:(int)ctl type:(int)type
{
  int mib[2] = {ctl, type};
  uint value;
  size_t size = sizeof value;
  if (0 != sysctl(mib, FB_ARRAY_COUNT(mib), &value, &size, NULL, 0)) {
    return 0;
  }
  return value;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
+ (NSString *)_getCarrier
{
#if TARGET_OS_TV || TARGET_OS_SIMULATOR
  return @"NoCarrier";
#else
  // Dynamically load class for this so calling app doesn't need to link framework in.
  CTTelephonyNetworkInfo *networkInfo = [[fbsdkdfl_CTTelephonyNetworkInfoClass() alloc] init];
  CTCarrier *carrier = networkInfo.subscriberCellularProvider;
  return carrier.carrierName ?: @"NoCarrier";
#endif
}

#pragma clang diagnostic pop

@end
