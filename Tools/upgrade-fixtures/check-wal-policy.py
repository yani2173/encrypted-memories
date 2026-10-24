#!/usr/bin/env python3
"""Require an identical frame/backfill history with and without the observer."""
import hashlib
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
plain = json.loads((root / 'plain.json').read_text())
observed = json.loads((root / 'observed.json').read_text())
if not any(frames >= 1000 and backfilled == frames for _, frames, backfilled in plain):
    raise SystemExit('System checkpoint threshold was not crossed')
if plain != observed:
    raise SystemExit('Observer changed historical autocheckpoint behavior')
events = [json.loads(line) for line in (root / 'snapshots/events.jsonl').read_text().splitlines()]
checkpoints = [event for event in events if event['kind'] == 'autocheckpoint']
if not checkpoints or any(event['threshold'] != 1000 or event['frames'] < 1000 or event['result'] != 0 for event in checkpoints):
    raise SystemExit('Original threshold was not exercised successfully')
proof = {'threshold': 1000, 'commitsCompared': len(plain), 'frameAndBackfillHistoryMatches': True, 'historySHA256': hashlib.sha256(json.dumps(plain).encode()).hexdigest(), 'checkpointEvents': checkpoints}
Path(sys.argv[2]).write_text(json.dumps(proof, indent=2) + '\n')
print(json.dumps(proof, indent=2))
