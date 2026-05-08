#!/usr/bin/env ruby
# frozen_string_literal: true

ROOT = Dir.pwd
SRC_DIR = File.join(ROOT, 'src')

def read_trimmed(file_path)
  File.read(file_path).sub(/\s+\z/, '')
end

def indent(content, spaces)
  content.lines(chomp: true).map { |line| line.empty? ? '' : "#{' ' * spaces}#{line}" }.join("\n")
end

def expand_includes(content, base_dir = SRC_DIR)
  expanded = content.gsub(/^(\s*[^:\n]+:\s*)<<include\(([^)]+)\)>>\s*$/) do
    prefix = Regexp.last_match(1)
    include_path = Regexp.last_match(2).strip
    included = read_trimmed(File.join(base_dir, include_path))
    key_indent = prefix[/\A\s*/].length
    "#{prefix}|\n#{indent(included, key_indent + 2)}"
  end

  expanded.gsub(/^(\s*)<<include\(([^)]+)\)>>/) do
    leading = Regexp.last_match(1)
    include_path = Regexp.last_match(2).strip
    indent(read_trimmed(File.join(base_dir, include_path)), leading.length)
  end
end

def append_section(lines, section_name, directory_name)
  directory = File.join(SRC_DIR, directory_name)
  return unless Dir.exist?(directory)

  files = Dir.children(directory).select { |file| file.end_with?('.yml') }.sort
  return if files.empty?

  lines << ''
  lines << "#{section_name}:"
  files.each do |file|
    key = File.basename(file, '.yml')
    content = expand_includes(read_trimmed(File.join(directory, file)))
    lines << "  #{key}:"
    lines << indent(content, 4)
  end
end

lines = [expand_includes(read_trimmed(File.join(SRC_DIR, '@orb.yml')))]
append_section(lines, 'executors', 'executors')
append_section(lines, 'commands', 'commands')
append_section(lines, 'jobs', 'jobs')
append_section(lines, 'examples', 'examples')

File.write(File.join(ROOT, 'orb.yml'), "#{lines.join("\n")}\n")
