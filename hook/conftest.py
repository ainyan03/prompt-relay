"""Keep hook runtime artifacts and routing logs inside each test's directory."""
import pytest


@pytest.fixture(autouse=True)
def isolated_hook_paths(tmp_path, monkeypatch):
    monkeypatch.setenv('PROMPT_RELAY_RUNTIME_DIR', str(tmp_path / 'runtime'))
    monkeypatch.setenv('PROMPT_RELAY_LOG', str(tmp_path / 'logs' / 'hook.log'))
