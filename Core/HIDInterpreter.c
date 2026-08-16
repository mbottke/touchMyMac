//
//  HIDInterpreter.c
//  Touch Up Core
//
//  Created by Sebastian Hueber on 03.02.23.
//

#include "HIDInterpreter.h"
#include <unistd.h>
#include <os/log.h>
#include "TUCTouchInputManager-C.h"

#include <mach/mach_port.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>

#include <CoreGraphics/CoreGraphics.h>

#pragma mark - Global variables

static void* gTouchManager;

static CFRunLoopRef gRunLoopRef;

static IOHIDManagerRef gHidManager;

IOHIDQueueRef gQueue;


uint8_t gAreElementRefsSet = 0;

IOHIDElementRef         gApplicationCollectionElement;
IOHIDElementRef         gScanTimeElement;
CFMutableArrayRef       gTouchCollectionElements;

/**
 stores values for the touch collections: cookie -> latest value
 in hybrid mode (especially if order of touches moves) this data has to be set to last state per collection element receiving touches now
 */
CFMutableDictionaryRef  gStoredInputValues; //


CFIndex gContactCount = 1;
CFIndex gHybridOffset = 0; // how many touches are already sent until this point?
Boolean gTouchscreenUsesHybridMode = FALSE;


CFMutableArrayRef gContactIdentifiers;

/// Vendor "device certification status" feature report (vendor page 0xFF00, usage 0xC5).
/// Windows reads this during enumeration; reading it is what takes a Windows-spec panel
/// out of single-touch mouse emulation and into true multitouch digitizer reporting.
static const uint8_t kDeviceCertificationReportID = 0x44;
static const uint8_t kContactCountMaximumReportID = 0x0A;
static const int     kCertificationReadAttempts   = 5;

/// Contact Count Maximum as reported by the panel, 0 when unknown. Informational.
uint8_t gReportedContactCountMaximum = 0;

/// Retry state for deferred device setup (see Handle_SetupRetryTimer).
static const CFTimeInterval kSetupRetryInterval = 2.0;
static const int            kMaxSetupRetries    = 15;
static int                  gSetupRetryCount    = 0;
static Boolean              gSetupRetryScheduled = false;


#pragma mark General Debug Utilities




void PrintAddress(UInt8 *ptr, UInt64 length) {
    for (int i=0; i<length; i++) {
        printf("%02x ", ptr[i]);
        if ((i+1)%8 == 0) printf("  ");
        if ((i+1)%32 == 0) printf("\n");
    }
    printf("\n");
}


void PrintInput(IOHIDValueRef inHIDValue) {
    IOHIDElementRef elem = IOHIDValueGetElement(inHIDValue);
    CFIndex page = IOHIDElementGetUsagePage(elem);
    CFIndex usage = IOHIDElementGetUsage(elem);
    CFIndex value = IOHIDValueGetIntegerValue(inHIDValue);
    
    IOHIDElementCookie cookie = IOHIDElementGetCookie(elem);
    
    char pageDescr[6]  = "(---)";
    char usageDescr[10] = "(-------)";
    
    if (page == kHIDPage_GenericDesktop) {
        strcpy(pageDescr, "(GD) ");
        if (usage == kHIDUsage_GD_X) {
            strcpy(usageDescr, "(X)      ");
        } else if (usage == kHIDUsage_GD_Y) {
            strcpy(usageDescr, "(Y)      ");
        }
        
    } else if (page == kHIDPage_Digitizer) {
        strcpy(pageDescr, "(Dig)");
        
        if (usage == kHIDUsage_Dig_TipSwitch) {
            strcpy(usageDescr, "(Tip)    ");
        } else if (usage == kHIDUsage_Dig_ContactIdentifier) {
            strcpy(usageDescr, "(Cont ID)");
        } else if (usage == kHIDUsage_Dig_ContactCount) {
            strcpy(usageDescr, "(ContCnt)");
        } else if (usage == kHIDUsage_Dig_TouchValid) {
            strcpy(usageDescr, "(IsValid)");
        } else if (usage == kHIDUsage_Dig_RelativeScanTime) {
            strcpy(usageDescr, "(ScnTime)");
        } else if (usage == kHIDUsage_Dig_Width) {
            strcpy(usageDescr, "(Width)  ");
        } else if (usage == kHIDUsage_Dig_Height) {
            strcpy(usageDescr, "(Height) ");
        } else if (usage == kHIDUsage_Dig_Azimuth) {
            strcpy(usageDescr, "(Azimuth)");
        }
    }
    
    CFIndex  lMin = IOHIDElementGetLogicalMin(elem);
    CFIndex lMax = IOHIDElementGetLogicalMax(elem);
    
    printf("%u\t| %#02lx %s\t| %#02lx %s\t|%8ld\t(%ld-%ld)\n", cookie, page, pageDescr, usage, usageDescr, value, lMin, lMax);
}





#pragma mark - Storing Values


int64_t StorageKeyForElement(IOHIDElementRef element) {
    return IOHIDElementGetCookie(element);
}



CFIndex ValueOfElement(IOHIDElementRef element) {
    
    if (!element) {
        return kCFNotFound;
    }
    
    int64_t hash = StorageKeyForElement(element);
    CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &hash);
    
    if (CFDictionaryContainsKey(gStoredInputValues, key)) {
        CFIndex value;
        CFNumberRef num = CFDictionaryGetValue(gStoredInputValues, key);
        CFNumberGetValue(num, kCFNumberCFIndexType, &value);
        CFRelease(key);
        return value;
        
    }
    return kCFNotFound;

}



void StoreInputValue(IOHIDValueRef hidValue) {

    CFIndex value = IOHIDValueGetIntegerValue(hidValue);
    IOHIDElementRef elem = IOHIDValueGetElement(hidValue);

    CFIndex keyValue = StorageKeyForElement(elem);

    
    CFNumberRef key = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &keyValue);
    
    CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberCFIndexType, &value);
    
    CFDictionarySetValue(gStoredInputValues, key, num);
    
    CFRelease(num);
    CFRelease(key);
    
    
    // special case: contact count could be zero in hybrid mode --> s
    CFIndex page = IOHIDElementGetUsagePage(elem);
    CFIndex usage = IOHIDElementGetUsage(elem);
    
    if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_ContactCount) {
        // hybrid mode can only exist if the old value is larger than the number of collections that can be communicated at once
        CFIndex numCollections =  CFArrayGetCount(gTouchCollectionElements);
        
        if (gContactCount > numCollections && value == 0 && gHybridOffset > 0) {
            gTouchscreenUsesHybridMode = TRUE;
            
        } else {
            gContactCount = value;
            gHybridOffset = 0;
        }
    }
}




/**
 We need to inspect the HID tree as a whole once to see which elements are grouped into logical groups of touch data.
 Just pass in any element of the tree, the function will walk up the tree, search for the logical groups and rememeber them in the global variables.
 */
void IdentifyElements(IOHIDElementRef anyElement, Boolean printTree) {
    
    IOHIDElementRef applicationCollection = anyElement;
    IOHIDElementType type = kIOHIDElementTypeOutput;
    
    while (type != kIOHIDElementCollectionTypeApplication) {
        IOHIDElementRef next = IOHIDElementGetParent(applicationCollection);
        if (next) {
            applicationCollection = next;
            type = IOHIDElementGetType(applicationCollection);
        } else {
            break;
        }
    }
    
    gApplicationCollectionElement = applicationCollection;

    // Idempotent: this can be reached both from the matching-callback bootstrap and from
    // the manager's input-value callback. Without clearing, the same logical collections
    // get appended twice and every touch is dispatched twice.
    if (gTouchCollectionElements != NULL) {
        CFArrayRemoveAllValues(gTouchCollectionElements);
    }

    CFArrayRef children = IOHIDElementGetChildren(applicationCollection);
    CFIndex numChildren = CFArrayGetCount(children);
    
    if (printTree) {
        printf("# parent (type %u) has %ld children:\n", type, numChildren);
    }
    
    
    for (CFIndex i=0; i<numChildren; i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        
        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);
        IOHIDElementType type =  IOHIDElementGetType(element);
        IOHIDElementCollectionType collectionType = IOHIDElementGetCollectionType(element);
        
        if (type == kIOHIDElementTypeCollection && collectionType == kIOHIDElementCollectionTypeLogical) {
            CFArrayAppendValue(gTouchCollectionElements, element);
            
            if (printTree) {
                printf(" > Logical collection %ld\n", i);
                CFArrayRef grandchildren = IOHIDElementGetChildren(element);
                for( CFIndex j=0; j<CFArrayGetCount(grandchildren); j++) {
                    IOHIDElementRef gch = (IOHIDElementRef)CFArrayGetValueAtIndex(grandchildren, j);
                    CFIndex page = IOHIDElementGetUsagePage(gch);
                    CFIndex usage = IOHIDElementGetUsage(gch);
                    CFIndex cookie= IOHIDElementGetCookie(gch);
                    
                    printf("    > %#02lx %#02lx  [%ld]\n", page, usage, cookie);
                }
            }
            
        } // logical collection
        
        else if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_ContactCount) {
            if (printTree) {
                printf(" > Contact Count\n");
            }
        }
        
        else if (page == kHIDPage_Digitizer && usage == kHIDUsage_Dig_RelativeScanTime) {
            gScanTimeElement = element;
            if (printTree) {
                printf(" > Scan Time\n");
            }
        }
        
        else {
            if (printTree) {
                printf(" > %#02lx %#02lx\n", page, usage);
            }
        }
    }
}









#pragma mark - Propagate Touch Data to next layer


void PrintTouchCollection(IOHIDElementRef collection) {
    CFArrayRef children = IOHIDElementGetChildren(collection);
    
    // get stored values of all touches
    for (CFIndex i=0; i<CFArrayGetCount(children); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        
        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);
        CFIndex cookie = IOHIDElementGetCookie(element);
        CFIndex value = ValueOfElement(element);
        
        char pageDescr[6]  = "(---)";
        char usageDescr[10] = "(-------)";
        
        if (page == kHIDPage_GenericDesktop) {
            strcpy(pageDescr, "(GD) ");
            if (usage == kHIDUsage_GD_X) {
                strcpy(usageDescr, "(X)      ");
            } else if (usage == kHIDUsage_GD_Y) {
                strcpy(usageDescr, "(Y)      ");
            }
            
        } else if (page == kHIDPage_Digitizer) {
            strcpy(pageDescr, "(Dig)");
            
            if (usage == kHIDUsage_Dig_TipSwitch) {
                strcpy(usageDescr, "(Tip)    ");
            } else if (usage == kHIDUsage_Dig_ContactIdentifier) {
                strcpy(usageDescr, "(Cont ID)");
            } else if (usage == kHIDUsage_Dig_ContactCount) {
                strcpy(usageDescr, "(ContCnt)");
            } else if (usage == kHIDUsage_Dig_TouchValid) {
                strcpy(usageDescr, "(IsValid)");
            } else if (usage == kHIDUsage_Dig_RelativeScanTime) {
                strcpy(usageDescr, "(ScnTime)");
            } else if (usage == kHIDUsage_Dig_Width) {
                strcpy(usageDescr, "(Width)  ");
            } else if (usage == kHIDUsage_Dig_Height) {
                strcpy(usageDescr, "(Height) ");
            } else if (usage == kHIDUsage_Dig_Azimuth) {
                strcpy(usageDescr, "(Azimuth)");
            }
        }
        
        
        
        printf("[%u]\t%#02lx\t%#02lx %s\t %8ld\n", cookie, page, usage, usageDescr,  value);
    }
    printf("\n");
}


/**
 Dispatches touch data for the given collection, but only if all values needed were received
 */

void DispatchTouchDataForCollection(IOHIDElementRef collection) {

    CFArrayRef children = IOHIDElementGetChildren(collection);


    CGFloat x = -1;
    CGFloat y = -1;
    
    CFIndex contactID = 0;
    CFIndex tipSwitch = 0;
    CFIndex isValid = 0;
    
    CFIndex width   = kCFNotFound;
    CFIndex height  = kCFNotFound;
    CFIndex azimuth = kCFNotFound;
    
    // get stored values of all touches
    for (CFIndex i=0; i<CFArrayGetCount(children); i++) {
        IOHIDElementRef element = (IOHIDElementRef)CFArrayGetValueAtIndex(children, i);
        
        CFIndex page = IOHIDElementGetUsagePage(element);
        CFIndex usage = IOHIDElementGetUsage(element);
        CFIndex value = ValueOfElement(element);
        
        if (value != kCFNotFound) {
            if (page == kHIDPage_GenericDesktop) {
                if (usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y) {
                    CGFloat min = (CGFloat)IOHIDElementGetLogicalMin(element);
                    CGFloat max = (CGFloat)IOHIDElementGetLogicalMax(element);

                    // Some panels declare the coordinate with Report Count 2 (the 16-bit
                    // value is transmitted twice). macOS coalesces the pair into a single
                    // 32-bit element, so the value arrives as 0xVVVVVVVV with the real
                    // coordinate duplicated in both halves. Recover the low half.
                    if (value > (CFIndex)max) {
                        CFIndex low  = value & 0xFFFF;
                        CFIndex high = (value >> 16) & 0xFFFF;
                        if (low == high && low <= (CFIndex)max) {
                            value = low;
                        } else if (low <= (CFIndex)max) {
                            value = low;
                        }
                    }

                    CGFloat curr = (CGFloat)value;
                    CGFloat normalized = ( (curr - min) / (max - min) ) + min;

                    if (usage == kHIDUsage_GD_X) {
                        x = normalized;
                    } else {
                        y = normalized;
                    }
                }
            } //kHIDPage_GenericDesktop
            
            else if (page == kHIDPage_Digitizer) {
                if (usage == kHIDUsage_Dig_ContactIdentifier) {
                    contactID = value;
                } else if (usage == kHIDUsage_Dig_TipSwitch) {
                    tipSwitch = value;
                } else if (usage == kHIDUsage_Dig_TouchValid) {
                    isValid = value;
                } else if (usage == kHIDUsage_Dig_Width) {
                    width = value;
                } else if (usage == kHIDUsage_Dig_Height) {
                    height = value;
                } else if (usage == kHIDUsage_Dig_Azimuth) {
                    azimuth = value;
                }
            } // kHIDPage_Digitizer
        }
    }

    TouchInputManagerUpdateTouchPosition(gTouchManager, contactID, x, y, (int)tipSwitch, (int)isValid);
    
//    if (width != kCFNotFound && height != kCFNotFound && azimuth != kCFNotFound) {
//        TouchInputManagerUpdateTouchSize(gTouchManager, contactID, (CGFloat)width, (CGFloat)height, (CGFloat)azimuth);
//    }
    
}



void DispatchTouches(void) {

    CFIndex numCollections = CFArrayGetCount(gTouchCollectionElements);
    CFIndex remainingUpdates = gContactCount - gHybridOffset;
    
    CFIndex numUpdates = numCollections;
    if (remainingUpdates < numCollections) {
        numUpdates = remainingUpdates;
    }
    
//    if(gTouchscreenUsesHybridMode && gHybridOffset > 0) {
//        printf("Update NEXT %ld out of %ld touches beginning with %ld \n", numUpdates, gContactCount, gHybridOffset);
//        
//    } else {
//        printf("Update %ld out of %ld touches beginning with %ld \n", numUpdates, gContactCount, gHybridOffset);
//    }
    
    CFIndex numElementsToPost = CFArrayGetCount(gTouchCollectionElements);
    if (numUpdates < numElementsToPost)
        numElementsToPost = numUpdates;

    
    // update the touch data
    for (CFIndex i=0; i<numElementsToPost; i++) {
        IOHIDElementRef collection = (IOHIDElementRef)CFArrayGetValueAtIndex(gTouchCollectionElements, i);
        DispatchTouchDataForCollection(collection);
//        PrintTouchCollection(collection);
    }
    
    gHybridOffset = gHybridOffset + numUpdates;
    
    if (gHybridOffset == gContactCount) {
        gHybridOffset = 0;
    }

    if (gHybridOffset == 0) {
        TouchInputManagerDidProcessReport(gTouchManager);
    }
    
}






#pragma mark - Callbacks

/*!
    @param context void * pointer to your data, often a pointer to an object.
    @param result Completion result of desired operation.
    @param inSender Interface instance sending the completion routine.
*/

static void Handle_QueueValueAvailable(
            void * _Nullable        context,
            IOReturn                result,
            void * _Nullable        inSender
) {
    do {
        IOHIDValueRef valueRef = IOHIDQueueCopyNextValueWithTimeout((IOHIDQueueRef) inSender, 0.);
        if (!valueRef)  {
            // finished processing 1 report
            DispatchTouches();
            break;
        }
        // process the HID value reference
        StoreInputValue(valueRef);
        
        // Don't forget to release our HID value reference
        CFRelease(valueRef);
    } while (1) ;
}


static void Handle_InputValueCallback (
                void *          inContext,      // context from IOHIDManagerRegisterInputValueCallback
                IOReturn        inResult,       // completion result for the input value operation
                void *          inSender,       // the IOHIDManagerRef
                IOHIDValueRef   inIOHIDValueRef // the new element value
) {
    if(!gAreElementRefsSet) {
        IOHIDElementRef e = IOHIDValueGetElement(inIOHIDValueRef);
        IdentifyElements(e, TRUE);
        gAreElementRefsSet = 1;
    }
    
    IOHIDElementRef elem = IOHIDValueGetElement(inIOHIDValueRef);
    
    if (gQueue == NULL) {
        // If we haven't set up the device queue yet, there's nowhere to route values.
        // The matching callback should create/schedule/start gQueue; this guard avoids a crash
        // and lets the system retry when the queue becomes available.
        return;
    }

    Boolean added = IOHIDQueueContainsElement(gQueue, elem);
    if(!added) {
        IOHIDQueueAddElement(gQueue, elem);
        StoreInputValue(inIOHIDValueRef);
    }
    
}








static Boolean SetUpTouchDevice(IOHIDDeviceRef inIOHIDDeviceRef);

/// The matching callback fires once per device. When the app is launched by
/// LaunchServices (login item, Finder) it can start before the HID/TCC layer is ready, so
/// IOHIDDeviceOpen fails with kIOReturnNotPermitted and, without this retry, the
/// touchscreen stays dead until the app is relaunched by hand. Retry on the run loop.
static void Handle_SetupRetryTimer(CFRunLoopTimerRef timer, void *info) {
    IOHIDDeviceRef device = (IOHIDDeviceRef)info;

    if (gQueue != NULL || device == NULL) {
        CFRunLoopTimerInvalidate(timer);
        if (device) CFRelease(device);
        return;
    }

    if (SetUpTouchDevice(device)) {
        os_log(OS_LOG_DEFAULT, "TouchMyMac: touch device ready after %d retries", gSetupRetryCount);
        gSetupRetryScheduled = false;
        CFRunLoopTimerInvalidate(timer);
        CFRelease(device);
        return;
    }

    if (++gSetupRetryCount >= kMaxSetupRetries) {
        os_log_error(OS_LOG_DEFAULT,
                     "TouchMyMac: giving up after %d setup attempts; touch will not work. "
                     "Check Input Monitoring and Accessibility permissions.", gSetupRetryCount);
        CFRunLoopTimerInvalidate(timer);
        CFRelease(device);
    }
}

static void ScheduleSetupRetry(IOHIDDeviceRef device) {
    if (device == NULL) {
        return;
    }
    CFRetain(device);
    CFRunLoopTimerContext ctx = {0, (void *)device, NULL, NULL, NULL};
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                                   CFAbsoluteTimeGetCurrent() + kSetupRetryInterval,
                                                   kSetupRetryInterval, 0, 0,
                                                   Handle_SetupRetryTimer, &ctx);
    if (timer == NULL) {
        CFRelease(device);
        return;
    }
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
    CFRelease(timer);
    os_log(OS_LOG_DEFAULT, "TouchMyMac: touch device not ready, retrying every %.1fs",
           (double)kSetupRetryInterval);
}


// this will be called when the HID Manager matches a new (hot plugged) HID device
static void Handle_DeviceMatchingCallback(
            void *          inContext,       // context from IOHIDManagerRegisterDeviceMatchingCallback
            IOReturn        inResult,        // the result of the matching operation
            void *          inSender,        // the IOHIDManagerRef for the new device
            IOHIDDeviceRef  inIOHIDDeviceRef // the new HID device
) {
    gAreElementRefsSet = 0;

    // This interpreter currently supports a single active touchscreen queue.
    // If we already have one, ignore additional matching callbacks.
    if (gQueue != NULL) {
        return;
    }

    if (inIOHIDDeviceRef == NULL) {
        os_log_error(OS_LOG_DEFAULT, "TouchMyMac: matching callback fired with a NULL device");
        return;
    }

    if (!SetUpTouchDevice(inIOHIDDeviceRef)) {
        // The forced enumeration in OpenHIDManager and the real matching callback can both
        // land here for the same device; only ever run one retry timer.
        if (!gSetupRetryScheduled) {
            gSetupRetryScheduled = true;
            gSetupRetryCount = 0;
            ScheduleSetupRetry(inIOHIDDeviceRef);
        }
    }
}


/// Opens, mode-switches and queues the digitizer. Returns false if the device is not ready
/// yet, in which case the caller should retry rather than give up.
static Boolean SetUpTouchDevice(IOHIDDeviceRef inIOHIDDeviceRef) {

    // On macOS 26/27 the digitizer is TCC gated (RequiresTCCAuthorization = Yes in the
    // IOHIDDevice registry entry). The matching callback can fire before the device is
    // actually usable, and IOHIDQueueCreate then returns NULL. Open the device first so
    // we fail loudly on a missing Input Monitoring grant instead of crashing.
    // Seize the digitizer. Without this, macOS's own HID event system keeps the device
    // open (ioreg: DeviceOpenedByEventSystem = Yes) and synthesizes single-pointer mouse
    // events mapped to the main display, which fights us and makes multi-touch gestures
    // impossible. Seizing stops the system from generating events for this device so this
    // process is the sole consumer. Fall back to a shared open if seizing is refused.
    IOReturn deviceOpenResult = IOHIDDeviceOpen(inIOHIDDeviceRef, kIOHIDOptionsTypeSeizeDevice);
    if (deviceOpenResult != kIOReturnSuccess) {
        deviceOpenResult = IOHIDDeviceOpen(inIOHIDDeviceRef, kIOHIDOptionsTypeNone);
    }
    if (deviceOpenResult != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT,
               "TouchMyMac: IOHIDDeviceOpen failed (0x%x); device not ready, or Input Monitoring "
               "is not granted to this build (ad-hoc signatures invalidate the grant on rebuild)",
               deviceOpenResult);
        return false;
    }

    // Windows-spec HID touchscreens boot in single-touch absolute-mouse emulation and only
    // start emitting true multitouch digitizer reports once the host reads the vendor
    // "device certification status" feature report (report id 0x44, vendor page 0xFF00,
    // usage 0xC5, 256 bytes). Windows does this during enumeration; macOS never does, so the
    // panel stays a single absolute pointer forever. Reading it here flips the device into
    // multitouch mode. Report 0x0A (Contact Count Maximum) is read as well: some controllers
    // gate the switch on that instead.
    {
        // The first attempt usually returns kIOReturnTimeout while the controller is still
        // settling after enumeration, so retry before giving up.
        IOReturn certResult = kIOReturnError;
        for (int attempt = 0; attempt < kCertificationReadAttempts; attempt++) {
            uint8_t certBuf[256];
            CFIndex certLen = sizeof(certBuf);
            certResult = IOHIDDeviceGetReport(inIOHIDDeviceRef, kIOHIDReportTypeFeature,
                                              kDeviceCertificationReportID, certBuf, &certLen);
            if (certResult == kIOReturnSuccess) {
                break;
            }
            usleep(250000);
        }

        if (certResult != kIOReturnSuccess) {
            // Without this read a Windows-spec panel stays in single-touch mouse emulation
            // and never emits digitizer reports, so treat it as "not ready" and let the
            // caller retry rather than coming up in a permanently broken state.
            os_log(OS_LOG_DEFAULT,
                   "TouchMyMac: certification report unreadable (0x%x); panel would stay in "
                   "mouse emulation, will retry", certResult);
            IOHIDDeviceClose(inIOHIDDeviceRef, kIOHIDOptionsTypeNone);
            return false;
        }

        // Contact Count Maximum, purely informational.
        uint8_t maxBuf[16];
        CFIndex maxLen = sizeof(maxBuf);
        if (IOHIDDeviceGetReport(inIOHIDDeviceRef, kIOHIDReportTypeFeature,
                                 kContactCountMaximumReportID, maxBuf, &maxLen) == kIOReturnSuccess
            && maxLen >= 2) {
            gReportedContactCountMaximum = maxBuf[1];
        }
    }

    IOHIDQueueRef queue = IOHIDQueueCreate(kCFAllocatorDefault, inIOHIDDeviceRef, 1000, kNilOptions);

    // NB: the original check called CFGetTypeID(queue) unconditionally, which segfaults
    // when IOHIDQueueCreate returns NULL, and then fell through and used the queue anyway.
    if (queue == NULL || CFGetTypeID(queue) != IOHIDQueueGetTypeID()) {
        os_log(OS_LOG_DEFAULT, "TouchMyMac: IOHIDQueueCreate returned an invalid queue, will retry");
        if (queue != NULL) {
            CFRelease(queue);
        }
        IOHIDDeviceClose(inIOHIDDeviceRef, kIOHIDOptionsTypeNone);
        return false;
    }

    IOHIDQueueRegisterValueAvailableCallback(queue, Handle_QueueValueAvailable, NULL);
    IOHIDQueueScheduleWithRunLoop(queue, gRunLoopRef, kCFRunLoopCommonModes);

    // Bootstrap element identification here rather than waiting for the HID manager's
    // input-value callback. That callback is what normally calls IdentifyElements() and
    // populates the queue, but it does not fire for a seized device, which would leave
    // gTouchCollectionElements empty and make DispatchTouches() a no-op: reports arrive
    // but no touches are ever produced.
    if (!gAreElementRefsSet) {
        CFArrayRef allElements =
            IOHIDDeviceCopyMatchingElements(inIOHIDDeviceRef, NULL, kIOHIDOptionsTypeNone);
        if (allElements != NULL) {
            CFIndex elementCount = CFArrayGetCount(allElements);
            if (elementCount > 0) {
                IdentifyElements((IOHIDElementRef)CFArrayGetValueAtIndex(allElements, 0), FALSE);
                gAreElementRefsSet = 1;

                for (CFIndex i = 0; i < elementCount; i++) {
                    IOHIDElementRef e = (IOHIDElementRef)CFArrayGetValueAtIndex(allElements, i);
                    if (IOHIDElementGetType(e) != kIOHIDElementTypeCollection &&
                        !IOHIDQueueContainsElement(queue, e)) {
                        IOHIDQueueAddElement(queue, e);
                    }
                }
            }
            setvbuf(stderr, NULL, _IONBF, 0);
            CFRelease(allElements);
        } else {
            os_log_error(OS_LOG_DEFAULT,
                         "TouchMyMac: IOHIDDeviceCopyMatchingElements returned NULL; "
                         "touch elements could not be enumerated");
        }
    }

    IOHIDQueueStart(queue);
    gQueue = queue;

    TouchInputManagerDidConnectTouchscreen(gTouchManager);

    os_log(OS_LOG_DEFAULT,
           "TouchMyMac: touchscreen ready (%ld touch collections, contact max %u)",
           (long)CFArrayGetCount(gTouchCollectionElements), gReportedContactCountMaximum);

    return true;
}   // SetUpTouchDevice
 


// this will be called when a HID device is removed (unplugged)
static void Handle_RemovalCallback(
                void *         inContext,       // context from IOHIDManagerRegisterDeviceMatchingCallback
                IOReturn       inResult,        // the result of the removing operation
                void *         inSender,        // the IOHIDManagerRef for the device being removed
                IOHIDDeviceRef inIOHIDDeviceRef // the removed HID device
) {
    printf("%s(context: %p, result: %p, sender: %p, device: %p).\n",
        __PRETTY_FUNCTION__, inContext, (void *) inResult, inSender, (void*) inIOHIDDeviceRef);
    if (gQueue != NULL) {
        IOHIDQueueStop(gQueue);
        CFRelease(gQueue);
        gQueue = NULL;
    }
    
    if (gTouchCollectionElements != NULL) {
        CFArrayRemoveAllValues(gTouchCollectionElements);
    }
    if (gContactIdentifiers != NULL) {
        CFArrayRemoveAllValues(gContactIdentifiers);
    }
    if (gStoredInputValues != NULL) {
        CFDictionaryRemoveAllValues(gStoredInputValues);
    }
    
    TouchInputManagerDidDisconnectTouchscreen(gTouchManager);
}   // Handle_RemovalCallback



#pragma mark - Start / Stop


// function to create matching dictionary
static CFMutableDictionaryRef CreateDeviceMatchingDictionary(UInt32 inUsagePage, UInt32 inUsage) {
    // create a dictionary to add usage page/usages to
    CFMutableDictionaryRef result = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (result) {
        if (inUsagePage) {
            // Add key for device type to refine the matching dictionary.
            CFNumberRef pageCFNumberRef = CFNumberCreate(
                            kCFAllocatorDefault, kCFNumberIntType, &inUsagePage);
            if (pageCFNumberRef) {
                CFDictionarySetValue(result,
                        CFSTR(kIOHIDDeviceUsagePageKey), pageCFNumberRef);
                CFRelease(pageCFNumberRef);
 
                // note: the usage is only valid if the usage page is also defined
                if (inUsage) {
                    CFNumberRef usageCFNumberRef = CFNumberCreate(
                                    kCFAllocatorDefault, kCFNumberIntType, &inUsage);
                    if (usageCFNumberRef) {
                        CFDictionarySetValue(result,
                            CFSTR(kIOHIDDeviceUsageKey), usageCFNumberRef);
                        CFRelease(usageCFNumberRef);
                    } else {
                        fprintf(stderr, "%s: CFNumberCreate(usage) failed.", __PRETTY_FUNCTION__);
                    }
                }
            } else {
                fprintf(stderr, "%s: CFNumberCreate(usage page) failed.", __PRETTY_FUNCTION__);
            }
        }
    } else {
        fprintf(stderr, "%s: CFDictionaryCreateMutable failed.", __PRETTY_FUNCTION__);
    }
    return result;
}   // CreateDeviceMatchingDictionary
 




void OpenHIDManager(void *delegate) {
    gTouchManager = delegate;
    
    // If Open is called twice within one process, make sure we start clean.
    if (gHidManager != NULL) {
        CloseHIDManager();
    }
    
    gHidManager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);

    // Same NULL-deref shape as the queue check below: bail instead of calling
    // CFGetTypeID on a NULL manager.
    if (gHidManager == NULL || CFGetTypeID(gHidManager) != IOHIDManagerGetTypeID()) {
        fprintf(stderr, "%s: IOHIDManagerCreate failed; touch input unavailable.\n",
                __PRETTY_FUNCTION__);
        gHidManager = NULL;
        return;
    }
        
    
    gTouchCollectionElements = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
    gContactIdentifiers      = CFArrayCreateMutable(kCFAllocatorDefault, 0, NULL);
    gStoredInputValues       = CFDictionaryCreateMutable(kCFAllocatorDefault,0, NULL, NULL);
   
//    CFMutableDictionaryRef keyboard =
//    CreateDeviceMatchingDictionary(kHIDPage_Digitizer, kHIDUsage_Dig_Pen);
//    CFMutableDictionaryRef keypad =
//    CreateDeviceMatchingDictionary(kHIDPage_Digitizer, kHIDUsage_Dig_Touch);

    CFMutableDictionaryRef matchesList[] = {
        CreateDeviceMatchingDictionary(kHIDPage_Digitizer, kHIDUsage_Dig_TouchScreen),
    };
    

    
    CFArrayRef matches = CFArrayCreate(kCFAllocatorDefault,
            (const void **)matchesList, 1, NULL);
    IOHIDManagerSetDeviceMatchingMultiple(gHidManager, matches);
    CFRelease(matches);
    
    IOHIDManagerRegisterDeviceMatchingCallback(gHidManager, Handle_DeviceMatchingCallback, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(gHidManager, Handle_RemovalCallback, NULL);
    
//    IOHIDManagerRegisterInputReportWithTimeStampCallback(gHidManager, Handle_ReportCallback, NULL);
    IOHIDManagerRegisterInputValueCallback(gHidManager, Handle_InputValueCallback, NULL);
    
    
    gRunLoopRef = CFRunLoopGetMain();
    
    IOHIDManagerScheduleWithRunLoop(gHidManager, gRunLoopRef,
                                    kCFRunLoopCommonModes);

    // Seize at the manager level too, so matched devices are exclusive from the outset.
    IOReturn openRes = IOHIDManagerOpen(gHidManager, kIOHIDOptionsTypeSeizeDevice);
    if (openRes != kIOReturnSuccess) {
        fprintf(stderr, "%s: manager seize failed: 0x%x, retrying shared\n",
                __PRETTY_FUNCTION__, openRes);
        openRes = IOHIDManagerOpen(gHidManager, kIOHIDOptionsTypeNone);
    }
    if (openRes != kIOReturnSuccess) {
        fprintf(stderr, "%s: IOHIDManagerOpen failed: 0x%x\n", __PRETTY_FUNCTION__, openRes);
    }

    // Some systems don't reliably invoke the matching callback for already-attached devices
    // at app start. Force an enumeration pass and initialize the queue immediately.
    if (gQueue == NULL) {
        CFSetRef devices = IOHIDManagerCopyDevices(gHidManager);
        if (devices != NULL) {
            CFIndex count = CFSetGetCount(devices);
            if (count > 0) {
                IOHIDDeviceRef *values = (IOHIDDeviceRef *)calloc((size_t)count, sizeof(IOHIDDeviceRef));
                if (values != NULL) {
                    CFSetGetValues(devices, (const void **)values);
                    for (CFIndex i = 0; i < count; i++) {
                        if (gQueue != NULL) {
                            break;
                        }
                        Handle_DeviceMatchingCallback(NULL, kIOReturnSuccess, gHidManager, values[i]);
                    }
                    free(values);
                }
            }
            CFRelease(devices);
        }
    }
}



void CloseHIDManager(void) {
    if (gQueue != NULL) {
        IOHIDQueueUnscheduleFromRunLoop(gQueue, gRunLoopRef, kCFRunLoopCommonModes);
        IOHIDQueueStop(gQueue);
        CFRelease(gQueue);
        gQueue = NULL;
    }

    if (gHidManager != NULL) {
        IOHIDManagerUnscheduleFromRunLoop(gHidManager, gRunLoopRef, kCFRunLoopCommonModes);
        IOHIDManagerClose(gHidManager, kIOHIDOptionsTypeNone);
        CFRelease(gHidManager);
        gHidManager = NULL;
    }

    if (gTouchCollectionElements != NULL) {
        CFRelease(gTouchCollectionElements);
        gTouchCollectionElements = NULL;
    }
    if (gContactIdentifiers != NULL) {
        CFRelease(gContactIdentifiers);
        gContactIdentifiers = NULL;
    }
    if (gStoredInputValues != NULL) {
        CFRelease(gStoredInputValues);
        gStoredInputValues = NULL;
    }

    gAreElementRefsSet = 0;
    gContactCount = 1;
    gHybridOffset = 0;
    gTouchscreenUsesHybridMode = FALSE;
}
