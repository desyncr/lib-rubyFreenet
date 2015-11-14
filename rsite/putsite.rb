#!/usr/bin/ruby
# == Description
#
# Basic wrapper for rsite to put in a new or update an existing freesite from
# a directory on the same server as the node.
#
# == Usage
#
# putsite.rb [OPTIONS] ... DIR
#
# -h, --help:
#     This message
#
# -n, --name:
#     The site name and the file to save the rsite info to. If this is found
#     in ./ then the details will be loaded from it and the site updated
#
# -t, --type:
#     The type of site, either USK or SSK
require './rsite'
require 'getoptlong'

opts = GetoptLong.new(
  ['--help', '-h', GetoptLong::NO_ARGUMENT],
  ['--name', '-n', GetoptLong::REQUIRED_ARGUMENT],
  ['--type', '-t', GetoptLong::OPTIONAL_ARGUMENT],
  ['--keys', '-k', GetoptLong::OPTIONAL_ARGUMENT]
)

dir = nil
name = nil
keys = nil
type = 'SSK'

opts.each do |opt, arg|
  case opt
  when '--help'
      puts <<-EOF
putsite.rb [OPTIONS] ... DIR

-h, --help:
    This message

-n, --name:
    The site name and the file to save the rsite info to. If this is found
    in ./ then the details will be loaded from it and the site updated

-t, --type:
    The type of site, either USK or SSK
    EOF
    exit 0
  when '--name'
    name = arg.to_s
  when '--type'
    type = arg.to_s
  when '--keys'
    keys = arg.to_s.split(';')
  end
end
if ARGV.length != 1
  puts "Missing dir argument (try --help)"
  exit 0
end

dir = File.expand_path(ARGV.shift)
if name and File.exists? name
  site = Freenet::Site.load(name)
else
  site = Freenet::Site.new(type, dir, name)
end

site.keys = keys if keys
site.connect
site.insert_site
site.save(name)
