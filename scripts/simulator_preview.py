"""Launch the actual simulator app and capture its first screen (not a device test)."""
import json
from pathlib import Path
import subprocess
import time

def run(*arguments):
    return subprocess.check_output(arguments, text=True)

devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '--json'))['devices']
candidates = [device for runtime, items in sorted(devices.items(), reverse=True)
              if 'iOS' in runtime for device in items
              if device.get('isAvailable') and device['name'].startswith('iPhone')]
if not candidates:
    raise SystemExit('No available iPhone simulator on this runner.')
device = candidates[0]
udid = device['udid']
if device['state'] != 'Booted':
    run('xcrun', 'simctl', 'boot', udid)
run('xcrun', 'simctl', 'bootstatus', udid, '-b')
app = Path('build-simulator/Build/Products/Debug-iphonesimulator/MyGarage.app')
if not app.is_dir():
    raise SystemExit('Simulator .app is missing.')
run('xcrun', 'simctl', 'install', udid, str(app))
run('xcrun', 'simctl', 'launch', udid, 'bg.personal.mygarage')
time.sleep(5)
Path('dist').mkdir(exist_ok=True)
run('xcrun', 'simctl', 'io', udid, 'screenshot', 'dist/MyGarage-preview.png')
print('Captured the real running simulator screen on', device['name'])
