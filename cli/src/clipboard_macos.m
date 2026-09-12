#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <string.h>

int vivi_clipboard_read_png(unsigned char **bytes, size_t *length, size_t limit) {
    *bytes = NULL;
    *length = 0;
    @autoreleasepool {
        @try {
            NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
            if (pasteboard == nil) return -1;
            NSMutableArray<NSString *> *types = [NSMutableArray arrayWithObject:NSPasteboardTypePNG];
            [types addObjectsFromArray:[NSBitmapImageRep imageTypes]];
            NSString *type = [pasteboard availableTypeFromArray:types];
            if (type == nil) return 0;
            NSData *data = [pasteboard dataForType:type];
            if (data == nil) return -1;
            if ([data length] > limit) return -3;
            if (![type isEqualToString:NSPasteboardTypePNG]) {
                NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:data];
                if (bitmap == nil) return -2;
                data = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                if (data == nil) return -2;
            }
            if ([data length] > limit) return -3;
            if ([data length] == 0) return -2;
            *bytes = malloc([data length]);
            if (*bytes == NULL) return -4;
            *length = [data length];
            memcpy(*bytes, [data bytes], *length);
            return 1;
        } @catch (NSException *exception) {
            (void)exception;
            return -1;
        }
    }
}
