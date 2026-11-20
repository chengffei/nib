#!/usr/bin/env python3
"""Generates THIRD-PARTY-NOTICES.md: lists the npm packages bundled into Nib/Editor/editor.js along with their full licence texts.
Usage (from the repo root): python3 scripts/notices.py   Re-run whenever dependencies change."""
import json, os, re, subprocess, tempfile

web = os.path.join(os.path.dirname(__file__), '..', 'Web')
meta = os.path.join(tempfile.mkdtemp(), 'meta.json')
subprocess.run(['npx', 'esbuild', 'src/main.js', '--bundle', '--format=iife', f'--metafile={meta}',
                '--outfile=/dev/null', '--log-level=error'], cwd=web, check=True)
pkgs = set()
for f in json.load(open(meta))['inputs']:
    m = re.match(r'node_modules/((?:@[^/]+/)?[^/]+)', f)
    if m: pkgs.add(m.group(1))

out = ['# Third-Party Notices', '', 'Nib bundles the following open-source packages into `Nib/Editor/editor.js`.', '']
for p in sorted(pkgs):
    d = os.path.join(web, 'node_modules', p)
    info = json.load(open(os.path.join(d, 'package.json')))
    lic = next((os.path.join(d, n) for n in sorted(os.listdir(d)) if re.match(r'(?i)licen[cs]e', n)), None)
    out += [f'## {p} {info.get("version", "")}', '', f'License: {info.get("license", "unknown")}', '']
    out += ['```', open(lic).read().strip() if lic else '(no license file shipped in package)', '```', '']
open(os.path.join(web, '..', 'THIRD-PARTY-NOTICES.md'), 'w').write('\n'.join(out))
print(f'{len(pkgs)} packages')
