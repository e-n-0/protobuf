require "ffi-compiler/compile_task"

# # @param task [FFI::Compiler::CompileTask] task to configure
def configure_common_compile_task(task)
  if FileUtils.pwd.include? 'ext'
    src_dir = '.'
    third_party_path = 'third_party/utf8_range'
  else
    src_dir = 'ext/google/protobuf_c'
    third_party_path = 'ext/google/protobuf_c/third_party/utf8_range'
  end

  task.add_include_path third_party_path
  task.add_define 'NDEBUG'
  task.cflags << "-std=gnu99 -O0 -g"
  [
    :convert, :defs, :map, :message, :protobuf, :repeated_field, :wrap_memcpy
  ].each { |file| task.exclude << "/#{file}.c" }
  task.ext_dir = src_dir
  task.source_dirs = [src_dir]
  if RbConfig::CONFIG['target_os'] =~ /darwin|linux/
    task.cflags << "-Wall -Wsign-compare -Wno-declaration-after-statement"
  end
end

# FFI::CompilerTask's constructor walks the filesystem at task definition time
# to create subtasks for each source file, so files from third_party must be
# copied into place before the task is defined for it to work correctly.
# TODO(jatl) Is there a sane way to check for generated protos under lib too?
def with_generated_files
  expected_path = FileUtils.pwd.include?('ext') ? 'third_party/utf8_range' : 'ext/google/protobuf_c/third_party/utf8_range'
  if File.directory?(expected_path)
    yield
  else
    task :default do
      # It is possible, especially in cases like the first invocation of
      # `rake test` following `rake clean` or a fresh checkout that the
      # `copy_third_party` task has been executed since initial task definition.
      # If so, run the task definition block now and invoke it explicitly.
      if File.directory?(expected_path)
        yield
        Rake::Task[:default].invoke
      else
        raise "Missing directory #{File.absolute_path(expected_path)}." +
                " Did you forget to run `rake copy_third_party` before building" +
                " native extensions?"
      end
    end
  end
end

desc "Compile Protobuf library for FFI"
namespace "ffi-protobuf" do
  with_generated_files do
    # Compile Ruby UPB separately in order to limit use of -DUPB_BUILD_API to one
    # compilation unit.
    desc "Compile UPB library for FFI"
    namespace "ffi-upb" do
      with_generated_files do
        FFI::Compiler::CompileTask.new('ruby-upb') do |c|
          configure_common_compile_task c
          c.add_define "UPB_BUILD_API"
          c.exclude << "/glue.c"
          c.exclude << "/shared_message.c"
          c.exclude << "/shared_convert.c"
          if RbConfig::CONFIG['target_os'] =~ /darwin|linux/
            c.cflags << "-fvisibility=hidden"
          end
        end
      end
    end

    FFI::Compiler::CompileTask.new 'protobuf_c_ffi' do |c|
      configure_common_compile_task c
      # Ruby UPB was already compiled with different flags.
      c.exclude << "/range2-neon.c"
      c.exclude << "/range2-sse.c"
      c.exclude << "/naive.c"
      c.exclude << "/ruby-upb.c"
    end

    # Setup dependencies so that the .o files generated by building ffi-upb are
    # available to link here.
    # TODO(jatl) Can this be simplified? Can the single shared library be used
    # instead of the object files?
    protobuf_c_task = Rake::Task[:default]
    protobuf_c_shared_lib_task = Rake::Task[protobuf_c_task.prereqs.last]
    ruby_upb_shared_lib_task = Rake::Task[:"ffi-upb:default"].prereqs.first
    Rake::Task[ruby_upb_shared_lib_task].prereqs.each do |dependency|
      protobuf_c_shared_lib_task.prereqs.prepend dependency
    end
  end
end
