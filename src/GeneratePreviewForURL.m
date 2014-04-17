#import <QuickLook/QuickLook.h>
#import "Tools.h"


OSStatus GeneratePreviewForURL(void* thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options);
void CancelPreviewGeneration(void* thisInterface, QLPreviewRequestRef preview);


OSStatus GeneratePreviewForURL(void* thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options)
{
	@autoreleasepool
	{
		// Verify if we support this type of file
		NSString* filepath = [(__bridge NSURL*)url path];
		if (![Tools isValidFilepath:filepath])
		{
			QLPreviewRequestSetURLRepresentation(preview, url, contentTypeUTI, NULL);
			return kQLReturnNoError;
		}

		// Check if cancel since thumb generation can take a long time
		if (QLPreviewRequestIsCancelled(preview))
			return kQLReturnNoError;

		// Create thumbnail
		NSString* thumbnailPath = [Tools createThumbnailForFilepath:filepath];
		if (!thumbnailPath)
		{
			QLPreviewRequestSetURLRepresentation(preview, url, contentTypeUTI, NULL);
			return kQLReturnNoError;
		}

		// Get the movie properties
		NSDictionary* mediainfo = [Tools mediainfoForFilepath:filepath];
		if (!mediainfo)
		{
			QLPreviewRequestSetURLRepresentation(preview, url, contentTypeUTI, NULL);
			return kQLReturnNoError;
		}

		// Load CSS && thumbnail
		CFBundleRef bundle = QLPreviewRequestGetGeneratorBundle(preview);
		NSURL* cssFile = (__bridge_transfer NSURL*)CFBundleCopyResourceURL(bundle, CFSTR("style"), CFSTR("css"), NULL);
		NSData* cssData = [[NSData alloc] initWithContentsOfURL:cssFile];
		NSData* thumbnailData = [[NSData alloc] initWithContentsOfFile:thumbnailPath];
		// Create properties with all metadata and attachments
		NSDictionary* properties = @{ // properties for the HTML data
									 (__bridge NSString*)kQLPreviewPropertyTextEncodingNameKey : @"UTF-8",
									 (__bridge NSString*)kQLPreviewPropertyMIMETypeKey : @"text/html",
									 // CSS and thumbnail
									 (__bridge NSString*)kQLPreviewPropertyAttachmentsKey : @{
											 @"css" : @{
													 (__bridge NSString*)kQLPreviewPropertyMIMETypeKey : @"text/css",
													 (__bridge NSString*)kQLPreviewPropertyAttachmentDataKey: cssData,
													 },
											 @"thb" : @{
													 (__bridge NSString*)kQLPreviewPropertyMIMETypeKey : @"image/png",
													 (__bridge NSString*)kQLPreviewPropertyAttachmentDataKey: thumbnailData,
													 },
											 },
									 };
		// Create HTML
		NSString* general = mediainfo[@"general"];
		NSString* video = mediainfo[@"video"];
		NSString* audio = mediainfo[@"audio"];
		NSString* subs = mediainfo[@"subs"];
		NSMutableString* html = [[NSMutableString alloc] initWithFormat:@"<!DOCTYPE html><html><head><link rel=\"stylesheet\" type=\"text/css\" href=\"cid:css\"></head>"];
		[html appendFormat:@"<body><div id=\"c\"><div id=\"i\"><img src=\"cid:thb\"></div>"];
		[html appendFormat:@"<div id=\"t\">%@%@%@%@</div></div></body></html>", general ? general : @"", video ? video : @"", audio	? audio : @"", subs ? subs : @""];

		// Give the HTMl to QuickLook
		QLPreviewRequestSetDataRepresentation(preview, (__bridge CFDataRef)[html dataUsingEncoding:NSUTF8StringEncoding], kUTTypeHTML, (__bridge CFDictionaryRef)properties);

		// Delete thumbnail
		//[[NSFileManager defaultManager] removeItemAtPath:thumbnailPath error:nil];
		
		return kQLReturnNoError;
	}
}

void CancelPreviewGeneration(void* thisInterface, QLPreviewRequestRef preview)
{
}