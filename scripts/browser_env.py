"""Minimal environment for browser checks; keeps an external browser endpoint."""
import os


def browser_env():
    # Sandboxed agents cannot start Chrome and connect to one started outside.
    env = {'PATH': os.environ.get('PATH', os.defpath)}
    endpoint = os.environ.get('PW_TEST_CONNECT_WS_ENDPOINT')
    if endpoint:
        env['PW_TEST_CONNECT_WS_ENDPOINT'] = endpoint
    return env
