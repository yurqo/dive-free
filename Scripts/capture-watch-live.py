"""Capture the real live Watch UI with a verified native system clock.

watchOS rejects simctl status_bar overrides. A temporary TZ in the simulator's
Carousel environment controls its native clock instead. Always restore the old
value; never modify the host clock or screenshot pixels.
"""
import argparse
import datetime
import os
import pathlib
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--device', required=True)
parser.add_argument('--bundle', required=True)
parser.add_argument('--language', required=True)
parser.add_argument('--locale', required=True)
parser.add_argument('--output', required=True, type=pathlib.Path)
parser.add_argument('--clock', default='17:02', help='Featured dive wall time, HH:MM')
parser.add_argument('--simctl', help='Explicit CLI path; defaults to xcrun simctl')
args = parser.parse_args()
simctl = [args.simctl] if args.simctl else ['xcrun', 'simctl']
hour, minute = map(int, args.clock.split(':'))
if not (0 <= hour < 24 and 0 <= minute < 60):
    parser.error('--clock requires a valid HH:MM')
expected = {f'{hour}:{minute:02}', f'{hour:02}:{minute:02}', f'{hour % 12 or 12}:{minute:02}'}
clock_reader = pathlib.Path(__file__).with_name('read-watch-clock.swift')


def run(*command, check=True):
    return subprocess.run(simctl + list(command), check=check, capture_output=True, text=True)


prior = run('spawn', args.device, 'launchctl', 'getenv', 'TZ', check=False).stdout.strip()
try:
    for attempt in range(3):
        now = datetime.datetime.now(datetime.timezone.utc)
        if now.second > 20:
            time.sleep(61 - now.second)
        now = datetime.datetime.now(datetime.timezone.utc)
        offset = hour * 60 + minute - (now.hour * 60 + now.minute)
        h, m = divmod(abs(offset), 60)
        zone = f'UTC{"+" if offset >= 0 else "-"}{h}:{m:02}'
        run('spawn', args.device, 'launchctl', 'setenv', 'TZ', zone)
        run('spawn', args.device, 'launchctl', 'kickstart', '-k', 'system/com.apple.Carousel')
        time.sleep(8)
        for retry in range(3):
            data = pathlib.Path(run('get_app_container', args.device, args.bundle, 'data').stdout.strip()) / 'Documents'
            for filename in ['screenshot-ready.txt', 'screenshot-language.txt']:
                (data / filename).unlink(missing_ok=True)
            run('launch', '--terminate-running-process', args.device, args.bundle,
                '-AppleLanguages', f'({args.language})', '-AppleLocale', args.locale,
                '-unitMode', 'metric', '--screenshot-demo', '--screenshot-screen', '01-live')
            for poll in range(100):
                ready = data / 'screenshot-ready.txt'
                if ready.exists() and ready.read_text() == '01-live':
                    break
                time.sleep(.2)
            else:
                raise RuntimeError('Live Watch screen did not become ready')
            resolved = (data / 'screenshot-language.txt').read_text().strip()
            if resolved != args.language:
                raise RuntimeError(f'Requested {args.language}, resolved {resolved}')
            time.sleep(3)
            temporary = args.output.with_suffix('.capturing.png')
            run('io', args.device, 'screenshot', '--type=png', '--mask=black', str(temporary))
            quality = subprocess.run(['swift', str(clock_reader.with_name('validate-watch-screenshot.swift')), str(temporary)], capture_output=True, text=True)
            if quality.returncode != 0:
                temporary.unlink(missing_ok=True)
                continue
            ocr = subprocess.run(['swift', str(clock_reader), str(temporary)], capture_output=True, text=True)
            if ocr.returncode == 0 and ocr.stdout.strip() in expected:
                os.replace(temporary, args.output)
                print(f'Native Watch clock verified: {ocr.stdout.strip()}')
                break
            temporary.unlink(missing_ok=True)
        else:
            continue
        break
    else:
        raise RuntimeError(f'Unable to capture native Watch clock {args.clock}')
finally:
    run('terminate', args.device, args.bundle, check=False)
    if prior:
        run('spawn', args.device, 'launchctl', 'setenv', 'TZ', prior, check=False)
    else:
        run('spawn', args.device, 'launchctl', 'unsetenv', 'TZ', check=False)
    run('spawn', args.device, 'launchctl', 'kickstart', '-k', 'system/com.apple.Carousel', check=False)
