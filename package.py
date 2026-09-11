#!/usr/bin/env python3
"""Create a reproducible SDK-only Swift source archive for repository releases."""
import hashlib
from pathlib import Path
import stat
import zipfile
import re

root = Path(__file__).resolve().parent
sources = ['Package.swift', 'README.md', 'LICENSE', 'CONTRIBUTING.md', 'CODE_OF_CONDUCT.md',
           'SECURITY.md', 'SUPPORT.md', 'Makefile', 'package.py', 'Sources', 'Tests',
           'vendor', '.github', '.gitignore', 'release.json', 'RELEASING.md']
files = []
for name in sources:
    path = root / name
    if not path.exists():
        raise ValueError(f'Missing Swift package source: {name}')
    if path.is_symlink() or any(file.is_symlink() for file in path.rglob('*')):
        raise ValueError('Swift source packages must not contain symlinks')
    files.extend([path] if path.is_file() else [
        file for file in path.rglob('*')
        if file.is_file() and '__pycache__' not in file.parts
        and file.suffix not in {'.pyc', '.pyo'} and file.name != '.DS_Store'
    ])
destination = root / 'artifacts'
destination.mkdir(exist_ok=True)
version = re.search(r'sdkClientVersion = "swift/([^"]+)"', (root / 'Sources/Jelto/Wire.swift').read_text())[1]
if not re.fullmatch(r'[0-9A-Za-z.-]+', version):
    raise ValueError('Invalid Swift package version')
archive = destination / f'jelto-swift-{version}.zip'
with zipfile.ZipFile(archive, 'w') as output:
    for file in sorted(files):
        if file.is_symlink():
            raise ValueError('Swift source packages must not contain symlinks')
        entry = zipfile.ZipInfo(file.relative_to(root).as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
        entry.create_system = 3
        entry.external_attr = (stat.S_IFREG | 0o644) << 16
        entry.compress_type = zipfile.ZIP_DEFLATED
        output.writestr(entry, file.read_bytes(), compresslevel=9)
checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
(destination / 'CHECKSUMS').write_text(f'{checksum}  {archive.name}\n')
print(archive)
