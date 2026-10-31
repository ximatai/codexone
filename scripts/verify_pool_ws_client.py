#!/usr/bin/env python3
"""Independent bounded socket client for the synthetic pool's persistent WS tests."""
import json
import sys
from verify_websocket import dial, send, receive


def event(sock):
    opcode, body = receive(sock)
    assert opcode == 1
    return json.loads(body)


def create(command, lane=None):
    value = {"type": "response.create", "model": "synthetic-text", "input": command.get("input", "synthetic")}
    for field in ("previous_response_id", "generate", "tools", "store", "max_output_tokens", "temperature", "top_p",
                  "truncation", "metadata", "prompt_cache_retention", "service_tier", "include"):
        if field in command:
            value[field] = command[field]
    if lane:
        value["stream_id"] = lane
    return value


def main():
    sock = dial(int(sys.argv[1]), token=sys.argv[2])
    try:
        print('{"ready":true}', flush=True)
        for line in sys.stdin:
            assert len(line) <= 4096
            command = json.loads(line)
            op = command.get("op", "turn")
            if op == "compatibility":
                send(sock, dict(type='synthetic.future', payload='synthetic-private-control-body'), masked=True)
                assert event(sock)['status'] == 400
                send(sock, create({}), masked=True)
                first = event(sock); done = event(sock)
                assert done['type'] == 'response.completed'
                send(sock, dict(type='synthetic.future', payload='synthetic-private-control-body'), masked=True)
                assert event(sock)['type'] == 'synthetic.echo'
                for prompt in ('cancel-before', 'cancel-after', 'drain'):
                    send(sock, create(dict(input=prompt), prompt), masked=True)
                    started = event(sock)
                    rid = started['response']['id']
                    send(sock, dict(type='response.interrupt', response_id=rid, mode='discard_partial_items'), masked=True)
                    replies = [event(sock), event(sock)]
                    expected = ['response.completed', 'response.interrupt.accepted'] if prompt == 'cancel-after' else ['response.interrupt.accepted', 'response.completed']
                    assert [item['type'] for item in replies] == expected, replies
                    assert all(item['stream_id'] == prompt for item in replies)
                    send(sock, dict(type='response.interrupt', response_id=rid), masked=True)
                    assert event(sock)['type'] == 'response.interrupt.failed'
                send(sock, dict(type='synthetic.spawn'), masked=True)
                try:
                    assert receive(sock)[0] == 8
                except (EOFError, ConnectionResetError):
                    pass
                print('{"verified":true}', flush=True)
                continue
            if op == "close":
                return
            if op == "expect_close":
                if command.get("race"):
                    send(sock, create(command), masked=True)
                observed = []
                for _ in range(16):
                    opcode, body = receive(sock)
                    if opcode == 8:
                        assert body[:2] == b'\x03\xe8', body
                        break
                    assert opcode == 1
                    observed.append(json.loads(body)["type"])
                else:
                    raise AssertionError("No bounded normal close")
                result = {"closed": 1000, "events": observed}
            elif op == "multi":
                send(sock, create({"input": "hold"}, "slow"), masked=True)
                send(sock, create({}, "fast"), masked=True)
                events = [event(sock) for _ in range(4)]
                done = [e for e in events if e["type"] == "response.completed"]
                assert [e["stream_id"] for e in done] == ["fast", "slow"]
                result = {"lanes": 2}
            elif op == "receive":
                result = event(sock)
            else:
                send(sock, create(command, command.get("lane")), masked=True)
                if op == "send":
                    result = {"sent": True}
                else:
                    result = event(sock)
                    while result["type"] not in ["response.completed", "response.failed", "response.incomplete", "error"]:
                        result = event(sock)
            print(json.dumps(result), flush=True)
    finally:
        sock.close()


if __name__ == '__main__':
    main()
