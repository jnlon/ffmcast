#!/usr/bin/env -S ruby --disable-all

require 'json'

USAGE = 'Usage: ffmcast.rb [mediafile]'

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

class IcecastSettings
  def initialize(auth, host, mount)
    @auth = auth
    @host = host
    @mount = mount
  end

  def icecast_url
    "icecast://#{@auth}@#{@host}/#{@mount}"
  end

  def http_url
    "http://#{@host}/#{@mount}"
  end
end

class Timestamp
  def initialize(seconds)
    @seconds = seconds
  end

  def to_timestamp
    h = @seconds / 3600
    m = @seconds % 3600 / 60
    s = @seconds % 60
    return format('%.2d:%.2d:%.2d', h, m, s)
  end

  def to_seconds
    @seconds
  end

  def self.from_timestamp(ts)
    toks = ts.split(':').reverse.map { |t| t.to_i }
    seconds = 0
    seconds += toks[0] if toks[0]
    seconds += toks[1]*60 if toks[1]
    seconds += toks[2]*60*60 if toks[2]
    Timestamp.new(seconds)
  end
end

class StreamData
  attr_reader :index, :codec_name, :codec_type, :duration
  # Where data is a hash of a single 'stream' block from ffprobe json output
  def initialize(data)
    @index = data['index']
    @codec_name = data['codec_name']
    @codec_type = data['codec_type']
    @tags = (data['tags']) ? data['tags'] : []
  end

  def to_s
    tags_string = @tags.map { |k, v| "\tTAG: #{k}: #{v}\n"}.join
    "stream ##{@index}: #{@codec_type}/#{@codec_name}
     #{tags_string}"
  end
end

class Settings
  def initialize(audio_bitrate, video_bitrate, resolution_scale, seek_time, icecast_settings, video_stream, audio_stream, subtitle_stream)
    @audio_bitrate = audio_bitrate # String
    @video_bitrate = video_bitrate # String
    @resolution_scale = resolution_scale # String
    @icecast_settings = icecast_settings # IcecastSettings object
    @seek_time = seek_time # Timestamp object
    @video_stream = video_stream # StreamData object
    @audio_stream = audio_stream # StreamData object
    @subtitle_stream = subtitle_stream # StreamData object, possibly nil
  end

  def to_ffmpeg_cli(mediainfo)
    # select the audio and video stream indexes
    audio_stream_index = '0:' + @audio_stream.index.to_s
    video_stream_index = '0:' + @video_stream.index.to_s

    # filter settings, may be extended based on subtitle format
    filter_settings = ["scale=#{@resolution_scale}"]

    # compute appropriate filter options for "burning" subtitles into the video.
    # different ffmpeg filters are needed depending whether the source video subtitles
    # are embedded text (subrip, ass) or bitmap/images (dvd_subtitle, hdmv_pgs_subtitle)
    if @subtitle_stream != nil
      # filter_idx is the index used by ffmpeg in filters. it is relative to all the streams *of a
      # specific type* (subtitles, video, or audio). it is different from the stream index as seen with ffprobe
      filter_idx = mediainfo.subtitle_streams.index {|i| i.index == @subtitle_stream.index}
      # picture-based subs list retrieved from https://wiki.videolan.org/Subtitles/ and 'ffmpeg -codecs | grep '^ ..S''
      if @subtitle_stream.codec_name.downcase.match(/(dvd_subtitle|dvb_subtitle|dvb_teletext|hdmv_pgs_subtitle)/) then
        video_stream_index = '[v]'
        filter_settings = ["[0:v][0:s:#{filter_idx}]overlay"] + filter_settings
        filter_settings[-1] += video_stream_index # append stream filter index to end of last filter settings option
      else
        # see ffmpeg-filters manual, filter arguments need to be escaped
        filename_escaped = mediainfo.filename.gsub(/([‘\[\]=;,’`])/) { |m| '\\' + m }
        filename_escaped = filename_escaped.gsub(/([:])/) { |m| '\\\\' + m }
        filename_escaped = filename_escaped.gsub(/(['])/) { |m| '\\\\\\' + m }
        # use 'setpts' filter hack to align subtitles with audio/video after a seek
        # see: https://trac.ffmpeg.org/ticket/2067#comment:15
        filter_settings << "setpts=PTS+#{@seek_time.to_seconds}/TB"
        filter_settings << "subtitles=#{filename_escaped}:si=#{filter_idx}"
        filter_settings << 'setpts=PTS-STARTPTS'
      end
    end

    # substitute command options
    ['ffmpeg',
        '-loglevel', '+warning', '-hide_banner', '-stats',
        '-probesize', '50M', '-analyzeduration', '100M',
        '-re', '-accurate_seek', '-seek_timestamp', '1', '-ss', @seek_time.to_timestamp,
        '-i', mediainfo.filename, '-g', '50', '-bufsize', '6000k', '-f', 'ogg', '-content_type', 'application/ogg',
        '-map', audio_stream_index, '-codec:a', 'libvorbis', '-b:a', @audio_bitrate, # audio mapping
        '-filter_complex', filter_settings.join(','), '-map', video_stream_index, # (possibly) subtitle mapping and filter
        '-codec:v', 'libtheora', '-b:v', @video_bitrate, # video encode settings
        @icecast_settings.icecast_url]
  end
end

# Using 'ffprobe' to aquire media info
class MediaInfo
  attr_reader :filename, :duration, :audio_streams, :subtitle_streams, :video_streams

  def initialize(mediafile)
    @filename = mediafile
    # run ffprobe on filename and parse the JSON output
    command = ['ffprobe', '-hide_banner', '-loglevel', '0', '-of', 'json', '-show_streams', '-show_format', @filename]
    ffprobe_json = JSON.parse(IO.popen(command).read)

    # Sort streams by type: audio, video, or subtitle
    stream_data = ffprobe_json['streams'].map { |s| StreamData.new(s) }
    @audio_streams = stream_data.select { |a| a.codec_type == 'audio' }
    @video_streams = stream_data.select { |a| a.codec_type == 'video' }
    @subtitle_streams = stream_data.select { |a| a.codec_type == 'subtitle' }

    # Duration of the media file, stored as a timestamp
    @duration = Timestamp.new(ffprobe_json['format']['duration'].to_i)
  end
end

# Helper for prompting and retrieving a value from stdin
def prompt(description, default_value, validate_regex)
  while true do
    print("#{description} [#{default_value}]: ")
    result = $stdin.gets.to_s.chomp
    if result.empty?
      return default_value
    elsif result.match(validate_regex)
      return result
    else
      puts "WARNING: Invalid input, please try again"
    end
  end
end

# Helper for prompting input based on a menu of stream options
def prompt_stream_selection(description, stream_objects, default)
  puts '', description
  puts '---------------------------------------------'
  # render menu
  puts "-1: default/none\n"
  stream_objects.each_index do |i|
    puts " #{i}: #{stream_objects[i]}"
  end
  # show prompt
  return prompt('Selection', default, /^([0-9]+|-1)$/)
end

# Helper for retrieving a stream index from stdin, and falling back to a
# default value if none were selected
#
# description: the name of the menu in stream selection
# streams: list of streams to display and select from
# default_prompt_choice: the default selection of the prompt, eg [0]
# default_value: value to return in case the selection was '-1'
def get_stream_selection(description, streams, default_prompt_choice, default_value)
  if streams.count >= 1
    idx = prompt_stream_selection(description, streams, default_prompt_choice).to_i
    return (idx == -1) ? default_value : streams[idx]
  end
  return default_value
end

# Main entrypoint
def main
  if ARGV[0].nil?
    puts USAGE
    return 1
  end

  mediafile = ARGV[0]

  if !(File.exist? mediafile)
    puts "File #{mediafile} does not exist"
    return 1
  end

  mediainfo = MediaInfo.new(mediafile)

  audio_bitrate = DefaultSettings::AUDIO_BITRATE
  video_bitrate = DefaultSettings::VIDEO_BITRATE
  resolution_scale = DefaultSettings::RESOLUTION_SCALE
  icecast_auth = DefaultSettings::ICECAST_AUTH
  icecast_host = DefaultSettings::ICECAST_HOST
  icecast_mount = DefaultSettings::ICECAST_MOUNT

  if DefaultSettings::ICECAST_PROMPT
    icecast_auth = prompt('Icecast Auth', DefaultSettings::ICECAST_AUTH, /^.*?:.*?$/)
    icecast_host = prompt('Icecast Host', DefaultSettings::ICECAST_HOST, /^.*$/)
    icecast_mount = prompt('Icecast Mount', DefaultSettings::ICECAST_MOUNT, /^.*$/)
  end

  if DefaultSettings::QUALITY_PROMPT
    audio_bitrate = prompt('Audio Bitrate', DefaultSettings::AUDIO_BITRATE, /^[0-9]+[KMG](ib)?$/)
    video_bitrate = prompt('Video Bitrate', DefaultSettings::VIDEO_BITRATE, /^[0-9]+[KMG](ib)?$/)
    resolution_scale = prompt('Resolution Scale', DefaultSettings::RESOLUTION_SCALE, /^[-]?\d+:[-]?\d+$/)
  end

  seek_time = prompt("Seek (00:00:00 - #{mediainfo.duration.to_timestamp})", '00:00:00', /^(\d+?:)?(\d?\d:)?\d?\d$/)
  seek_time = Timestamp.from_timestamp(seek_time)

  # select first video stream when '-1' is chosen
  selected_video_stream = get_stream_selection(
    'Video Stream Selection', mediainfo.video_streams, '0', mediainfo.video_streams[0])

  # select first audio stream when '-1' is chosen
  selected_audio_stream = get_stream_selection(
    'Audio Stream Selection', mediainfo.audio_streams, '0', mediainfo.audio_streams[0])

  # no subtitle stream selected when '-1' is chosen
  selected_subtitle_stream = get_stream_selection(
    'Subtitle Stream Selection', mediainfo.subtitle_streams, '0', nil)

  # create the settings objects
  icecast_settings = IcecastSettings.new(icecast_auth, icecast_host, icecast_mount)
  settings = Settings.new(
    audio_bitrate, video_bitrate, resolution_scale, seek_time,
    icecast_settings,
    selected_video_stream, selected_audio_stream, selected_subtitle_stream
  )

  # build the command array
  ffmpeg_command = settings.to_ffmpeg_cli(mediainfo)

  # output summery before confirm execute
  puts '', 'ffmpeg command'
  puts '---------------------------------------------'
  puts ffmpeg_command.join(' '), ''
  puts 'stream URL'
  puts '---------------------------------------------'
  puts icecast_settings.http_url, ''

  confirm = prompt('Execute ffmpeg?', 'y', /.*/)
  if confirm[0].downcase == 'y'
    begin
      Process.wait((IO.popen ffmpeg_command).pid)
      puts "***** STREAM FINISHED *****"
    rescue Interrupt
      puts "***** STREAM CANCELLED *****"
      return 1
    end
  end

  return 0
end

exit(main)
