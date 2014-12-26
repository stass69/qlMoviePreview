//
//  NYXMovie.m
//  qlMoviePreview
//
//  Created by @Nyx0uf on 24/12/14.
//  Copyright (c) 2014 Nyx0uf. All rights reserved.
//  www.cocoaintheshell.com
//


#import "NYXMovie.h"
#import <libavformat/avformat.h>
#import <libswscale/swscale.h>
#import <sys/stat.h>
#import <time.h>


@implementation NYXMovie
{
	NSString* _filepath;
	AVFormatContext* _fmt_ctx;
	AVCodecContext* _dec_ctx;
	AVStream* _stream;
	AVFrame* _frame;
	AVPicture _picture;
	int _stream_idx;
}

#pragma mark - Allocations / Deallocations
-(instancetype)initWithFilepath:(NSString*)filepath
{
	if ((self = [super init]))
	{
		if (nil == filepath)
			return nil;

		_filepath = [filepath copy];
		_fmt_ctx = NULL;
		_dec_ctx = NULL;
		_stream = NULL;
		_frame = NULL;
		_stream_idx = 0;

		if (avformat_open_input(&_fmt_ctx, [filepath UTF8String], NULL, NULL) != 0)
		{
			return nil;
		}

		if (avformat_find_stream_info(_fmt_ctx, NULL))
		{
			avformat_close_input(&_fmt_ctx);
			return nil;
		}

		// Find video stream
		AVCodec* codec = NULL;
		for (_stream_idx = 0; _stream_idx < (int)_fmt_ctx->nb_streams; _stream_idx++)
		{
			_stream = _fmt_ctx->streams[_stream_idx];
			_dec_ctx = _stream->codec;
			if ((_dec_ctx) && (_dec_ctx->codec_type == AVMEDIA_TYPE_VIDEO))
			{
				if (_dec_ctx->height > 0)
					codec = avcodec_find_decoder(_dec_ctx->codec_id);
				break;
			}
		}
		// Open codec
		if ((NULL == codec) || (avcodec_open2(_dec_ctx, codec, NULL) != 0))
		{
			avformat_close_input(&_fmt_ctx);
			return nil;
		}

		// Allocate frame
		if (NULL == (_frame = av_frame_alloc()))
		{
			avcodec_close(_dec_ctx);
			avformat_close_input(&_fmt_ctx);
			return nil;
		}
	}
	return self;
}

-(void)dealloc
{
	avpicture_free(&_picture);
	av_frame_free(&_frame);
	avcodec_close(_dec_ctx);
	avformat_close_input(&_fmt_ctx);
}

#pragma mark - Public
-(bool)createThumbnailAtPath:(NSString*)path ofSize:(NYXSize)size atPosition:(int64_t)position
{
	// Thumbnail only once
	NSFileManager* file_manager = [[NSFileManager alloc] init];
	if ([file_manager fileExistsAtPath:path])
		return true;

	// Set screenshot offset
	// If duration is unknown or less than 2 seconds, use the first frame
	if (_fmt_ctx->duration > (2 * AV_TIME_BASE))
	{
		int64_t timestamp = (_fmt_ctx->duration > (position * 2 * AV_TIME_BASE) ? av_rescale(position, _stream->time_base.den, _stream->time_base.num) : av_rescale(_fmt_ctx->duration, _stream->time_base.den, 2 * AV_TIME_BASE * _stream->time_base.num));
		if (_stream->start_time > 0)
			timestamp += _stream->start_time;
		if (av_seek_frame(_fmt_ctx, _stream_idx, timestamp, AVSEEK_FLAG_BACKWARD) < 0)
			av_seek_frame(_fmt_ctx, _stream_idx, 0, AVSEEK_FLAG_BYTE); // Fail, rewind
	}

	AVPacket packet;
	av_init_packet(&packet);
	packet.data = NULL;
	packet.size = 0;
	int got_frame = 0;
	while (av_read_frame(_fmt_ctx, &packet) >= 0)
	{
		if (packet.stream_index == _stream_idx)
			avcodec_decode_video2(_dec_ctx, _frame, &got_frame, &packet);
		av_free_packet(&packet);
		if (got_frame)
			break;
	}
	if (!got_frame) // No frame :<
	{
		return false;
	}

	// Allocate thumbnail
	avpicture_free(&_picture);
	if (avpicture_alloc(&_picture, AV_PIX_FMT_RGB24, (int)size.w, (int)size.h) != 0)
	{
		return false;
	}

	// Convert frame and scale if needed
	struct SwsContext* sws_ctx = sws_getContext(_dec_ctx->width, _dec_ctx->height, _dec_ctx->pix_fmt, (int)size.w, (int)size.h, AV_PIX_FMT_RGB24, SWS_SPLINE, NULL, NULL, NULL);
	if (NULL == sws_ctx)
	{
		return false;
	}
	sws_scale(sws_ctx, (const uint8_t* const*)_frame->data, _frame->linesize, 0, _dec_ctx->height, _picture.data, _picture.linesize);
	sws_freeContext(sws_ctx);

	// Create CGImageRef
	CGDataProviderRef data_provider = CGDataProviderCreateWithData(NULL, _picture.data[0], (size.w * size.h * 3), NULL);
	CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
	CGImageRef img_ref = CGImageCreate(size.w, size.h, 8, 24, size.w * 3, color_space, kCGBitmapByteOrderDefault, data_provider, NULL, false, kCGRenderingIntentDefault);
	CGColorSpaceRelease(color_space);
	CGDataProviderRelease(data_provider);

	if (NULL == img_ref)
	{
		return false;
	}

	// Save
	CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], kUTTypePNG, 1, NULL);
	if (NULL == dst)
	{
		CGImageRelease(img_ref);
		return false;
	}
	CGImageDestinationAddImage(dst, img_ref, NULL);
	const bool ret = CGImageDestinationFinalize(dst);
	CFRelease(dst);
	CGImageRelease(img_ref);

	return ret;
}

-(void)fillDictionary:(NSMutableDictionary*)attrs
{
	// Duration
	attrs[(__bridge NSString*)kMDItemDurationSeconds] = @((double)((double)_fmt_ctx->duration / AV_TIME_BASE));
	// Bit rate
	attrs[(__bridge NSString*)kMDItemTotalBitRate] = @(_fmt_ctx->bit_rate);
	
	AVDictionaryEntry* tag = NULL;
	while ((tag = av_dict_get(_fmt_ctx->metadata, "", tag, AV_DICT_IGNORE_SUFFIX)))
	{
		if (!strlen(tag->value)) // just to be sure
			continue;

		if (!strcasecmp(tag->key, "encoder"))
			attrs[(__bridge NSString*)kMDItemEncodingApplications] = @(tag->value);
		else if (!strcasecmp(tag->key, "title"))
			attrs[(__bridge NSString*)kMDItemTitle] = @(tag->value);
	}

	NSMutableArray* codecs = [[NSMutableArray alloc] init];
	for (int stream_idx = 0; stream_idx < (int)_fmt_ctx->nb_streams; stream_idx++)
	{
		AVStream* stream = _fmt_ctx->streams[stream_idx];
		AVCodecContext* dec_ctx = stream->codec;

		if (dec_ctx->codec_type == AVMEDIA_TYPE_AUDIO)
		{
			if (dec_ctx->bit_rate > 0 && !attrs[(__bridge NSString*)kMDItemAudioBitRate])
				attrs[(__bridge NSString*)kMDItemAudioBitRate] = @(dec_ctx->bit_rate);
			if (dec_ctx->channels > 0 && !attrs[(__bridge NSString*)kMDItemAudioChannelCount])
			{
				NSNumber* channels;
				switch (dec_ctx->channels)
				{
					case 3:
						channels = @2.1f;
						break;
					case 6:
						channels = @5.1f;
						break;
					case 7:
						channels = @6.1f;
						break;
					case 8:
						channels = @7.1f;
						break;
					default:
						channels = [NSNumber numberWithInt:dec_ctx->channels];
				}
				attrs[(__bridge NSString*)kMDItemAudioChannelCount] = channels;
			}
			if (dec_ctx->sample_rate > 0 && !attrs[(__bridge NSString*)kMDItemAudioSampleRate])
				attrs[(__bridge NSString*)kMDItemAudioSampleRate] = @(dec_ctx->sample_rate);
		}
		else if (dec_ctx->codec_type == AVMEDIA_TYPE_VIDEO)
		{
			if (dec_ctx->bit_rate > 0 && !attrs[(__bridge NSString*)kMDItemVideoBitRate])
				attrs[(__bridge NSString*)kMDItemVideoBitRate] = @(dec_ctx->bit_rate);
			if (dec_ctx->height > 0 && !attrs[(__bridge NSString*)kMDItemPixelHeight])
			{
				attrs[(__bridge NSString*)kMDItemPixelHeight] = @(dec_ctx->height);
				AVRational sar = av_guess_sample_aspect_ratio(_fmt_ctx, stream, NULL);
				if (sar.num && sar.den)
					attrs[(__bridge NSString*)kMDItemPixelWidth] = @(av_rescale(dec_ctx->width, sar.num, sar.den));
				else
					attrs[(__bridge NSString*)kMDItemPixelWidth] = @(dec_ctx->width);
			}
		}
		else if (dec_ctx->codec_type == AVMEDIA_TYPE_SUBTITLE)
		{
			if (stream->disposition & AV_DISPOSITION_FORCED)
				continue;
		}
		else
			continue;
		
		AVCodec* codec = avcodec_find_decoder(dec_ctx->codec_id);
		if (codec)
		{
			const char* cname;
			switch (codec->id)
			{
				case AV_CODEC_ID_H263:
					cname = "H.263";
					break;
				case AV_CODEC_ID_H263P:
					cname = "H.263+";
					break;
				case AV_CODEC_ID_H264:
					cname = "H.264";
					break;
				case AV_CODEC_ID_HEVC:
					cname = "H.265";
					break;
				case AV_CODEC_ID_MJPEG:
					cname = "Motion JPEG";
					break;
				case AV_CODEC_ID_VORBIS:
					cname = "Vorbis";
					break;
				case AV_CODEC_ID_AAC:
					cname = "AAC";
					break;
				case AV_CODEC_ID_AC3:
					cname = "AC-3";
					break;
				case AV_CODEC_ID_DTS:
					cname = "DTS";
					break;
				case AV_CODEC_ID_TRUEHD:
					cname = "TrueHD";
					break;
				case AV_CODEC_ID_FLAC:
					cname = "FLAC";
					break;
				case AV_CODEC_ID_MP2:
					cname = "MPEG Layer 2";
					break;
				case AV_CODEC_ID_MP3:
					cname = "MPEG Layer 3";
					break;
				case AV_CODEC_ID_ASS:
					cname = "Advanced SubStation Alpha";
					break;
				case AV_CODEC_ID_SSA:
					cname = "SubStation Alpha";
					break;
				case AV_CODEC_ID_HDMV_PGS_SUBTITLE:
					cname = "PGS";
					break;
				case AV_CODEC_ID_SRT:
					cname = "SubRip";
					break;
				default:
					cname = codec->long_name ? codec->long_name : codec->name;
				}
			
			if (cname)
			{
				const char* profile = av_get_profile_name(codec, dec_ctx->profile);
				NSString* s = profile ? [NSString stringWithFormat:@"%s [%s]", cname, profile] : [NSString stringWithUTF8String:cname];
				if (![codecs containsObject:s])
					[codecs addObject:s];
			}
		}
	}

	if ([codecs count])
		attrs[(__bridge NSString*)kMDItemCodecs] = codecs;
}

-(NSDictionary*)informations
{
	/* General file info */
	NSMutableDictionary* outDict = [[NSMutableDictionary alloc] init];
	NSMutableString* strGeneral = [[NSMutableString alloc] initWithString:@"<h2 class=\"stitle\">General</h2><ul>"];

	// Movie name
	AVDictionaryEntry* tag = av_dict_get(_fmt_ctx->metadata, "title", NULL, 0);
	NSString* moviename = @"Undefined";
	if (tag != NULL)
		moviename = @(tag->value);
	[strGeneral appendFormat:@"<li><span class=\"st\">Title:</span> <span class=\"sc\">%@</span></li>", moviename];

	// Duration
	time_t timestamp = (time_t)((double)_fmt_ctx->duration / AV_TIME_BASE);
	struct tm* ptm = localtime(&timestamp);
	[strGeneral appendFormat:@"<li><span class=\"st\">Duration:</span> <span class=\"sc\">%d:%d:%d</span></li>", ptm->tm_hour, ptm->tm_min, ptm->tm_sec];
	
	// Filesize
	struct stat st;
	stat([_filepath UTF8String], &st);
	NSString* fmt = nil;
	if (st.st_size > 1073741824) // More than 1Gb
		fmt = [[NSString alloc] initWithFormat:@"%.1fGb", (float)((float)st.st_size / 1073741824.0f)];
	else if ((st.st_size < 1073741824) && (st.st_size > 1048576)) // More than 1Mb
		fmt = [[NSString alloc] initWithFormat:@"%.1fMb", (float)((float)st.st_size / 1048576.0f)];
	else if ((st.st_size < 1048576) && (st.st_size > 1024)) // 1Kb - 1Mb
		fmt = [[NSString alloc] initWithFormat:@"%.2fKb", (float)((float)st.st_size / 1024.0f)];
	else // Less than 1Kb
		fmt = [[NSString alloc] initWithFormat:@"%lldb", st.st_size];
	[strGeneral appendFormat:@"<li><span class=\"st\">Size:</span> <span class=\"sc\">%@</span></li>", fmt];
	[strGeneral appendString:@"</ul>"];
	outDict[@"general"] = strGeneral;

	/* Video stream(s) */
	NSMutableString* strVideo = [[NSMutableString alloc] init];
	size_t nb_video_tracks = 0;
	for (int stream_idx = 0; stream_idx < (int)_fmt_ctx->nb_streams; stream_idx++)
	{
		AVStream* stream = _fmt_ctx->streams[stream_idx];
		AVCodecContext* dec_ctx = stream->codec;
		if (dec_ctx->codec_type == AVMEDIA_TYPE_VIDEO)
		{
			// Separator if multiple streams
			if (nb_video_tracks > 0)
				[strVideo appendString:@"<div class=\"sep\">----</div>"];

			// WIDTHxHEIGHT (aspect ratio)
			const int height = dec_ctx->height;
			int width = dec_ctx->width;
			AVRational sar = av_guess_sample_aspect_ratio(_fmt_ctx, stream, NULL);
			if ((sar.num) && (sar.den))
				width = (int)av_rescale(dec_ctx->width, sar.num, sar.den);
			AVRational dar = stream->display_aspect_ratio;
			[strVideo appendFormat:@"<li><span class=\"st\">Resolution:</span> <span class=\"sc\">%dx%d <em>(%d:%d)</em></span></li>", width, height, dar.num, dar.den];

			// Format, profile, bitrate, reframe
			AVCodec* codec = avcodec_find_decoder(dec_ctx->codec_id);
			if (codec != NULL)
			{
				[strVideo appendFormat:@"<li><span class=\"st\">Format/Codec:</span> <span class=\"sc\">%s", codec->long_name];
				const char* profile = av_get_profile_name(codec, dec_ctx->profile);
				if (profile != NULL)
					[strVideo appendFormat:@" / %s", profile];
				if (dec_ctx->bit_rate > 0)
					[strVideo appendFormat:@" / %d Bps", dec_ctx->bit_rate];
				if (dec_ctx->refs > 0)
					[strVideo appendFormat:@" / %d ReF", dec_ctx->refs];
				[strVideo appendString:@"</span></li>"];
			}

			// Framerate (mode)
			AVRational fps = dec_ctx->framerate;
			if ((fps.num) && (fps.den))
				[strVideo appendFormat:@"<li><span class=\"st\">Framerate:</span> <span class=\"sc\">%.3f</span></li>", (float)((float)fps.num / (float)fps.den)];
			else
				[strVideo appendString:@"<li><span class=\"st\">Framerate:</span> <span class=\"sc\">Undefined</span></li>"];

			// Bit depth
			// TODO: find bit depth, the following code is wrong
			//[strVideo appendFormat:@"<li><span class=\"st\">Bit depth:</span> <span class=\"sc\">%d</span></li>", dec_ctx->pix_fmt];

			// Title
			tag = av_dict_get(stream->metadata, "title", NULL, 0);
			if (tag != NULL)
				[strVideo appendFormat:@"<li><span class=\"st\">Title:</span> <span class=\"sc\">%s</span></li>", tag->value];

			nb_video_tracks++;
		}
	}
	[strVideo appendString:@"</ul>"];
	NSMutableString* header = [[NSMutableString alloc] initWithFormat:@"<h2 class=\"stitle\">Video%@</h2><ul>", (nb_video_tracks > 1) ? @"s" : @""];
	[strVideo insertString:header atIndex:0];
	outDict[@"video"] = strVideo;

	/* Audio stream(s) */
	NSMutableString* strAudio = [[NSMutableString alloc] init];
	size_t nb_audio_tracks = 0;
	for (int stream_idx = 0; stream_idx < (int)_fmt_ctx->nb_streams; stream_idx++)
	{
		AVStream* stream = _fmt_ctx->streams[stream_idx];
		AVCodecContext* dec_ctx = stream->codec;
		if (dec_ctx->codec_type == AVMEDIA_TYPE_AUDIO)
		{
			// Separator if multiple streams
			if (nb_audio_tracks > 0)
				[strAudio appendString:@"<div class=\"sep\">----</div>"];

			// Language
			tag = av_dict_get(stream->metadata, "language", NULL, 0);
			if (tag != NULL)
				[strAudio appendFormat:@"<li><span class=\"st\">Language:</span> <span class=\"sc\">%s %@</span></li>", tag->value, (stream->disposition & AV_DISPOSITION_DEFAULT) ? @"<em>(Default)</em>" : @""];
			else
				[strAudio appendString:@"<li><span class=\"st\">Language:</span> <span class=\"sc\"><em>Undefined</em></span></li>"];
		
			// Format, profile, bit depth, bitrate, sampling rate
			AVCodec* codec = avcodec_find_decoder(dec_ctx->codec_id);
			if (codec != NULL)
			{
				[strAudio appendFormat:@"<li><span class=\"st\">Format/Codec:</span> <span class=\"sc\">%s", codec->long_name];
				const char* profile = av_get_profile_name(codec, dec_ctx->profile);
				if (profile != NULL)
					[strAudio appendFormat:@" %s", profile];
				//if (bitdepth)
				//	[strAudio appendFormat:@" / %@", bitdepth];
				if (dec_ctx->bit_rate > 0)
					[strAudio appendFormat:@" / %d Bps", dec_ctx->bit_rate];
				if (dec_ctx->sample_rate > 0)
					[strAudio appendFormat:@" / %d Hz", dec_ctx->sample_rate];
				[strAudio appendString:@"</span></li>"];
			}

			// Channels
			NSString* tmp = nil;
			switch (dec_ctx->channels)
			{
				case 1:
					tmp = @"1.0 [Mono]";
					break;
				case 2:
					tmp = @"2.0 [Stereo]";
					break;
				case 3:
					tmp = @"2.1 [Surround]";
					break;
				case 6:
					tmp = @"5.1 [Surround]";
					break;
				case 7:
					tmp = @"6.1 [Surround]";
					break;
				case 8:
					tmp = @"7.1 [Surround]";
					break;
				default:
					tmp = @"???";
					break;
			}
			[strAudio appendFormat:@"<li><span class=\"st\">Channels:</span> <span class=\"sc\">%d <em>(%@)</em></span></li>", dec_ctx->channels, tmp];

			tag = av_dict_get(stream->metadata, "title", NULL, 0);
			if (tag != NULL)
				[strAudio appendFormat:@"<li><span class=\"st\">Title:</span> <span class=\"sc\">%s</span></li>", tag->value];

			nb_audio_tracks++;
		}
	}
	[strAudio appendString:@"</ul>"];
	header = [[NSMutableString alloc] initWithFormat:@"<h2 class=\"stitle\">Audio%@</h2><ul>", (nb_audio_tracks > 1) ? @"s" : @""];
	[strAudio insertString:header atIndex:0];
	outDict[@"audio"] = strAudio;

	/* Subs stream(s) */
	NSMutableString* strSubs = [[NSMutableString alloc] init];
	size_t nb_subs_tracks = 0;
	for (int stream_idx = 0; stream_idx < (int)_fmt_ctx->nb_streams; stream_idx++)
	{
		AVStream* stream = _fmt_ctx->streams[stream_idx];
		AVCodecContext* dec_ctx = stream->codec;
		if (dec_ctx->codec_type == AVMEDIA_TYPE_SUBTITLE)
		{
			// Separator if multiple streams
			if (nb_subs_tracks > 0)
				[strSubs appendString:@"<div class=\"sep\">----</div>"];

			// Language
			tag = av_dict_get(stream->metadata, "language", NULL, 0);
			if (tag != NULL)
				[strSubs appendFormat:@"<li><span class=\"st\">Language:</span> <span class=\"sc\">%s %@</span></li>", tag->value, (stream->disposition & AV_DISPOSITION_DEFAULT) ? @"<em>(Default)</em>" : @""];
			else
				[strSubs appendString:@"<li><span class=\"st\">Language:</span> <span class=\"sc\"><em>Undefined</em></span></li>"];
			// Format
			AVCodec* codec = avcodec_find_decoder(dec_ctx->codec_id);
			if (codec != NULL)
			{
				const char* cname;
				switch (codec->id)
				{
					case AV_CODEC_ID_ASS:
						cname = "Advanced SubStation Alpha (ASS)";
						break;
					case AV_CODEC_ID_SSA:
						cname = "SubStation Alpha (SSA)";
						break;
					case AV_CODEC_ID_HDMV_PGS_SUBTITLE:
						cname = "Presentation Graphic Stream (PGS)";
						break;
					case AV_CODEC_ID_SRT:
					case AV_CODEC_ID_SUBRIP:
						cname = "SubRip (SRT)";
						break;
					default:
						cname = codec->long_name ? codec->long_name : codec->name;
				}
				[strSubs appendFormat:@"<li><span class=\"st\">Format:</span> <span class=\"sc\">%s", cname];
			}
			// Title
			tag = av_dict_get(stream->metadata, "title", NULL, 0);
			if (tag != NULL)
				[strSubs appendFormat:@"<li><span class=\"st\">Title:</span> <span class=\"sc\">%s</span></li>", tag->value];
		
			nb_subs_tracks++;
		}
	}
	[strSubs appendString:@"</ul>"];
	header = [[NSMutableString alloc] initWithFormat:@"<h2 class=\"stitle\">Subtitle%@</h2><ul>", (nb_subs_tracks > 1) ? @"s" : @""];
	[strSubs insertString:header atIndex:0];
	outDict[@"subs"] = strSubs;

	return outDict;
}

@end