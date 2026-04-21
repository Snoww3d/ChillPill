#pragma once

#include <CoreFoundation/CoreFoundation.h>

// Forward declarations for private IOKit HID event-system APIs.
// These symbols are exported by IOKit.framework at runtime but are absent from
// the public headers. Declaring the opaque handles as CFTypeRef gives Swift
// proper CF ARC bridging (CFRelease, Unmanaged, etc.) without needing a
// dedicated class-bridged type.

CFTypeRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);

int IOHIDEventSystemClientSetMatching(CFTypeRef client,
                                      CFDictionaryRef matching);

CFArrayRef IOHIDEventSystemClientCopyServices(CFTypeRef client);

CFTypeRef IOHIDServiceClientCopyProperty(CFTypeRef service,
                                         CFStringRef property);

CFTypeRef IOHIDServiceClientCopyEvent(CFTypeRef service,
                                      int64_t eventType,
                                      int32_t options,
                                      int64_t reserved);

double IOHIDEventGetFloatValue(CFTypeRef event, int32_t field);
