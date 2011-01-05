#!/usr/bin/env ruby

# Chef2Puppet - Convert Chef cookbooks to Puppet manifests with minimized human
# intervention required.

# Tue Jan  4 11:55:05 PST 2011

require 'rubygems'
require 'json'
require 'parse_tree'
require 'parse_tree_extensions'
require 'ruby2ruby'
require 'net/http' # yuck
require 'stringio'
require 'optparse'

$options = {}
opts = OptionParser.new do |opts|
  opts.banner = "Usage: convert.rb [options]"

  opts.on("-c COOKBOOK", "--cookbook COOKBOOK", :REQUIRED, String, 
    "Chef Cookbook directory (e.g. contains /recipes, /attributes...)") do |cookbook|
      $options[:cookbook] = cookbook
  end

  opts.on("-o OUTPUT_DIR", "--output-dir OUTPUT_DIR", :REQUIRED, String, 
    "Output directory (where modules are written)") do |output_dir|
      $options[:output_dir] = output_dir
  end

  opts.on("-s SERVER_NAME", "--server-name SERVER_NAME", :REQUIRED, String, 
    "The name of the Puppet server to be used in puppet:// URLs") do |server_name|
      $options[:server_name] = server_name
  end
end

opts.parse!(ARGV)
if $options.keys.size < 3
  puts opts 
  exit
end

# map Chef resources to Puppet
def resource_translate resource
  @resource_map ||= {
       "cookbook_file" => "file",
       "cron" => "cron",
       "deploy" => "deploy",
       "directory" => "file",
       "erlang_call" => "erlang_call",
       "execute" => "exec",
       "file" => "file",
       "gem_package" => "package",
       "git" => "git",
       "group" => "group",
       "http_request" => "http_request",
       "ifconfig" => "ifconfig",
       "link" => "file",
       "log" => "log",
       "mdadm" => "mdadm",
       "mount" => "mount",
       "package" => "package",
       "remote_directory" => "remote_directory",
       "remote_file" => "file",
       "route" => "route",
       "ruby_block" => "ruby_block",
       "scm" => "scm",
       "script" => "script",
       "service" => "service",
       "subversion" => "subversion",
       "template" => "file",
       "user" => "user",
       "include_recipe" => "require"
  }
  return @resource_map[resource.to_s] if @resource_map[resource.to_s]
  resource.to_s
end

# map Chef actions to Puppet ensure statements
def action_translate action
  @action_map ||= {
       "install" => "installed" 
  }
  return @action_map[action.to_s] if @action_map[action.to_s]
  action.to_s
end

# Chef assumes default actions for some resources, so make them explicit for Puppet
def default_action resource
  @default_action_map ||= {
        "package" => "install",
        "gem_package" => "install",
        "directory" => "directory"
  }
  return action_translate(@default_action_map[resource.to_s]) if @default_action_map[resource.to_s]
  nil
end

class ParsingContext
  attr_accessor :output, 
      :current_chef_resource, 
      :cookbook_name, 
      :recipes_path, 
      :files_path,
      :templates_path,
      :output_path,
      :fname,
      :server_name

  def initialize output, cookbook_name, recipes_path, files_path, templates_path, output_path, server_name
    @output = output
    @current_chef_resource = current_chef_resource 
    @cookbook_name = cookbook_name
    @recipes_path = recipes_path
    @files_path = files_path
    @templates_path = templates_path
    @output_path = output_path
    @fname = ''
    @server_name = server_name
  end

  def short_fname
    if fname =~ /default.rb$/
      # We don't want output files called default.rb
      @short_fname = "#{@cookbook_name}.rb"
    else
      @short_fname = File.basename(@fname)
    end
  end

  def class_name
    @class_name ||= "#{@cookbook_name}::#{short_fname.sub(/\.rb$/, '')}"
  end

  def puts *args
    @output.puts *args
  end

  def print *args
    @output.print *args
  end

  def contents
    @output.string
  end

  def truncate
    @output.string = ''
  end
end

# Responsible for the top level Chef DSL resources
class ChefResource

  def initialize context
    @context = context
  end
  
  def handle_inner_block &block
    inside_block = ChefInnerBlock.new @context
    inside_block.instance_eval &block if block_given?

    print "    " + inside_block.result.join(",\n    ")

    puts ";\n  }\n\n"
    self
  end

  def handle_resource chef_name, *args, &block
    @context.current_chef_resource = chef_name
    if args
      puts "  #{resource_translate(chef_name)} { '#{args[0]}':"
    end

    handle_inner_block &block
  end

  def execute arg, &block
    # exec takes the command as the namevar unlike Chef
    @context.current_chef_resource = 'execute'

    # Isolate the command element and reformat it
    block_source = block.to_ruby
    block_source =~ /command\s*(.+)/
    block_source = $1.gsub(/(^[(]*)|([)]*$)/, '')
    print "  # #{arg.gsub(/[-_]/, ' ')}\n  exec { 'echo \""

    # Some strings are interpolated with values from node[][] and this handles that
    # You get this for free from things evaluated inside ChefInnerBlock
    print ChefInnerBlock.new(@context).instance_eval(block_source)
    puts "\" | bash':" # Puppet is unhappy with the exit status of /bin/sh
    puts "    path => '/bin:/usr/bin:/sbin:/usr/sbin'," # a bit hacky to do this here

    handle_inner_block &block
  end

  def include_recipe name, &block
    if name =~ /::/
      puts "  require #{name}\n"
    else
      puts "  require '#{name}::#{name}'\n" # The default case for Chef
    end
  end

  def method_missing id, *args, &block
    handle_resource id.id2name, *args, &block
  end

  def print *args
    @context.print *args
  end

  def puts *args
    @context.puts *args
  end

end

# Responsible for the blocks passed to the top level Chef resources
class ChefInnerBlock

  def initialize context
    @context = context
    @statements = []
  end

  def node *args
    return ChefNode.new
  end

  # Exec -------
  def command *args
    # eat it... handled by the call to the resource itself
    self
  end
  # ------------

  # Service ----
  def subscribes *args
    # eat it... we handle this with 'resources'
    self
  end

  def notifies *args
    # eat it... we handle this with 'resources'
    self
  end

  def resources args
    @statements << args.map { |k,v| "subscribe => #{resource_translate(k).to_s.capitalize}['#{v.to_s}']" }
    self
  end

  def running *args
    @statements << "ensure => running"
    self
  end
  # ------------
  
  # Link -------
  def to arg
    @statements << "ensure => '#{arg}'"
    self
  end
  # ------------

  # Template ----
  def source arg
    if @context.current_chef_resource == 'template'
      @statements << "content => template('#{@context.cookbook_name}/#{arg}')"
    elsif [ 'remote_file', 'file' ].include? @context.current_chef_resource
      outfile = arg.split("/").last
      if arg =~ /http/
        # Download the remote file
        outpath = File.join(@context.output_path, 'files', outfile)
        http_get arg, outpath unless File.exist? outpath
      end
      @statements << "source => 'puppet://#{@context.server_name}/modules/#{@context.cookbook_name}/#{outfile}'"
    end
    self
  end

  def backup arg
    @statements << "backup => #{arg}"
    self
  end
  # ------------

  def action arg, &block
    # Wouldn't it be nice if to_a wasn't deprecated for this case?
    arg = [ arg ] unless arg.is_a? Array
    @statements += arg.map { |action| "ensure => '#{action_translate(action)}'" }
  end

  def not_if *args, &block
    block_source = block.to_ruby.sub(/proc \{ /, '').sub(/ \}/, '')
    block_source.gsub!(/File\.exist\?/, "").gsub!(/[\(\)]/, '')
    @statements << "creates => #{block_source}" if block_given?
  end

  def only_if *args, &block
    block_source = block.to_ruby.sub(/proc \{ /, '').sub(/ \}/, '')
    block_source.gsub!(/File\.exist\?/, "test -f ").gsub!(/[\(\)]/, '')
    @statements << "onlyif => '#{block_source}'" if block_given?
  end

  def method_missing id, *args, &block
    if args
      if args.join(' ') =~ /^[0-9]+$/
        @statements << "#{id.id2name} => #{args.join(' ')}"
      else
        @statements << "#{id.id2name} => '#{args.join(' ')}'"
      end
    else
      @statements << id.id2name
    end
    
    # Handle at least two deep
    ChefInnerBlock.new(@context).instance_eval &block if block_given?
    self
  end

  def print *args
    @context.print *args
  end

  def puts *args
    @context.puts *args
  end

  # Called when the eval is complete.  Returns completed results
  def result
    if @statements.select do |s| 
          s =~ /^ensure => '#{default_action(@context.current_chef_resource)}'/ 
      end.empty? && default_action(@context.current_chef_resource)
      @statements << "ensure => '#{default_action(@context.current_chef_resource)}'"
    end
    @statements.uniq
  end

end

class ChefNode
  def initialize
    @calls = []
  end

  def method_missing id, *args, &block
    if id.id2name == '[]'
      @calls << "#{args.join}"
    else
      @calls << "#{id.id2name} #{args.join}"
    end

    self
  end

  def to_s 
    "${#{@calls.join('_')}}"
  end

  def to_s_bare
    @calls.join('_')
  end
end

def http_get url, output_path
  uri = URI.parse url
  $stderr.puts "Fetching #{uri.path} from #{uri.host} to #{output_path}..."
  Net::HTTP.start(uri.host) do |http|
    resp = http.get(uri.path)
    open(output_path, "wb") do |file|
      file.write(resp.body)
    end
  end
end

def process_recipes context
  Dir[File.join(context.recipes_path, '*')].each do |fname|
    context.fname = fname
    process_one_recipe context
  end
end

def process_one_recipe context
  class_opened = false
  block_buffer = []

  puts "Working on recipe... #{context.fname}"
  File.open(context.fname) do |f|
    f.each_line do |line|
      # Blank lines
      next if line =~ /^\s*$/
  
      # Comments
      if line =~ /^#/
        if class_opened
          context.puts "  #{line}"
        else
          context.puts line
        end

        next
      end
  
      block_buffer << line
  
      if line =~ /^end/
        context.puts "class #{context.class_name} {" unless class_opened
        class_opened = true
        puppeteer = ChefResource.new context
        puppeteer.instance_eval block_buffer.join
        block_buffer = []
      end
    end
  end

  context.puts "}" if class_opened
  outfile_name = File.join(context.output_path, "manifests", context.short_fname)
  outfile_name.sub! /\.rb/, '.pp'
  File.open(outfile_name, 'w') { |f| f.write(context.contents) }
  context.truncate
end

def process_files context
  Dir[File.join(context.files_path, '*')].each do |fname|
    context.fname = fname
    process_one_file context
  end
end

def process_one_file context
  puts "Copying #{context.fname}..."
  FileUtils.cp context.fname, File.join(context.output_path, "files")
end

def process_templates context
  Dir[File.join(context.templates_path, '*')].each do |fname|
    context.fname = fname
    process_one_template context
  end
end

def process_one_template context
  puts "Modifying template #{context.fname}..."
  File.open(context.fname) do |f| 
    # Attempt to reduce node[][]... to the same format used in the recipes
    output = f.map do |line|
      line.gsub /\@?(node\[.*\])/ do |match|
        node = ChefNode.new
        node.instance_eval $1
        node.to_s_bare
      end
    end

    File.open(File.join(context.output_path, "templates", context.short_fname), 'w') { |f| f.write output }
  end

end

# MAIN -------------------

# Detect/create configuration info
cookbook_name  = File.open("#{$options[:cookbook]}/metadata.json") { |f| JSON.parse(f.read) }['name']
recipes_path   = File.join($options[:cookbook], 'recipes')
templates_path = File.join($options[:cookbook], 'templates', 'default') # TODO this only handles default
files_path     = File.join($options[:cookbook], 'files', 'default')     # TODO this only handles default
output_path    = "#{$options[:output_dir]}/#{cookbook_name}"

puts "Cookbook Name:   #{cookbook_name}"
puts "Recipes Path:    #{recipes_path}"
puts "Templates Path:  #{templates_path}"
puts "Files Path:      #{files_path}"
puts "Output Path:     #{output_path}"

context = ParsingContext.new(
  StringIO.new, 
  cookbook_name,
  recipes_path,
  files_path,
  templates_path,
  output_path,
  $options[:server_name]
)

# Build the Puppet module output directory structure
[
    "/files",
    "/manifests",
    "/lib",
    "/lib/puppet",
    "/lib/puppet/parser",
    "/lib/puppet/provider",
    "/lib/puppet/type",
    "/lib/facter",
    "/templates"
].each { |dir| FileUtils.mkdir_p("#{ File.join(output_path, dir) }") }

# Do the actual work
process_recipes context
process_files context
process_templates context
