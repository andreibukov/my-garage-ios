"""Fail before upload/build if a private report or unexpected file enters the package."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
allowed = {'.swift', '.js', '.yml', '.md', '.py', '.gitignore', '.json'}
example_plates = {'CA1234AB', 'CA9999AB', 'PB1234AB'}
skip = {'.git', '.build', 'build', 'build-simulator', 'dist', 'MyGarage.xcodeproj', '__pycache__'}
count = 0
for file in root.rglob('*'):
    if not file.is_file() or any(part in skip for part in file.relative_to(root).parts):
        continue
    if file.suffix not in allowed and file.name != '.gitignore':
        raise SystemExit(f'Unexpected file in public package: {file.relative_to(root)}')
    text = file.read_text(encoding='utf-8')
    plates = re.findall(r'(?<![A-Z0-9])[ABEKMHOPCTYX]{1,2}[0-9]{4}[ABEKMHOPCTYX]{1,2}(?![A-Z0-9])', text)
    if any(value not in example_plates for value in plates):
        raise SystemExit(f'Private test data found: {file.relative_to(root)}')
    if re.search(r'gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----', text):
        raise SystemExit(f'Possible credential found: {file.relative_to(root)}')
    count += 1
for required in ['Package.swift', 'project.yml', 'App/MyGarageApp.swift', 'Resources/webview-bridge.js', '.github/workflows/ios.yml']:
    if not (root / required).is_file():
        raise SystemExit(f'Missing required file: {required}')
print(f'Public package checked: {count} text files; only documented example plates and no credential patterns.')
