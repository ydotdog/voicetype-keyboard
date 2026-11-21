// Turns the hinge of an iPhone Duo simulator and reads the angle back. It runs
// inside the simulator, started with `xcrun simctl spawn <udid> <program> ...`,
// and scripts/ci/run_ios_tests.sh builds it on the machine that runs the tests.
// It is a tool for the tests only and is not part of the app.
//
// usage: duo_hinge set <degrees>   0 is closed, 130 half open, 180 fully open
//        duo_hinge angle           prints the angle the device reports and
//                                  whether the device calls it valid
//
// Simulator offers no command for the hinge. The device takes the hinge position
// from a vendor-defined HID event whose data is a serialized dictionary that names
// Simulator's hinge slider. That dictionary and the event's usage page and usage
// are the ones the fold helper of the callstack/agent-device project (MIT License)
// sends. The angle is read from CoreMotion's CMAngleManager, the source of the
// hinge angle that Xcode's devicectl reports. All of these are private interfaces
// of the simulator runtime. They are looked up when the program runs, so a missing
// one is reported by name instead of failing the build.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <math.h>
#import <objc/message.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

typedef CFDataRef (*SerializeFunction)(CFTypeRef object, CFOptionFlags options);
typedef CFTypeRef (*VendorEventFunction)(CFAllocatorRef allocator, uint64_t timestamp, uint32_t usagePage,
                                         uint32_t usage, uint32_t version, const uint8_t *bytes,
                                         CFIndex length, uint32_t options);
typedef CFTypeRef (*ClientFunction)(CFAllocatorRef allocator);
typedef void (*DispatchFunction)(CFTypeRef client, CFTypeRef event);

// kIOCFSerializeToBinary
static const CFOptionFlags SerializeToBinary = 1;
static const uint32_t SimulatorControlUsagePage = 0xff61;
static const uint32_t SimulatorControlUsage = 0x5b;

static void *find(void *library, const char *name) {
  void *function = dlsym(library, name);
  if (function == NULL) {
    fprintf(stderr, "duo_hinge: %s is not in this simulator runtime\n", name);
  }
  return function;
}

static int setAngle(double degrees) {
  void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
  if (iokit == NULL) {
    fprintf(stderr, "duo_hinge: IOKit did not load: %s\n", dlerror());
    return 3;
  }
  SerializeFunction serialize = (SerializeFunction)find(iokit, "IOCFSerialize");
  VendorEventFunction createEvent = (VendorEventFunction)find(iokit, "IOHIDEventCreateVendorDefinedEvent");
  ClientFunction createClient = (ClientFunction)find(iokit, "IOHIDEventSystemClientCreate");
  DispatchFunction dispatchEvent = (DispatchFunction)find(iokit, "IOHIDEventSystemClientDispatchEvent");
  if (serialize == NULL || createEvent == NULL || createClient == NULL || dispatchEvent == NULL) {
    return 3;
  }

  NSDictionary *control = @{
    @"provider" : @"com.apple.Virtualization.VirtualMachines",
    @"source" : @"hinge-slider-control",
    @"type" : @"range",
    @"value" : @(degrees),
  };
  CFDataRef data = serialize((__bridge CFTypeRef)control, SerializeToBinary);
  if (data == NULL) {
    fprintf(stderr, "duo_hinge: the hinge control could not be serialized\n");
    return 4;
  }
  CFTypeRef event = createEvent(kCFAllocatorDefault, mach_absolute_time(), SimulatorControlUsagePage,
                                SimulatorControlUsage, 0, CFDataGetBytePtr(data), CFDataGetLength(data), 0);
  CFRelease(data);
  if (event == NULL) {
    fprintf(stderr, "duo_hinge: no HID event was created\n");
    return 4;
  }
  CFTypeRef client = createClient(kCFAllocatorDefault);
  if (client == NULL) {
    CFRelease(event);
    fprintf(stderr, "duo_hinge: no HID event system client was created\n");
    return 4;
  }
  dispatchEvent(client, event);
  CFRelease(event);
  CFRelease(client);
  printf("sent %.1f\n", degrees);
  return 0;
}

static BOOL answers(id target, SEL selector) {
  return target != nil && [target respondsToSelector:selector];
}

static int readAngle(void) {
  dlopen("/System/Library/Frameworks/CoreMotion.framework/CoreMotion", RTLD_NOW);
  Class managerClass = NSClassFromString(@"CMAngleManager");
  SEL isAvailable = NSSelectorFromString(@"isAvailable");
  SEL start = NSSelectorFromString(@"startAngleUpdatesToQueue:handler:");
  SEL stop = NSSelectorFromString(@"stopAngleUpdates");
  SEL angleDegrees = NSSelectorFromString(@"angleDegrees");
  SEL isAngleValid = NSSelectorFromString(@"isAngleValid");
  if (managerClass == Nil || !answers(managerClass, isAvailable) ||
      !((BOOL (*)(id, SEL))objc_msgSend)(managerClass, isAvailable) ||
      ![managerClass instancesRespondToSelector:start]) {
    fprintf(stderr, "duo_hinge: CMAngleManager is not available in this simulator runtime\n");
    return 3;
  }

  id manager = [[managerClass alloc] init];
  NSOperationQueue *queue = [[NSOperationQueue alloc] init];
  queue.maxConcurrentOperationCount = 1;
  dispatch_semaphore_t sampled = dispatch_semaphore_create(0);
  __block double degrees = NAN;
  __block BOOL valid = NO;
  __block BOOL received = NO;
  // The manager calls this with the sample first. The block reads only that
  // argument; what follows it is ignored.
  void (^handler)(id) = ^(id sample) {
    if (!answers(sample, angleDegrees)) {
      return;
    }
    degrees = ((float (*)(id, SEL))objc_msgSend)(sample, angleDegrees);
    valid = answers(sample, isAngleValid) && ((BOOL (*)(id, SEL))objc_msgSend)(sample, isAngleValid);
    if (!received) {
      received = YES;
      dispatch_semaphore_signal(sampled);
    }
  };
  ((void (*)(id, SEL, NSOperationQueue *, id))objc_msgSend)(manager, start, queue, handler);
  long timedOut = dispatch_semaphore_wait(sampled, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
  if (answers(manager, stop)) {
    ((void (*)(id, SEL))objc_msgSend)(manager, stop);
  }
  [queue waitUntilAllOperationsAreFinished];
  if (timedOut != 0) {
    fprintf(stderr, "duo_hinge: CMAngleManager gave no sample within 3 seconds\n");
    return 4;
  }
  printf("%.1f %s\n", degrees, valid ? "valid" : "invalid");
  return 0;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc == 3 && strcmp(argv[1], "set") == 0) {
      char *end = NULL;
      double degrees = strtod(argv[2], &end);
      if (end == argv[2] || *end != '\0' || !isfinite(degrees) || degrees < 0 || degrees > 180) {
        fprintf(stderr, "duo_hinge: the angle must be a number from 0 to 180\n");
        return 2;
      }
      return setAngle(degrees);
    }
    if (argc == 2 && strcmp(argv[1], "angle") == 0) {
      return readAngle();
    }
    fprintf(stderr, "usage: duo_hinge set <degrees> | angle\n");
    return 2;
  }
}
