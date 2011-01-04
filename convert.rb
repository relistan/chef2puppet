#!/usr/bin/env ruby

require 'rubygems'
require 'json'
require 'Getopt/Declare'
require 'parse_tree'
require 'parse_tree_extensions'
require 'ruby2ruby'

args_spec = %q(
    -o <output_dir>    Output directory (where modules are written)
    -c <cookbook>      Chef Cookbook directory (e.g. contains /recipes, /attributes...)
)

args = Getopt::Declare.new(args_spec)

args.usage && exit if !(args.size == 2)

# map Chef resources to Puppet
def resource_translate resource
  @resource_map ||= {
       "cookbook_file" => "file",
       "cron" => "cron",
       "deploy" => "deploy",
       "directory" => "directory",
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
       "user" => "user"
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
        "gem_package" => "install"
  }
  return action_translate(@default_action_map[resource.to_s]) if @default_action_map[resource.to_s]
  nil
end

class ParsingContext
  attr_accessor :output, 
      :current_chef_resource, 
	  :class_name, 
	  :cookbook_name, 
	  :recipes_path, 
	  :files_path,
	  :templates_path,
	  :output_path,
	  :fname,
	  :short_fname

  def initialize output, cookbook_name, recipes_path, files_path, templates_path, output_path
    @output = output
	@current_chef_resource = current_chef_resource 
	@class_name = class_name
	@cookbook_name = cookbook_name
	@recipes_path = recipes_path
	@files_path = files_path
	@templates_path = templates_path
	@output_path = output_path
	@fname = ''
	@short_fname = ''
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
    block_source = block.to_ruby
    block_source =~ /command\s*(.+)/
    block_source = $1.gsub(/(^[(]*)|([)]*$)/, '')
    print "  # #{arg.gsub(/[-_]/, ' ')}\n  exec { '"
    # Some strings are interpolated with values from node[][] and this handles that
    # You get this for free from things evaluated inside ChefInnerBlock
    print ChefInnerBlock.new(@context).instance_eval(block_source)
    puts "':"

    handle_inner_block &block
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
      @statements << "content => template('#{arg}')"
    elsif [ 'remote_file', 'file' ].include? @context.current_chef_resource
      @statements << "source => 'puppet://server/modules/#{@context.cookbook_name}/#{arg}"
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
    block_source.gsub!(/File\.exist\?/, "test -f ").gsub!(/[\(\)]/, '')
    @statements << "unless => '#{block_source}'" if block_given?
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
end

def process_recipes context
  Dir[File.join(context.recipes_path, '*')].each do |fname|
    context.fname = fname
    context.short_fname = fname.sub(/#{context.recipes_path}\//, '')
    context.class_name = context.short_fname.sub(/\.rb$/, '')
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
  puts "Copying #{context.fname}..."
  FileUtils.cp context.fname,  File.join(context.output_path, "templates")
end

# MAIN -------------------

# Detect/create configuration info
cookbook_name  = File.open("#{args['-c']}/metadata.json") { |f| JSON.parse(f.read) }['name']
recipes_path   = File.join(args['-c'], 'recipes')
templates_path = File.join(args['-c'], 'templates', 'default') # TODO this only handles default
files_path     = File.join(args['-c'], 'files', 'default')     # TODO this only handles default
output_path    = "#{args['-o']}/#{cookbook_name}"

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
  output_path
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

process_recipes context
process_files context
process_templates context
