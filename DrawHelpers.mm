// SPDX-License-Identifier: MIT
#include "Newt/DrawHelpers.h"

NSColor* RGB(float r, float g, float b, float a) {
    return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:a];
}

void FillRounded(NSRect rect, CGFloat radius, NSColor* color) {
    [color setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius] fill];
}

void DrawText(NSString* text, NSRect rect, CGFloat size, BOOL bold,
              NSColor* color, NSTextAlignment align) {
    NSMutableParagraphStyle* style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = align;
    style.lineBreakMode = NSLineBreakByWordWrapping;
    NSFont* font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    NSDictionary* attrs = @{
        NSFontAttributeName : font,
        NSForegroundColorAttributeName : color,
        NSParagraphStyleAttributeName : style
    };
    [text drawInRect:rect withAttributes:attrs];
}

PixelImage MakeImage(void (^draw)(NSRect), uint32_t width, uint32_t height) {
    PixelImage img;
    img.width = width; img.height = height;
    img.pixels.assign(static_cast<size_t>(img.width) * img.height * 4, 0);
    @autoreleasepool {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(
            img.pixels.data(), img.width, img.height, 8, img.width * 4, cs,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGContextTranslateCTM(ctx, 0.0, img.height);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        NSGraphicsContext* gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:gc];
        draw(NSMakeRect(0, 0, img.width, img.height));
        [NSGraphicsContext restoreGraphicsState];
        CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
    }
    return img;
}
