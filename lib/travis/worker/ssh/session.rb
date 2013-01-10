require 'net/ssh'
require 'shellwords'
require 'travis/worker/utils/buffer'
require 'travis/support/logging'

module Travis
  module Worker
    module Ssh
      # Encapsulates an SSH connection to a remote host.
      class Session
        include Logging

        log_header { "#{name}:shell:session" }

        attr_reader :name, :config, :ssh_session

        # Initialize a shell Session
        #
        # config - A hash containing the timeouts, shell buffer time and ssh connection information
        # block - An optional block of commands to be excuted within the session. If
        #         a block is provided then the session will be started, block evaluated,
        #         and then the session will be closed.
        def initialize(name, config)
          @name = name
          @config = Hashr.new(config)
        end

        # Connects to the remote host.
        #
        # Returns the Net::SSH::Shell
        def connect(silent = false)
          info "starting ssh session to #{config.host}:#{config.port} ..." unless silent
          options = { :port => config.port, :paranoid => false }
          options[:password] = config.password if config.password?
          options[:keys] = [config.private_key_path] if config.private_key_path?
          @ssh_session = Net::SSH.start(config.host, config.username, options)
          true
        end

        # Closes the Shell, flushes and resets the buffer
        def close
          ssh_session.close if open?
          buffer.stop
        end

        # Allows you to set a callback when output is received from the ssh shell.
        #
        # on_output - The block to be called.
        def on_output(&on_output)
          uuid = Travis.uuid
          @on_output = lambda do |*args, &block|
            Travis.uuid = uuid
            on_output.call(*args, &block)
          end
        end

        # Checks is the current shell is open.
        #
        # Returns true if the shell has been setup and is open, otherwise false.
        def open?
          ssh_session && !ssh_session.closed?
        end

        # This is where the real SSH shell work is done. The command is run along with
        # callbacks setup for when data is returned. The exit status is also captured
        # when the command has finished running.
        #
        # command - The command to be executed.
        # block   - A block which will be called when output or error output is received
        #           from the shell command.
        #
        # Returns the exit status (0 or 1)
        def exec(command, &on_output)
          connect unless open?

          exit_code = nil
          
          ssh_session.open_channel do |channel|
            channel.exec("/bin/bash --login -c #{Shellwords.escape(command)}") do |ch, success|
              unless success
                abort "FAILED: couldn't execute command (ssh.channel.exec)"
              end
                
              channel.on_data do |ch, data|
                buffer << data
              end

              # channel.on_extended_data do |ch,type,data|
              #   stderr_data += data
              # end

              channel.on_request("exit-status") do |ch,data|
                exit_code = data.read_long
              end

              # channel.on_request("exit-signal") do |ch, data|
              #   exit_signal = data.read_long
              # end
            end
          end
          
          ssh_session.loop(1)
              
          exit_code
        end

        def upload_file(path_and_name, content)
          encoded = Base64.encode64(content).gsub("\n", "")
          command = "(echo #{encoded} | base64 -d) >> #{path_and_name}"
          exec(command)
        end

        protected

          # Internal: Sets up and returns a buffer to use for the entire ssh session when code
          # is executed.
          def buffer
            @buffer ||= Utils::Buffer.new(config.buffer) do |string|
              @on_output.call(string, :header => log_header) if @on_output
            end
          end
      end
    end
  end
end