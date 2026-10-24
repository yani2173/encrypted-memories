// Recorder environment only: put Foundation's item-replacement directories in the container.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdlib.h>

static NSURL *(*originalDirectory)(id, SEL, NSSearchPathDirectory, NSSearchPathDomainMask, NSURL *, BOOL, NSError **);
static unsigned long replacementSequence;
static NSURL *recordedDirectory(id manager, SEL selector, NSSearchPathDirectory directory,
    NSSearchPathDomainMask domain, NSURL *target, BOOL create, NSError **error) {
    const char *container = getenv("UPGRADE_RECORD_ROOT");
    if (container && directory == NSItemReplacementDirectory && target) {
        NSString *root = [NSString stringWithUTF8String:container];
        if ([target.path hasPrefix:[root stringByAppendingString:@"/"]]) {
            // Use the public environment boundary that NSData's atomic write requests.
            // Keep its unique-directory and same-volume requirements.
            @synchronized ([NSFileManager class]) {
                NSString *path = [root stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"Temporary/Replacement-%06lu", ++replacementSequence]];
                if (create && ![manager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:error])
                    return nil;
                return [NSURL fileURLWithPath:path isDirectory:YES];
            }
        }
    }
    return originalDirectory(manager, selector, directory, domain, target, create, error);
}
__attribute__((constructor)) static void isolateItemReplacement(void) {
    if (!getenv("UPGRADE_RECORD_ROOT")) return;
    Method method = class_getInstanceMethod([NSFileManager class],
        @selector(URLForDirectory:inDomain:appropriateForURL:create:error:));
    if (!method) abort();
    originalDirectory = (void *)method_setImplementation(method, (IMP)recordedDirectory);
}
