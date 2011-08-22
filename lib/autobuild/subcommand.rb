require 'set'
require 'autobuild/exceptions'
require 'autobuild/reporting'
require 'fcntl'

module Autobuild
    @logfiles = Set.new
    def self.clear_logfiles
        @logfiles.clear
    end

    def self.logfiles
        @logfiles
    end

    def self.register_logfile(path)
        @logfiles << path
    end

    def self.registered_logfile?(logfile)
        @logfiles.include?(logfile)
    end

    def self.statistics
        @statistics
    end
    def self.reset_statistics
        @statistics = Hash.new
    end
    def self.add_stat(package, phase, duration)
        if !@statistics[package]
            @statistics[package] = { phase => duration }
        elsif !@statistics[package][phase]
            @statistics[package][phase] = duration
        else
            @statistics[package][phase] += duration
        end
    end
    reset_statistics

    @parallel_build_level = nil
    class << self
        # Sets the level of parallelism during the build
        #
        # See #parallel_build_level for detailed information
        attr_writer :parallel_build_level

        # Returns the number of processes that can run in parallel during the
        # build. This is a system-wide value that can be overriden in a
        # per-package fashion by using Package#parallel_build_level.
        #
        # If not set, defaults to the number of CPUs on the system
        #
        # See also #parallel_build_level=
        def parallel_build_level
            if @parallel_build_level.nil?
                # No user-set value, return the count of processors on this
                # machine
                autodetect_processor_count
            elsif !@parallel_build_level || @parallel_build_level <= 0
                1
            else
                @parallel_build_level
            end
        end
    end

    # Returns the number of CPUs present on this system
    def self.autodetect_processor_count
        if @processor_count
            return @processor_count
        end

        if File.file?('/proc/cpuinfo')
            cpuinfo = File.readlines('/proc/cpuinfo')
            physical_ids, core_count, processor_ids = [], [], []
            cpuinfo.each do |line|
                case line
                when /^processor\s+:\s+(\d+)$/
                    processor_ids << Integer($1)
                when /^physical id\s+:\s+(\d+)$/
                    physical_ids << Integer($1)
                when /^cpu cores\s+:\s+(\d+)$/
                    core_count << Integer($1)
                end
            end
            
            # Try to count the number of physical cores, not the number of
            # logical ones. If the info is not available, fallback to the
            # logical count
            if (physical_ids.size == core_count.size) && (physical_ids.size == processor_ids.size)
                info = Array.new
                while (id = physical_ids.shift)
                    info[id] = core_count.shift
                end
                @processor_count = info.inject(&:+)
            else
                @processor_count = processor_ids.size
            end
        end

        # The format of the cpuinfo file is ... let's say not very standardized.
        # If the cpuinfo detection fails, inform the user and set it to 1
        if !@processor_count
            # Hug... What kind of system is it ?
            STDERR.puts "INFO: cannot autodetect the number of CPUs on this sytem"
            @processor_count = 1
        end

        @processor_count
    end
end


module Autobuild::Subprocess
    class Failed < Exception
        attr_reader :status
        def initialize(status = nil)
            @status = status
        end
    end

    CONTROL_COMMAND_NOT_FOUND = 1
    CONTROL_UNEXPECTED = 2
    def self.run(target, phase, *command)
        STDOUT.sync = true

        input_streams = []
        if command.last.kind_of?(Hash)
            options = command.pop
            if options[:input]
                input_streams = [options[:input]]
            end
        end

        start_time = Time.now

        # Filter nil and empty? in command
        command.reject!  { |o| o.nil? || (o.respond_to?(:empty?) && o.empty?) }
        command.collect! { |o| o.to_s }

        target_name = if target.respond_to?(:name)
                          target.name
                      else target.to_str
                      end
        logdir = if target.respond_to?(:logdir)
                     target.logdir
                 else Autobuild.logdir
                 end

        logname = File.join(logdir, "#{target_name}-#{phase}.log")
        if !File.directory?(File.dirname(logname))
            FileUtils.mkdir_p File.dirname(logname)
        end

	if Autobuild.verbose
	    puts "#{target_name}: running #{command.join(" ")}\n    (output goes to #{logname})"
	end

        open_flag = if Autobuild.keep_oldlogs then 'a'
                    elsif Autobuild.registered_logfile?(logname) then 'a'
                    else 'w'
                    end

        Autobuild.register_logfile(logname)

        status = File.open(logname, open_flag) do |logfile|
            if Autobuild.keep_oldlogs
                logfile.puts
            end
            logfile.puts "#{Time.now}: running"
            logfile.puts "    #{command.join(" ")}"
	    logfile.puts "with environment:"
            ENV.keys.sort.each do |key|
                logfile.puts "  '#{key}'='#{ENV[key]}'"
            end
	    logfile.flush
            logfile.sync = true

            if !input_streams.empty?
                pread, pwrite = IO.pipe # to feed subprocess stdin 
            end
            if block_given? # the caller wants the stdout/stderr stream of the process, git it to him
                outread, outwrite = IO.pipe
                outread.sync = true
                outwrite.sync = true
            end
            cread, cwrite = IO.pipe # to control that exec goes well

            cwrite.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)

            pid = fork do
                begin
                    cwrite.sync = true
                    if Autobuild.nice
                        Process.setpriority(Process::PRIO_PROCESS, 0, Autobuild.nice)
                    end

                    if outwrite
                        outread.close
                        $stderr.reopen(outwrite.dup)
                        $stdout.reopen(outwrite.dup)
                    else
                        $stderr.reopen(logfile.dup)
                        $stdout.reopen(logfile.dup)
                    end

                    if !input_streams.empty?
                        pwrite.close
                        $stdin.reopen(pread)
                    end
                   
                    exec(*command)
                rescue Errno::ENOENT
                    cwrite.write([CONTROL_COMMAND_NOT_FOUND].pack('I'))
                    raise
                rescue ::Exception
                    cwrite.write([CONTROL_UNEXPECTED].pack('I'))
                    raise
                end
            end

            # Feed the input
            if !input_streams.empty?
                pread.close
                begin
                    input_streams.each do |infile|
                        File.open(infile) do |instream|
                            instream.each_line { |line| pwrite.write(line) }
                        end
                    end
                rescue Errno::ENOENT => e
                    raise Failed.new, "cannot open input files: #{e.message}"
                end
                pwrite.close
            end

            # Get control status
            cwrite.close
            value = cread.read(4)
            if value
                # An error occured
                value = value.unpack('I').first
                if value == CONTROL_COMMAND_NOT_FOUND
                    raise Failed.new, "command '#{command.first}' not found"
                else
                    raise Failed.new, "something unexpected happened"
                end
            end

            # If the caller asked for process output, provide it to him
            # line-by-line.
            if outread
                outwrite.close
                outread.each_line do |line|
                    if Autobuild.verbose
                        STDOUT.print line
                    end
                    logfile.puts line
                    if !Autobuild.verbose && block_given?
                        yield(line)
                    end
                end
                outread.close
            end

            childpid, childstatus = Process.wait2(pid)
            childstatus
        end

        if !status.exitstatus || status.exitstatus > 0
            raise Failed.new(status.exitstatus), "'#{command.join(' ')}' returned status #{status.exitstatus}"
        end

        duration = Time.now - start_time
        Autobuild.add_stat(target, phase, duration)
        FileUtils.mkdir_p(Autobuild.logdir)
        File.open(File.join(Autobuild.logdir, "stats.log"), 'a') do |io|
            io.puts "#{target_name} #{phase} #{duration}"
        end
        if target.respond_to?(:add_stat)
            target.add_stat(phase, duration)
        end

    rescue Failed => e
        error = Autobuild::SubcommandFailed.new(target_name, command.join(" "), logname, e.status)
        error.phase = phase
        raise error, e.message
    end

end

