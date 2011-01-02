#!/usr/bin/env ruby

require 'rubygems'
require 'json'
require 'parse_tree'
require 'parse_tree_extensions'
require 'ruby2ruby'

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
end

# Responsible for the top level Chef DSL resources
class ChefResource

  def initialize
    @current_chef_resource = ''
  end
  
  def handle_inner_block &block
    inside_block = ChefInnerBlock.new
	inside_block.current_chef_resource = @current_chef_resource
	inside_block.instance_eval &block if block_given?

    if inside_block.statements.select { |s| s =~ /^ensure/ }.empty? && default_action(@current_chef_resource)
	  inside_block.statements << "ensure => '#{default_action(@current_chef_resource)}'"
	end

	print "    " + inside_block.statements.join(",\n    ")

    puts ";\n  }\n\n"
	self
  end

  def handle_resource chef_name, *args, &block
    @current_chef_resource = chef_name
	if args
      puts "  #{resource_translate(chef_name)} { '#{args[0]}':"
	end

	handle_inner_block &block
  end

  def execute arg, &block
    # exec takes the command as the namevar unlike Chef
    @current_chef_resource = 'execute'
	block_source = block.to_ruby
    block_source =~ /command\s*(.+)/
	block_source = $1.gsub(/(^[(]*)|([)]*$)/, '')
    print "  # #{arg.gsub(/[-_]/, ' ')}\n  exec { '"
	# Some strings are interpolated with values from node[][] and this handles that
	# You get this for free from things evaluated inside ChefInnerBlock
	print ChefInnerBlock.new.instance_eval(block_source)
	puts "':"

	handle_inner_block &block
  end

  def method_missing id, *args, &block
    handle_resource id.id2name, *args, &block
  end

end

# Responsible for the blocks passed to the top level Chef resources
class ChefInnerBlock

  attr_accessor :statements, :current_chef_resource

  def initialize
    @statements = []
	@current_chef_resource = ''
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
  # ------------
  
  # Link -------
  def to arg
    @statements << "ensure => '#{arg}'"
	self
  end
  # ------------

  # Template ----
  def source arg
    if @current_chef_resource == 'template'
      @statements << "content => template('#{arg}')"
	elsif [ 'remote_file', 'file' ].include? @current_chef_resource
      @statements << "source => 'puppet:///#{arg}"
	end
	self
  end

  def backup arg
    @statements << "backup => #{arg}"
    self
  end
  # ------------

  def action arg, &block
    @statements << arg.to_a.map { |action| "ensure => '#{action_translate(action)}'" }
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
    
	ChefInnerBlock.new.instance_eval &block if block_given?
	self
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

block_buffer = []
class_opened = false
recipe_name = File.open("#{ARGV[0]}/metadata.json") { |f| JSON.parse(f.read) }['name']

File.open(File.join(ARGV[0], 'recipes', ARGV[1])) do |f|
  f.each_line do |line|
    # Blank lines
	next if line =~ /^\s*$/

    # Comments
    if line =~ /^#/
      if class_opened
        puts "  #{line}"
      else
	    puts line
      end
	  next
	end

	block_buffer << line

	if line =~ /^end/
      puts "class #{recipe_name} {" unless class_opened
      class_opened = true
      puppeteer = ChefResource.new
	  puppeteer.instance_eval block_buffer.join("\n")
	  block_buffer = []
	end
  end
end
puts "}"
