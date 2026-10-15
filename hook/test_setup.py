"""Exercise hook merging in a disposable HOME, including repeat setup."""
import json
import os
from pathlib import Path
import subprocess

import pytest


SETUP = Path(__file__).resolve().parent.parent / 'setup.sh'


@pytest.mark.parametrize('legacy', [False, True])
def test_setup_registers_hooks_idempotently(tmp_path, legacy):
    (tmp_path / '.bashrc').touch()
    command = str(SETUP.parent / 'hook' / 'notification.sh')
    if legacy:
        (tmp_path / '.codex').mkdir()
        (tmp_path / '.codex' / 'hooks.json').write_text(json.dumps({'hooks': {
            'Stop': [{'hooks': [{'type': 'command', 'command': command}]}],
            'Other': [{'hooks': [{'command': 'keep-this'}]}],
        }}))
    env = dict(os.environ, HOME=str(tmp_path))
    for _ in range(2):
        result = subprocess.run(['bash', str(SETUP)], env=env, input='\n\n\n\n',
                                text=True, capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr
    assert not (tmp_path / '.gemini').exists()
    for directory, filename, agent, events in [
        ('.claude', 'settings.json', 'claude', ['UserPromptSubmit', 'Stop']),
        ('.codex', 'hooks.json', 'codex', ['UserPromptSubmit', 'Stop']),
    ]:
        hooks = json.loads((tmp_path / directory / filename).read_text())['hooks']
        for event in events:
            commands = [hook['command'] for entry in hooks[event] for hook in entry['hooks']]
            expected = command if legacy and agent == 'codex' and event == 'Stop' else command + ' --agent ' + agent
            assert commands == [expected]
        if legacy and agent == 'codex':
            assert hooks['Other'][0]['hooks'][0]['command'] == 'keep-this'


@pytest.mark.parametrize('existing', [False, True])
def test_setup_registers_agy_flat_hooks_without_duplicates(tmp_path, existing):
    (tmp_path / '.bashrc').touch()
    gemini = tmp_path / '.gemini'
    gemini.mkdir()
    path = gemini / 'config' / 'hooks.json'
    kept = {'Stop': [{'type': 'command', 'command': 'keep-existing'}]}
    if existing:
        path.parent.mkdir()
        path.write_text(json.dumps({'other-hook': kept, 'prompt-relay': {
            'Other': [{'type': 'command', 'command': 'keep-other-event'}],
            'Stop': [{'type': 'command', 'command': 'keep-other-handler'}],
        }}))
    env = dict(os.environ, HOME=str(tmp_path))
    for _ in range(2):
        result = subprocess.run(['bash', str(SETUP)], env=env, input='\n\n\n\n',
                                text=True, capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr
        assert str(path) in result.stdout
    settings = json.loads(path.read_text())
    for event in ('PreInvocation', 'Stop'):
        command = str(SETUP.parent / 'hook' / 'notification.sh') + ' --agent agy --event ' + event
        handlers = settings['prompt-relay'][event]
        assert handlers.count({'type': 'command', 'command': command, 'timeout': 10}) == 1
        assert all('hooks' not in handler and 'matcher' not in handler for handler in handlers)
    if existing:
        assert settings['other-hook'] == kept
        assert settings['prompt-relay']['Other'][0]['command'] == 'keep-other-event'
        assert settings['prompt-relay']['Stop'][0]['command'] == 'keep-other-handler'
