"""Package the device .app; SideStore performs personal signing at install time."""
from pathlib import Path
import plistlib
import zipfile

app = Path('build/Build/Products/Release-iphoneos/MyGarage.app')
if not app.is_dir():
    raise SystemExit('Device .app not found; the Xcode build must succeed first.')
with (app / 'Info.plist').open('rb') as file:
    info = plistlib.load(file)
if 'iPhoneOS' not in info.get('CFBundleSupportedPlatforms', []):
    raise SystemExit('Refusing to package a simulator build.')
if not (app / info['CFBundleExecutable']).is_file():
    raise SystemExit('Missing application executable.')
Path('dist').mkdir(exist_ok=True)
destination = Path('dist/MyGarage-unsigned.ipa')
with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
    for entry in sorted(app.rglob('*')):
        if entry.is_file():
            archive.write(entry, Path('Payload') / app.name / entry.relative_to(app))
print(f'Created {destination}; this is unsigned and must be signed before installation.')
