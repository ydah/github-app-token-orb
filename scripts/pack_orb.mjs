#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const srcDir = path.join(root, 'src');

const read = (filePath) => fs.readFileSync(filePath, 'utf8').replace(/\s+$/, '');

const indent = (content, spaces) =>
  content
    .split('\n')
    .map((line) => (line ? `${' '.repeat(spaces)}${line}` : ''))
    .join('\n');

const expandIncludes = (content, baseDir = srcDir) =>
  content
    .replace(/^(\s*[^:\n]+:\s*)<<include\(([^)]+)\)>>\s*$/gm, (_match, prefix, includePath) => {
      const included = read(path.join(baseDir, includePath.trim()));
      const keyIndent = prefix.match(/^\s*/)[0].length;
      return `${prefix}|\n${indent(included, keyIndent + 2)}`;
    })
    .replace(/^(\s*)<<include\(([^)]+)\)>>/gm, (_match, leading, includePath) => {
      const included = read(path.join(baseDir, includePath.trim()));
      return indent(included, leading.length);
    });

const appendSection = (lines, sectionName, directoryName) => {
  const directory = path.join(srcDir, directoryName);
  if (!fs.existsSync(directory)) {
    return;
  }

  const files = fs.readdirSync(directory).filter((file) => file.endsWith('.yml')).sort();
  if (files.length === 0) {
    return;
  }

  lines.push('', `${sectionName}:`);
  for (const file of files) {
    const key = path.basename(file, '.yml');
    const content = expandIncludes(read(path.join(directory, file)));
    lines.push(`  ${key}:`, indent(content, 4));
  }
};

const lines = [expandIncludes(read(path.join(srcDir, '@orb.yml')))];
appendSection(lines, 'executors', 'executors');
appendSection(lines, 'commands', 'commands');
appendSection(lines, 'jobs', 'jobs');
appendSection(lines, 'examples', 'examples');

fs.writeFileSync(path.join(root, 'orb.yml'), `${lines.join('\n')}\n`);
