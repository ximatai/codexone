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
    for field in ("previous_response_id", "generate"):
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
            if op == "close":
                return
            if op == "multi":
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
                    if result["type"] == "response.created":
                        result = event(sock)
                        assert result["type"] == "response.completed"
            print(json.dumps(result), flush=True)
    finally:
        sock.close()


if __name__ == '__main__':
    main()
