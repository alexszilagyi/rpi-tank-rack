require 'cgi'
require 'erb'
require 'socket'
require 'thin'
require 'rack/websocket'
require 'shellwords'

module RPiTankRack

class VideoStreamer
	class << self
		PIDFILE = 'mjpg_stream.pid'

		def start(options = {})
			stop
			command = "mjpg_streamer -i #{
				("/usr/lib/input_uvc.so " <<
					"-f #{(options[:framerate] || 20).to_s.shellescape} " <<
					"-r #{(options[:resolution] || '640x480').to_s.shellescape}"
				).shellescape} -o '/usr/lib/output_http.so -w /srv/http -p 8280'"
			puts "Running: #{command}"

			pid = Process.spawn command
			Process.detach(pid)
			File.write(PIDFILE, pid)
		end

		def stop
			pid = self.pid
			return if pid.nil?

			5.times do
				Process.kill(:QUIT, pid)
				sleep 1
			end

			Process.kill(:KILL, pid)
		rescue
			puts "Kill #{pid}: #$!"
		end

		def pid
			pid = File.read(PIDFILE).to_i rescue return
			Process.kill(0, pid)
			pid
		rescue
			File.unlink(PIDFILE)
			nil
		end

		alias_method :running?, :pid
	end
end

class WebApplication
	RESPONSE_INTERNAL_SERVER_ERROR = [500, { 'Content-Type' => 'text/plain' }, ['Internal Server Error']]
	RESPONSE_NOT_FOUND = [404, { 'Content-Type' => 'text/plain' }, ['Not Found']]

	attr_reader :params, :source_ip, :request_host_with_port, :request_host, :notice

	def call(env)
		return RESPONSE_NOT_FOUND unless env['PATH_INFO'] == '/'

		req = Rack::Request.new(env)
		if req.post?
			program = CGI::parse(req.body.read)['program'].first
			Thread.new do
				PowerState.new(true).instance_eval(program)
			end
			@notice = 'Program started'
		end

		@source_ip = env['HTTP_X_REAL_IP'] || env['REMOTE_ADDR']
		@params = CGI::parse(env['QUERY_STRING'].to_s)
		@request_host_with_port = env['HTTP_HOST']
		@request_host = @request_host_with_port.split(':', 2).first

		streaming_options = {}
		(res = @params['res']) && res.any? && (streaming_options[:resolution] = res.first)
		(fps = @params['fps']) && fps.any? && (streaming_options[:framerate] = fps.first)

		if streaming_options.any? || !VideoStreamer.running?
			if res.any? && res.first.eql?('stop')
				VideoStreamer.stop
			else
				VideoStreamer.start(streaming_options)
			end
		end

		[200, { 'Content-Type' => 'text/html' }, [ERB.new(File.read('index.html.erb')).result(binding)]]
	rescue
		warn "Exception when processing with #{params} from #{source_ip}"
		warn "Error #{$!.inspect} at:\n#{$!.backtrace.join $/}"
		RESPONSE_INTERNAL_SERVER_ERROR
	end
end

class GpiodClient
	@sync = Mutex.new

	def self.send(message)
		@sync.synchronize do
			reconnect unless @connection
			puts "GPIOD Client: writing: #{message.inspect}"
			2.times do
				begin
					@connection.puts message
					break
				rescue => e
					puts "GPIOD Client: reconnect due to an error: #{e}"
					reconnect
				end
			end
		end
	rescue
		puts "GPIOD Client: #$!"
	end

	def self.reconnect
		@connection.close if @connection
		@connection = TCPSocket.new 'localhost', 11700
	end
end

class PowerState
	module Directionable
		attr_reader :direction

		# Protect against double directioning
		def direction=(new_dir)
			if @submitter
				@direction = new_dir
				@submitter.submit
			else
				if @direction && @direction != new_dir
					# Lockout
					@direction = false
				elsif @direction != false
					@direction = new_dir
				end
			end

			new_dir
		end

		def reset
			@direction = nil
			@submitter.submit if @submitter
		end

		def to_pin
			@pins[@direction]
		end
	end

	class Track
		include Directionable

		def initialize(forward_pin, reverse_pin, submitter)
			@pins = {
				forward: forward_pin,
				reverse: reverse_pin,
			}
			@submitter = submitter
		end
	end

	attr_reader :track_left, :track_right

	class Tower
		include Directionable

		def initialize(left_pin, right_pin, submitter)
			@pins = {
				left: left_pin,
				right: right_pin,
			}
			@submitter = submitter
		end
	end

	attr_reader :tower

	# Tank hardware Version 2(current) definitions:
	#'left_forward'   => 26,
	#'left_backward'  => 24,
	#'right_forward'  => 23,
	#'right_backward' => 22,
	#'tower_left'     => 21,
	#'tower_right'    => 19,
	def initialize(autosubmit = false)
		@track_left = Track.new(26, 24, autosubmit && self)
		@track_right = Track.new(23, 22, autosubmit && self)
		@tower = Tower.new(21, 19, autosubmit && self)
		@autosubmit = autosubmit
	end

	def reset
		[@track_left, @track_right, @tower].each(&:reset)
	end

	def submit
		pins = [@track_left, @track_right, @tower].map(&:to_pin).compact.join(' ')
		puts "PowerState: [#{self.to_s}] transmitting as [#{pins}]"
		# Autosubmit suggests we are in a programming mode; do not bother developers with re-sending commands.
		# TODO(dotdoom): 2014-02-20: isolate this from Free Controls mode.
		GpiodClient.send 'set_fallback_timeout 15' if @autosubmit
		GpiodClient.send "set_output #{pins}"
	end

	def to_s
		[@track_left, @track_right, @tower].zip(%w(LEFT RIGHT TOWER)).map { |object, name|
			"#{name}: #{object.direction}" if object.direction
		}.compact.join(', ')
	end
end

class SocketControlApplication < Rack::WebSocket::Application
	CONTROLS = {
		'engine_left'        => -> ps { ps.track_right.direction = :forward },
		'engine_right'       => -> ps { ps.track_left.direction = :forward },
		'engine_forward'     => -> ps { ps.track_left.direction = ps.track_right.direction = :forward },
		'engine_reverse'     => -> ps { ps.track_left.direction = ps.track_right.direction = :reverse },
		'tower_left'         => -> ps { ps.tower.direction = :left },
		'tower_right'        => -> ps { ps.tower.direction = :right },
		'trackleft_forward'  => -> ps { ps.track_left.direction = :forward },
		'trackright_forward' => -> ps { ps.track_right.direction = :forward },
		'trackleft_reverse'  => -> ps { ps.track_left.direction = :reverse },
		'trackright_reverse' => -> ps { ps.track_right.direction = :reverse },
		'stop'               => -> ps {},
	}

	def on_open(env)
		puts 'WebSocket: Client connected'
	end

	def on_close(env)
		puts 'WebSocket: Client disconnected'
	end

	def on_message(env, msg)
		power_state.reset
		msg.split.each { |control| CONTROLS[control].call(power_state) } rescue false
		puts "WebSocket: message #{msg.inspect} => #{power_state.to_s.inspect}"
		power_state.submit
	rescue
		puts "WebSocket: #$!"
	end

	def on_error(env, error)
		puts "WebSocket: Error: #{error}"
	end

	def power_state
		@power_state ||= PowerState.new
	end
end

end # module
