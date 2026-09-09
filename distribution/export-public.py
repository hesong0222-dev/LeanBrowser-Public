#!/usr/bin/env python3
"""Export the native browser release source without private repository history."""
import argparse
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path, help='new, nonexistent output directory')
    args = parser.parse_args()
    source = Path(__file__).resolve().parents[1]
    destination = args.destination.resolve()
    if destination.exists():
        parser.error('destination must not exist; refusing to overwrite')
    files = [Path('LICENSE'), Path('native/Info.plist'), Path('native/make-icon.swift')]
    native_files = [p.relative_to(source) for p in sorted((source / 'native/LeanBrowser').glob('*.swift'))]
    if not native_files:
        parser.error('native Swift source directory is empty')
    files += native_files
    files += [Path('scripts') / name for name in ['build-native.sh', 'native_agent.py', 'test_native_agent_mcp.py', 'package-native-release.sh', 'install-agent-kit.sh']]
    files += [Path('distribution') / name for name in ['README.md', 'THIRD_PARTY_NOTICES.md', 'RELEASE_NOTES.md', 'export-public.py']]
    files += [Path('skills/leanbrowser/SKILL.md'), Path('skills/leanbrowser/references/protocol.md')]
    for path in files:
        item = source / path
        if not item.is_file() or item.is_symlink():
            parser.error('missing or symlinked release input: ' + str(path))
    destination.mkdir(parents=True)
    for path in files:
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / path, target)
    for name in ['README.md', 'THIRD_PARTY_NOTICES.md']:
        shutil.copy2(source / 'distribution' / name, destination / name)
    (destination / '.gitignore').write_text('/dist/\n/dist-qa/\n__pycache__/\n*.pyc\n.DS_Store\n', encoding='utf-8')
    print(f'Exported {len(files)} allowlisted files to {destination}')


if __name__ == '__main__':
    main()
