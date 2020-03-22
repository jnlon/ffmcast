# ffmcast

`ffmcast` is a friendly interface to ffmpeg for streaming media files to an
icecast server. A command-line invocation of ffmpeg is built from prompts on
standard input, which transcodes-while-streaming the selected file to an
icecast server in OGG/Theora/Vorbis format.

`ffmcast` uses `ffprobe` along with user input to select appropriate ffmpeg
settings for icecast streaming. It takes care of codec-specific filter
configuration for subtitles, audio/video/subtitle stream selection, resolution
scaling, bitrates, codecs, and seeking options while tuning for icecast
compatibility.

## Example Usage

```
$ ffmcast.rb ./sample.mkv
Audio Bitrate [128K]: 
Video Bitrate [900K]: 1100K
Resolution Scale [480:-1]: 720:-1
Seek (00:00:00 - 00:34:33) [00:00:00]: 15:00

Video Stream Selection
---------------------------------------------
-1: default/none
 0: stream #0: video/h264
	TAG: BPS: 2480196
	TAG: DURATION: 00:34:33.071000000
	TAG: NUMBER_OF_FRAMES: 124260
	TAG: NUMBER_OF_BYTES: 642702883
Selection [0]: 0

Audio Stream Selection
---------------------------------------------
-1: default/none
 0: stream #1: audio/ac3
	TAG: BPS: 384000
	TAG: DURATION: 00:34:33.056000000
 1: stream #2: audio/aac
	TAG: BPS: 257178
	TAG: DURATION: 00:34:32.107000000
Selection [0]: 0

Subtitle Stream Selection
---------------------------------------------
-1: default/none
 0: stream #3: subtitle/subrip
	TAG: language: eng
	TAG: BPS: 35
	TAG: DURATION: 00:25:16.353000000
Selection [0]: 0

ffmpeg command
---------------------------------------------
ffmpeg -loglevel +warning -hide_banner -stats -probesize 50M -analyzeduration 100M -re -accurate_seek -seek_timestamp 1 -ss 00:15:00 -i ./sample.mkv -g 50 -bufsize 6000k -f ogg -content_type application/ogg -map 0:1 -codec:a libvorbis -b:a 128K -filter_complex scale=720:-1,setpts=PTS+900/TB,subtitles=./sample.mkv:si=0,setpts=PTS-STARTPTS -map 0:0 -codec:v libtheora -b:v 1100K icecast://hackme:hackme@localhost:8000/stream.ogg

stream URL
---------------------------------------------
http://localhost:8000/stream.ogg

Execute ffmpeg? [y]: y
frame=  211 fps= 55 q=-0.0 size=      99kB time=00:00:03.72 bitrate= 217.4kbits/s speed=0.973x
```

The stream can be stopped with "Ctrl-C" on your terminal or paused with "Ctrl-Z".

## Requirements

`ruby`, `ffmpeg`, and `ffprobe` must be available in your $PATH. The following
versions are confirmed working:

- ruby 2.7.0
- ffmpeg n4.2.2
- ffprobe n4.2.2

## Configuration

Default settings can be changed by editing script constants the near the top
of the file. Certain prompts can also be enabled or disabled.

By default icecast server settings are not prompted for so it *must be updated
by manually editing the file.* The default configuration (seen below) will only
work if you have an icecast server running on localhost in the stock
configuration.

AUDIO\_BITRATE, VIDEO\_BITRATE, and RESOLUTION\_SCALE settings should be
adjusted based on (1) the encoding speed of your computer and (2) the available
bandwidth to your icecast server. As a rule of thumb the higher these values,
the more CPU and bandwidth streaming will take.

```
module DefaultSettings
  ## Transcode Quality Settings
  AUDIO_BITRATE = '128K'
  VIDEO_BITRATE = '900K'
  RESOLUTION_SCALE = '480:-1' # scale to 480p, keep aspect ratio

  ## Icecast Server Settings
  ICECAST_AUTH = 'hackme:hackme'
  ICECAST_HOST = 'localhost:8000'
  ICECAST_MOUNT = 'stream.ogg'

  ## Prompt for audio/video bitrates on startup
  QUALITY_PROMPT = true
  ## Prompt for icecast settings on startup
  ICECAST_PROMPT = false
end
```
