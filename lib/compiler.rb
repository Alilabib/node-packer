# Copyright (c) 2017 Minqi Pan <pmq2001@gmail.com>
# 
# This file is part of Node.js Compiler, distributed under the MIT License
# For full terms see the included LICENSE file

require "compiler/constants"
require "compiler/error"
require "compiler/utils"
require "compiler/npm_package"
require 'shellwords'
require 'tmpdir'
require 'fileutils'
require 'open3'

class Compiler
  def self.node_version
    @node_version ||= peek_node_version
  end

  def self.peek_node_version
    version_info = File.read(File.join(PRJ_ROOT, 'node/src/node_version.h'))
    versions = []
    if version_info =~ /NODE_MAJOR_VERSION\s+(\d+)/
      versions << $1.dup
    else
      raise 'Cannot peek NODE_MAJOR_VERSION'
    end
    if version_info =~ /NODE_MINOR_VERSION\s+(\d+)/
      versions << $1.dup
    else
      raise 'Cannot peek NODE_MINOR_VERSION'
    end
    if version_info =~ /NODE_PATCH_VERSION\s+(\d+)/
      versions << $1.dup
    else
      raise 'Cannot peek NODE_PATCH_VERSION'
    end
    versions.join('.')
  end

  def initialize(entrance, options = {})
    @options = options
    @entrance = entrance

    check_base_node_version!

    init_options
    init_entrance_and_root
    init_tmpdir

    STDERR.puts "Entrance: #{@entrance}"
    STDERR.puts "Options: #{@options}"
    STDERR.puts

    stuff_tmpdir
  end

  def check_base_node_version!
    expectation = "v#{self.class.node_version}"
    got = `node -v`.to_s.strip
    unless got.include?(expectation)
      msg =  "=== WARNING ===\n"
      msg += "Please make sure to have installed the correct version of node in your environment.\n"
      msg += "It should match the enclosed Node.js runtime version of the compiler.\n"
      msg += "Expecting #{expectation}; yet got #{got}.\n\n"
      STDERR.puts msg
    end
  end

  def init_entrance_and_root
    if @npm_package
      @root = @npm_package.work_dir
      return
    end
    # Important to expand_path; otherwiser the while would be erroneous
    @entrance = File.expand_path(@entrance)
    raise Error, "Cannot find entrance #{@entrance}." unless File.exist?(@entrance)
    if @options[:root]
      @root = File.expand_path(@options[:root])
    else
      @root = File.dirname(@entrance)
      # this while has to correspond with the expand_path above
      while !File.exist?(File.expand_path('./package.json', @root))
        break if @root == File.expand_path('..', @root)
        @root = File.expand_path('..', @root)
      end
    end
    unless File.exist?(File.expand_path('./package.json', @root))
      raise Error, "Cannot find a package.json inside #{@root}"
    end
  end

  def init_options
    @options[:npm] ||= 'npm'
    @options[:make_args] ||= '-j4'
    @options[:vcbuild_args] ||= "#{`node -pe process.arch`.to_s.strip} nosign"
    if Gem.win_platform?
      @options[:output] ||= 'a.exe'
    else
      @options[:output] ||= 'a.out'
    end
    @options[:output] = File.expand_path(@options[:output])

    @options[:tmpdir] ||= File.expand_path("nodec", Dir.tmpdir)
    @options[:tmpdir] = File.expand_path(@options[:tmpdir])
    
    if @options[:npm_package]
      @options[:npm_package_version] ||= 'latest'
      @npm_package = NpmPackage.new(@options)
    end
  end

  def init_tmpdir
    @options[:tmpdir] = File.expand_path(@options[:tmpdir])
    @root = File.expand_path(@root)
    if !@npm_package && (@options[:tmpdir].include? @root)
      raise Error, "tmpdir #{@options[:tmpdir]} cannot reside inside #{@root}."
    end
    @work_dir = File.join(@options[:tmpdir], '__work_dir__')
    @work_dir_inner = File.join(@work_dir, '__enclose_io_memfs__')
  end

  def stuff_tmpdir
    Utils.rm_rf(@options[:tmpdir]) if @options[:clean_tmpdir]
    Utils.mkdir_p(@options[:tmpdir])
    @tmpdir_node = File.join(@options[:tmpdir], 'node')
    unless Dir.exist?(@tmpdir_node)
      Utils.cp_r(File.join(PRJ_ROOT, 'node'), @tmpdir_node, preserve: true)
    end
    @npm_package.stuff_tmpdir if @npm_package
  end

  def run!
    npm_install unless @options[:keep_tmpdir]
    npm_package_set_entrance if @npm_package
    make_enclose_io_memfs
    make_enclose_io_vars
    if Gem.win_platform?
      compile_win
    elsif RbConfig::CONFIG['host_os'] =~ /darwin|mac os/i
      compile_mac
    else
      compile_linux
    end
  end

  def npm_package_set_entrance
    Utils.chdir(@work_dir_inner) do
      @entrance = @npm_package.get_entrance(@entrance)
      STDERR.puts "-> Setting entrance to #{@entrance}"
    end
  end

  def npm_install
    Utils.rm_rf(@work_dir)
    Utils.mkdir_p(@work_dir)

    Utils.cp_r(@root, @work_dir_inner)
    Utils.chdir(@work_dir_inner) do
      Utils.run("#{Utils.escape @options[:npm]} -v")
      Utils.run("#{Utils.escape @options[:npm]} install --production")
    end

    Utils.chdir(@work_dir_inner) do
      if Dir.exist?('.git')
        STDERR.puts `git status`
        Utils.rm_rf('.git')
      end
    end
  end

  def make_enclose_io_memfs
    Utils.chdir(@tmpdir_node) do
      Utils.rm_f('deps/libsquash/sample/enclose_io_memfs.squashfs')
      Utils.rm_f('deps/libsquash/sample/enclose_io_memfs.c')
      begin
        Utils.run("mksquashfs -version")
      rescue => e
        msg =  "=== HINT ===\n"
        msg += "Failed exectuing mksquashfs. Have you installed SquashFS Tools?\n"
        msg += "- On Windows, you could download it from https://github.com/pmq20/squashfuse/files/691217/sqfs43-win32.zip\n"
        msg += "- On macOS, you could install by using brew: brew install squashfs\n"
        msg += "- On Linux, you could install via apt or yum, or build from source after downloading source from http://squashfs.sourceforge.net/\n\n"
        STDERR.puts msg
        raise e
      end
      Utils.run("mksquashfs #{Utils.escape @work_dir} deps/libsquash/sample/enclose_io_memfs.squashfs")
      bytes = IO.binread('deps/libsquash/sample/enclose_io_memfs.squashfs').bytes
      # remember to change libsquash's sample/enclose_io_memfs.c as well
      File.open("deps/libsquash/sample/enclose_io_memfs.c", "w") do |f|
        f.puts '#include <stdint.h>'
        f.puts '#include <stddef.h>'
        f.puts '#include "squash.h"'
        f.puts 'sqfs *enclose_io_fs;'
        f.puts "const uint8_t enclose_io_memfs[#{bytes.size}] = { #{bytes[0]}"
        i = 1
        while i < bytes.size
          f.print ','
          f.puts bytes[(i)..(i + 100)].join(',')
          i += 101
        end
        f.puts '};'
        f.puts ''
      end
    end
  end

  def make_enclose_io_vars
    Utils.chdir(@tmpdir_node) do
      File.open("deps/libsquash/sample/enclose_io.h", "w") do |f|
        # remember to change libsquash's sample/enclose_io.h as well
        f.puts '#ifndef ENCLOSE_IO_H_999BC1DA'
        f.puts '#define ENCLOSE_IO_H_999BC1DA'
        f.puts ''
        f.puts '#include "enclose_io_prelude.h"'
        f.puts '#include "enclose_io_common.h"'
        f.puts '#include "enclose_io_win32.h"'
        f.puts '#include "enclose_io_unix.h"'
        if Gem.win_platform?
          f.puts "#define ENCLOSE_IO_ENTRANCE L#{mempath(@entrance).inspect}"
          # TODO remove this dirty hack some day
          squash_root_alias = @work_dir
          squash_root_alias += '/' unless '/' == squash_root_alias[-1]
          raise 'logic error' unless ':/' == squash_root_alias[1..2]
          squash_root_alias = "/cygdrive/#{squash_root_alias[0].downcase}/#{squash_root_alias[3..-1]}"
          f.puts "#define ENCLOSE_IO_ROOT_ALIAS #{squash_root_alias.inspect}"
        else
          f.puts "#define ENCLOSE_IO_ENTRANCE #{mempath(@entrance).inspect}"
        end
        f.puts '#endif'
        f.puts ''
      end
    end
  end

  def compile_win
    Utils.chdir(@tmpdir_node) do
      # --without-intl=none fixes: icutrim.py - it tries to run a binary made for linux on mac
      # --cross-compiling is required require host executables rather than target ones
      # --without-snapshot avoids mksnapshot to run on host platform after build
      Utils.run("call vcbuild.bat #{@options[:debug] ? 'debug' : ''} #{@options[:vcbuild_args]}")
    end
    src = File.join(@tmpdir_node, (@options[:debug] ? 'Debug\\node.exe' : 'Release\\node.exe'))
    Utils.cp(src, @options[:output])
  end

  def compile_mac
    Utils.chdir(@tmpdir_node) do
      # --without-intl=none fixes: icutrim.py - it tries to run a binary made for linux on mac
      # --cross-compiling is required require host executables rather than target ones
      # --without-snapshot avoids mksnapshot to run on host platform after build
      Utils.run("./configure #{@options[:debug] ? '--debug --xcode' : ''} #{@options[:os] ? '--cross-compiling --without-snapshot  --with-intl=none': ''} #{@options[:os] ? '--dest-os=' + @options[:os]: ''} #{@options[:arch] ? '--dest-cpu=' + @options[:arch]: ''}")
      Utils.run("make #{@options[:make_args]}")
    end
    src = File.join(@tmpdir_node, "out/#{@options[:debug] ? 'Debug' : 'Release'}/node")
    Utils.cp(src, @options[:output])
  end

  def compile_linux
    Utils.chdir(@tmpdir_node) do
      # --without-intl=none fixes: icutrim.py - it tries to run a binary made for linux on mac
      # --cross-compiling is required require host executables rather than target ones
      # --without-snapshot avoids mksnapshot to run on host platform after build
      Utils.run("./configure #{@options[:debug] ? '--debug' : ''} #{@options[:os] ? '--cross-compiling --without-snapshot  --with-intl=none': ''} #{@options[:os] ? '--dest-os=' + @options[:os]: ''} #{@options[:arch] ? '--dest-cpu=' + @options[:arch]: ''}")
      Utils.run("make #{@options[:make_args]}")
    end
    src = File.join(@tmpdir_node, "out/#{@options[:debug] ? 'Debug' : 'Release'}/node")
    Utils.cp(src, @options[:output])
  end

  def mempath(path)
    path = File.expand_path(path)
    raise "path #{path} should start with #{@root}" unless @root == path[0...(@root.size)]
    "#{MEMFS}#{path[(@root.size)..-1]}"
  end

  def copypath(path)
    path = File.expand_path(path)
    raise 'Logic error 1 in copypath' unless @root == path[0...(@root.size)]
    ret = File.join(@copy_dir, path[(@root.size)..-1])
    raise 'Logic error 2 in copypath' unless File.exist?(ret)
    ret
  end
end
