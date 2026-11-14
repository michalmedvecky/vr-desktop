"""Fake Mac host for testing the WebXR client without a Mac.

Serves mac/Web over HTTPS and answers POST /offer like the real Swift app: it streams synthetic
"windows" (moving test patterns) into the browser's video transceivers and logs every message
that arrives on the "ctl" data channel.

    pip install aiortc aiohttp
    python tools/fake_mac.py                                  # https://localhost:8443
    python tools/fake_mac.py --relay http://localhost:8080 <room>  # host on the relay server
"""
import asyncio, json, os, ssl, subprocess, sys, tempfile, time
from fractions import Fraction

import numpy as np
from aiohttp import web
from aiortc import RTCPeerConnection, RTCSessionDescription, VideoStreamTrack
from av import VideoFrame

ROOT = os.path.join(os.path.dirname(__file__), '..', 'mac', 'Web')
WINDOWS = [
    {"id": 101, "title": "Terminál — zsh", "app": "Terminal", "width": 900, "height": 560},
    {"id": 202, "title": "GitHub – vr-desktop", "app": "Safari", "width": 1280, "height": 800},
    {"id": 303, "title": "Poznámky", "app": "Notes", "width": 700, "height": 700},
]
LOG = []
selected = [101, 202]


class PatternTrack(VideoStreamTrack):
    """Colored test pattern with a moving bar. size follows the assigned window."""
    def __init__(self, slot):
        super().__init__()
        self.slot = slot

    async def recv(self):
        pts, time_base = await self.next_timestamp()
        wid = selected[self.slot] if self.slot < len(selected) else 0
        info = next((w for w in WINDOWS if w["id"] == wid), {"width": 320, "height": 200})
        w, h = info["width"] // 2 * 2, info["height"] // 2 * 2
        img = np.zeros((h, w, 3), np.uint8)
        color = [(200, 60, 60), (60, 160, 60), (60, 90, 200), (180, 180, 60)][self.slot]
        img[:, :] = color
        x = int((time.time() * 200) % w)
        img[:, max(0, x - 10):x + 10] = 255
        img[: h // 10, :] = 30  # dark "title" strip at top so orientation is visible
        frame = VideoFrame.from_ndarray(img, format="rgb24")
        frame.pts, frame.time_base = pts, time_base
        return frame


pcs = set()


async def offer(request):
    params = await request.json()
    return web.json_response({"sdp": await answer_offer(params["sdp"])})


async def answer_offer(offer_sdp):
    pc = RTCPeerConnection()
    pcs.add(pc)

    @pc.on("datachannel")
    def on_dc(ch):
        def slots():
            return [selected[i] if i < len(selected) else 0 for i in range(4)]

        def send_all():
            ch.send(json.dumps({"type": "hello", "name": "FakeMac", "version": 1, "maxWindows": 4}))
            ch.send(json.dumps({"type": "windows", "windows": WINDOWS}))
            ch.send(json.dumps({"type": "slots", "slots": slots()}))

        if ch.readyState == "open":
            send_all()
        ch.on("open", send_all)

        @ch.on("message")
        def on_msg(msg):
            global selected
            m = json.loads(msg)
            LOG.append(m)
            print("ctl <-", m, flush=True)
            if m.get("type") == "select":
                selected = m["windowIds"][:4]
                ch.send(json.dumps({"type": "slots", "slots": slots()}))
            elif m.get("type") == "listWindows":
                ch.send(json.dumps({"type": "windows", "windows": WINDOWS}))

    await pc.setRemoteDescription(RTCSessionDescription(sdp=offer_sdp, type="offer"))
    for i, t in enumerate(pc.getTransceivers()):
        if t.kind == "video":
            t.direction = "sendonly"
            t.sender.replaceTrack(PatternTrack(i))
    await pc.setLocalDescription(await pc.createAnswer())
    return pc.localDescription.sdp


async def relay_host(server, room):
    """Act like the Mac app's RelayClient: connect to the relay as host and answer offers."""
    import aiohttp
    url = server.replace("https://", "wss://").replace("http://", "ws://").rstrip("/") + f"/ws?role=host&room={room}"
    async with aiohttp.ClientSession() as s:
        async with s.ws_connect(url) as ws:
            print("relay host connected", url, flush=True)
            async for msg in ws:
                m = json.loads(msg.data)
                if m.get("type") == "offer":
                    await ws.send_str(json.dumps({"type": "answer", "sdp": await answer_offer(m["sdp"]), "to": m["from"]}))


async def log(request):
    return web.json_response(LOG)


async def static(request):
    name = request.match_info.get("name") or "index.html"
    return web.FileResponse(os.path.join(ROOT, name))


def make_ssl():
    d = tempfile.mkdtemp()
    key, cert = os.path.join(d, "k.pem"), os.path.join(d, "c.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=fake", "-keyout", key, "-out", cert], check=True, capture_output=True)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    return ctx


app = web.Application()
app.router.add_post("/offer", offer)
app.router.add_get("/_log", log)
app.router.add_get("/", static)
app.router.add_get("/{name}", static)

if __name__ == "__main__":
    # python tools/fake_mac.py [port]                      -> local mode (HTTPS, POST /offer)
    # python tools/fake_mac.py --relay <server-url> <room> -> host on a relay server (server/)
    if len(sys.argv) > 1 and sys.argv[1] == "--relay":
        asyncio.run(relay_host(sys.argv[2], sys.argv[3]))
    else:
        web.run_app(app, port=int(sys.argv[1]) if len(sys.argv) > 1 else 8443, ssl_context=make_ssl())
