#!/usr/bin/env python3
"""TCP proxy that delays every chunk, to exercise transfers over a high-latency link.

usage: latency-proxy.py LISTEN_PORT TARGET_PORT ONE_WAY_DELAY_MS
"""
import asyncio
import sys


async def pipe(reader, writer, delay):
    loop = asyncio.get_running_loop()
    queue = asyncio.Queue()

    async def drain():
        while True:
            due, data = await queue.get()
            if data is None:
                break
            await asyncio.sleep(max(0.0, due - loop.time()))
            writer.write(data)
            await writer.drain()
        writer.close()

    task = asyncio.create_task(drain())
    try:
        while data := await reader.read(65536):
            queue.put_nowait((loop.time() + delay, data))
    except ConnectionError:
        pass
    queue.put_nowait((0, None))
    await task


async def handle(client_reader, client_writer, target_port, delay):
    try:
        upstream_reader, upstream_writer = await asyncio.open_connection("127.0.0.1", target_port)
    except OSError:
        client_writer.close()
        return
    await asyncio.gather(
        pipe(client_reader, upstream_writer, delay),
        pipe(upstream_reader, client_writer, delay),
        return_exceptions=True,
    )


async def main(listen_port, target_port, delay_ms):
    delay = delay_ms / 1000.0
    server = await asyncio.start_server(
        lambda r, w: handle(r, w, target_port, delay), "127.0.0.1", listen_port
    )
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main(int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])))
