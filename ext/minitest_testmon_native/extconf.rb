# frozen_string_literal: true

require "mkmf"

headers = ["ruby.h", "ruby/debug.h", "ruby/ractor.h"]
abort "MRI TracePoint and Ractor headers are required" unless headers.all? { |header| have_header(header) }
%w[rb_tracepoint_new rb_tracearg_event rb_tracearg_method_id rb_ractor_local_storage_value_newkey rb_ractor_local_storage_value rb_ractor_local_storage_value_set].each do |function|
  abort "MRI API #{function} is required" unless have_func(function, headers)
end

create_makefile("minitest/testmon/native_tracepoint")
