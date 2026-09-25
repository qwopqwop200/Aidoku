#!/usr/bin/env python3
"""Loopback HTTP/1.1 fixture: aggregate fair sharing or independent per-flow rates.
No third-party dependencies; PNG data is identical for every image request.
"""
import argparse, asyncio, json, struct, time, urllib.parse, zlib


def png():
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data))
    rows = b''.join(b'\0' + bytes(v for x in range(64) for v in (x * 4, y * 4, (x ^ y) * 4, 255)) for y in range(64))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', 64, 64, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


class Server:
    def __init__(self, rate, sharing="aggregate"):
        self.rate, self.flows, self.records = rate, [], []
        self.sharing = sharing
        self.payload = png()

    async def scheduler(self):
        tick = .01
        while True:
            await asyncio.sleep(tick)
            active = [flow for flow in self.flows if not flow['done'].is_set()]
            if not active:
                continue
            divisor = len(active) if self.sharing == "aggregate" else 1
            amount = max(1, int(self.rate * tick / divisor))
            for flow in active:
                record = flow['record']
                try:
                    end = min(flow['offset'] + amount, len(flow['data']))
                    flow['writer'].write(flow['data'][flow['offset']:end])
                    await flow['writer'].drain()
                    record['bytes'] += end - flow['offset']
                    flow['offset'] = end
                    if end == len(flow['data']):
                        record['completed'] = time.monotonic()
                        flow['done'].set()
                except (ConnectionError, BrokenPipeError):
                    record['cancelled'] = time.monotonic()
                    flow['done'].set()

    async def handle(self, reader, writer):
        flow = None
        try:
            header = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 10)
            path = header.split(b' ', 2)[1].decode()
            parsed = urllib.parse.urlsplit(path)
            params = urllib.parse.parse_qs(parsed.query)
            run = params.get('run', [''])[0]
            if parsed.path in ('/health', '/stats'):
                records = [r for r in self.records if not run or r['run'] == run]
                body = json.dumps({'rateBytesPerSecond': self.rate, 'sharing': self.sharing, 'records': records}).encode()
                writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
                await writer.drain()
                return
            size = min(4 * 1024 * 1024, max(len(self.payload), int(params.get('bytes', [262144])[0])))
            data = self.payload + b'\0' * (size - len(self.payload))
            record = {'run': run, 'kind': params.get('kind', ['reader'])[0], 'id': params.get('id', [''])[0], 'started': time.monotonic(), 'bytes': 0}
            self.records.append(record)
            writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: ' + str(size).encode() + b'\r\n\r\n')
            await writer.drain()
            flow = {'writer': writer, 'record': record, 'data': data, 'offset': 0, 'done': asyncio.Event()}
            self.flows.append(flow)
            completion = asyncio.create_task(flow['done'].wait())
            disconnect = asyncio.create_task(reader.read())
            done, _ = await asyncio.wait([completion, disconnect], return_when=asyncio.FIRST_COMPLETED)
            if disconnect in done and not flow['done'].is_set():
                record['cancelled'] = time.monotonic()
                flow['done'].set()
            completion.cancel()
            disconnect.cancel()
        except (ConnectionError, asyncio.IncompleteReadError, asyncio.TimeoutError):
            pass
        finally:
            if flow:
                flow['done'].set()
                self.flows.remove(flow)
                print(json.dumps(flow['record']), flush=True)
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8766)
    parser.add_argument('--rate', type=int, default=1048576)
    parser.add_argument('--sharing', choices=('aggregate', 'per-flow'), default='aggregate')
    args = parser.parse_args()
    fixture = Server(args.rate, args.sharing)
    scheduler = asyncio.create_task(fixture.scheduler())
    server = await asyncio.start_server(fixture.handle, '127.0.0.1', args.port)
    print(json.dumps({'ready': True, 'port': args.port, 'rate': args.rate, 'sharing': args.sharing}), flush=True)
    try:
        async with server:
            await server.serve_forever()
    finally:
        scheduler.cancel()


if __name__ == '__main__':
    asyncio.run(main())
