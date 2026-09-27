#!/usr/bin/env python3
"""Every relative Markdown link resolves to a file, and every #anchor to a heading."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def slug(heading):
    """GitHub's heading anchor: lowercase, punctuation dropped, spaces to hyphens."""
    text = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', heading.strip().lower())
    return re.sub(r'[^\w\- ]', '', re.sub(r'[`*_]', '', text)).replace(' ', '-')


def anchors(path):
    found, fenced = set(), False
    for line in path.read_text().splitlines():
        if line.startswith('```'):
            fenced = not fenced
        elif not fenced and (match := re.match(r'#{1,6}\s+(.*)', line)):
            found.add(slug(match.group(1)))
    return found


def broken_links(root, documents):
    """Links in `documents` that leave `root`, name a missing file, or a missing anchor."""
    root = Path(root).resolve()
    broken = []
    for document in documents:
        document = Path(document).resolve()
        text = re.sub(r'```.*?```', '', document.read_text(), flags=re.S)
        for target in re.findall(r'\]\(([^)\s]+)\)', text):
            if re.match(r'[a-z]+:', target):
                continue
            path, _, anchor = target.partition('#')
            resolved = (document.parent / path).resolve() if path else document
            label = f'{document.relative_to(root)}: {target}'
            if not resolved.is_relative_to(root) or not resolved.exists():
                broken.append(label + ' (missing file)')
            elif anchor and resolved.suffix == '.md' and anchor not in anchors(resolved):
                broken.append(label + ' (missing anchor)')
    return broken


if __name__ == '__main__':
    listed = subprocess.run(['git', 'ls-files', '-co', '--exclude-standard', '*.md'],
                            cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    documents = [ROOT / name for name in listed if (ROOT / name).exists()]
    broken = broken_links(ROOT, documents)
    print('\n'.join(broken) or f'PASS: links in {len(documents)} Markdown files resolve')
    sys.exit(1 if broken else 0)
