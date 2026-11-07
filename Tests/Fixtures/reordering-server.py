#!/usr/bin/env python3
"""Protocol test fixture: reorder responses and force legal short reads.
Not part of the app and never used for normal connections.
"""
import os
import select
import struct
import sys

stdin = sys.stdin.buffer
stdout = sys.stdout.buffer
SIZE = 900_000

def uint(value): return struct.pack('>I', value)
def string(value): return uint(len(value)) + value

def exact(count):
    data = b''
    while len(data) < count:
        part = os.read(0, count - len(data))
        if not part: raise EOFError
        data += part
    return data

def packet(): return exact(struct.unpack('>I', exact(4))[0])
def write(value): stdout.write(uint(len(value)) + value); stdout.flush()
def reply(value):
    kind = value[0]
    if kind == 1: return b'\x02' + uint(3)
    request = value[1:5]
    if kind == 3: return b'\x66' + request + string(b'handle')
    if kind == 7:
        return b'\x69' + request + uint(1 | 4 | 8) + struct.pack('>Q', SIZE) + uint(0o100644) + uint(1700000000) * 2
    if kind == 5:
        length = struct.unpack('>I', value[5:9])[0]
        position = 9 + length
        offset, count = struct.unpack('>QI', value[position:position + 12])
        count = min(count, SIZE - offset)
        if count == 65536: count //= 2
        data = bytes(i % 251 for i in range(offset, offset + count))
        return b'\x67' + request + string(data)
    if kind == 4: return b'\x65' + request + uint(0) + string(b'') + string(b'')
    raise RuntimeError(f'Unexpected request {kind}')

try:
    while True:
        batch = [packet()]
        # os.read is unbuffered, so select observes every pending request.
        while select.select([0], [], [], 0.002)[0]:
            batch.append(packet())
        for item in reversed(batch): write(reply(item))
except EOFError:
    pass
