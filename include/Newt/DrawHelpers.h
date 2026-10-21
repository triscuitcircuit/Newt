#ifndef NEWT_DRAWHELPERS_H
#define NEWT_DRAWHELPERS_H
// SPDX-License-Identifier: MIT

#include "Newt/PixelImage.h"
#import <AppKit/AppKit.h>
NSColor* RGB(float r, float g, float b, float a = 1.0f);
void FillRounded(NSRect rect, CGFloat radius, NSColor* color);
void DrawText(NSString* text, NSRect rect, CGFloat size, BOOL bold,
              NSColor* color, NSTextAlignment align = NSTextAlignmentLeft);
PixelImage MakeImage(void (^draw)(NSRect), uint32_t width = kTextureWidth, uint32_t height = kTextureHeight);

#endif
