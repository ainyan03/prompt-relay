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
    if legacy:
        (tmp_path / '.claude').mkdir()
        (tmp_path / '.claude' / 'settings.json').write_text(json.dumps({'hooks': {
            'Notification': [{'matcher': 'idle_prompt', 'hooks': [
                {'type': 'command', 'command': command},
                {'type': 'command', 'command': 'keep-notification'},
            ]}],
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
        if agent == 'claude':
            entries = hooks['Notification']
            for event in ('idle_prompt', 'permission_prompt'):
                assert sum(hook['command'] == command for entry in entries
                           if entry.get('matcher') == event for hook in entry['hooks']) == 1
            if legacy:
                assert entries[0]['hooks'][1]['command'] == 'keep-notification'
                assert entries[0]['matcher'] == 'idle_prompt'
        if legacy and agent == 'codex':
            assert hooks['Other'][0]['hooks'][0]['command'] == 'keep-this'


@pytest.mark.parametrize('existing', [False, True])
@pytest.mark.parametrize('approval_format', ['absent', 'flat', 'wrapped', 'mixed'])
def test_setup_registers_agy_event_specific_hooks_without_duplicates(tmp_path, existing, approval_format):
    (tmp_path / '.bashrc').touch()
    gemini = tmp_path / '.gemini'
    gemini.mkdir()
    path = gemini / 'config' / 'hooks.json'
    permission = str(SETUP.parent / 'hook' / 'permission-request.sh') + ' --agent agy'
    handler = {'type': 'command', 'command': permission, 'timeout': 10}
    wrapped = {'matcher': '', 'hooks': [handler]}
    unrelated = {'matcher': 'other_tool', 'hooks': [{'command': 'keep-other-approval'}]}
    kept = {'PreToolUse': [{'type': 'command', 'command': 'keep-approval'}],
            'Stop': [{'type': 'command', 'command': 'keep-existing'}]}
    pretool = [unrelated]
    if approval_format in ('flat', 'mixed'): pretool += [handler, handler]
    if approval_format in ('wrapped', 'mixed'): pretool += [wrapped]
    group = {'PreToolUse': pretool}
    if existing:
        group.update({'Other': [{'type': 'command', 'command': 'keep-other-event'}],
                      'Stop': [{'type': 'command', 'command': 'keep-other-handler'}]})
    fresh = not existing and approval_format == 'absent'
    if not fresh:
        path.parent.mkdir()
        path.write_text(json.dumps({'other-hook': kept, 'prompt-relay': group}))
    env = dict(os.environ, HOME=str(tmp_path))
    previous = None
    for _ in range(2):
        result = subprocess.run(['bash', str(SETUP)], env=env, input='\n\n\n\n',
                                text=True, capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr
        assert str(path) in result.stdout
        settings = json.loads(path.read_text())
        if previous is not None:
            assert settings == previous
        previous = settings
        assert settings['prompt-relay']['PreToolUse'] == ([wrapped] if fresh else [unrelated, wrapped])
        if not fresh:
            assert settings['other-hook'] == kept
        if existing:
            assert settings['prompt-relay']['Other'] == group['Other']
            assert settings['prompt-relay']['Stop'][0] == group['Stop'][0]
    for event in ('PreInvocation', 'Stop'):
        command = str(SETUP.parent / 'hook' / 'notification.sh') + ' --agent agy --event ' + event
        handlers = settings['prompt-relay'][event]
        assert handlers.count({'type': 'command', 'command': command, 'timeout': 10}) == 1
        assert all('hooks' not in item and 'matcher' not in item for item in handlers)


@pytest.mark.parametrize('matcher', ['permission_prompt|idle_prompt',
                                     '^(permission_prompt|idle_prompt)$',
                                     '^(idle_prompt|permission_prompt|other)$', ''])
def test_setup_preserves_equivalent_notification_matchers(tmp_path, matcher):
    (tmp_path / '.bashrc').touch()
    settings = tmp_path / '.claude' / 'settings.json'
    settings.parent.mkdir()
    command = str(SETUP.parent / 'hook' / 'notification.sh')
    entries = [{'matcher': matcher, 'hooks': [{'command': command}, {'command': 'keep-this'}]}]
    settings.write_text(json.dumps({'hooks': {'Notification': entries}}))
    for _ in range(2):
        result = subprocess.run(['bash', str(SETUP)], env=dict(os.environ, HOME=str(tmp_path)),
                                input='\n\n\n\n', text=True, capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr
    assert json.loads(settings.read_text())['hooks']['Notification'] == entries
