# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Minitest
  module Testmon
    module AtomicFile
      module_function

      def write(path, contents, mode: 0o644)
        destination = File.expand_path(path)
        directory = File.dirname(destination)
        FileUtils.mkdir_p(directory)
        temporary = File.join(
          directory,
          ".#{File.basename(destination)}.tmp-#{Process.pid}-#{SecureRandom.hex(8)}"
        )
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
          file.binmode
          file.write(contents)
          file.flush
          file.fsync
        end
        File.rename(temporary, destination)
        File.open(directory, File::RDONLY, &:fsync)
        destination
      ensure
        File.unlink(temporary) if temporary && File.file?(temporary)
      end
    end
  end
end
