#!/usr/bin/env python3
"""Wyoming protocol adapter for VOICEVOX TTS."""

import argparse
import asyncio
import io
import logging
import wave

import aiohttp
from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.error import Error
from wyoming.event import Event
from wyoming.info import Attribution, Describe, Info, TtsProgram, TtsVoice
from wyoming.server import AsyncEventHandler, AsyncServer
from wyoming.tts import Synthesize

_LOGGER = logging.getLogger(__name__)
_CHUNK_BYTES = 2048


async def _call_voicevox(
    session: aiohttp.ClientSession,
    base_url: str,
    text: str,
    speaker: int,
    speed_scale: float,
) -> bytes:
    """Two-step VOICEVOX synthesis: audio_query → synthesis."""
    async with session.post(
        f"{base_url}/audio_query",
        params={"text": text, "speaker": speaker},
        timeout=aiohttp.ClientTimeout(total=30),
    ) as resp:
        resp.raise_for_status()
        query = await resp.json()

    query["speedScale"] = speed_scale

    async with session.post(
        f"{base_url}/synthesis",
        params={"speaker": speaker},
        json=query,
        timeout=aiohttp.ClientTimeout(total=60),
    ) as resp:
        resp.raise_for_status()
        return await resp.read()


class VoicevoxHandler(AsyncEventHandler):
    def __init__(
        self,
        wyoming_info: Info,
        args: argparse.Namespace,
        session: aiohttp.ClientSession,
        *handler_args,
        **handler_kwargs,
    ) -> None:
        super().__init__(*handler_args, **handler_kwargs)
        self._info_event = wyoming_info.event()
        self._args = args
        self._session = session

    async def handle_event(self, event: Event) -> bool:
        if Describe.is_type(event.type):
            await self.write_event(self._info_event)
            return True

        if not Synthesize.is_type(event.type):
            return True

        synthesize = Synthesize.from_event(event)
        text = synthesize.text.strip()
        if not text:
            await self.write_event(AudioStart(rate=24000, width=2, channels=1).event())
            await self.write_event(AudioStop().event())
            return True

        try:
            wav_bytes = await _call_voicevox(
                self._session,
                self._args.voicevox_url,
                text,
                self._args.speaker,
                self._args.speed_scale,
            )

            with io.BytesIO(wav_bytes) as wav_io:
                with wave.open(wav_io, "rb") as wf:
                    rate = wf.getframerate()
                    width = wf.getsampwidth()
                    channels = wf.getnchannels()
                    pcm = wf.readframes(wf.getnframes())

            await self.write_event(
                AudioStart(rate=rate, width=width, channels=channels).event()
            )
            for i in range(0, len(pcm), _CHUNK_BYTES):
                await self.write_event(
                    AudioChunk(
                        rate=rate,
                        width=width,
                        channels=channels,
                        audio=pcm[i : i + _CHUNK_BYTES],
                    ).event()
                )
            await self.write_event(AudioStop().event())

        except Exception:
            _LOGGER.exception("VOICEVOX synthesis failed: %r", text)
            await self.write_event(Error(text="VOICEVOX synthesis error").event())

        return True


async def main(args: argparse.Namespace) -> None:
    wyoming_info = Info(
        tts=[
            TtsProgram(
                name="voicevox",
                description="VOICEVOX Japanese TTS",
                attribution=Attribution(
                    name="VOICEVOX Project",
                    url="https://voicevox.hiroshiba.jp/",
                ),
                installed=True,
                version=None,
                voices=[
                    TtsVoice(
                        name="ja_JP-voicevox",
                        description=f"VOICEVOX speaker {args.speaker}",
                        attribution=Attribution(
                            name="VOICEVOX Project",
                            url="https://voicevox.hiroshiba.jp/",
                        ),
                        installed=True,
                        languages=["ja", "ja-JP"],
                        version=None,
                    )
                ],
            )
        ]
    )

    connector = aiohttp.TCPConnector(limit=4)
    async with aiohttp.ClientSession(connector=connector) as session:
        _LOGGER.info("Waiting for VOICEVOX engine at %s ...", args.voicevox_url)
        while True:
            try:
                async with session.get(
                    f"{args.voicevox_url}/version",
                    timeout=aiohttp.ClientTimeout(total=5),
                ) as resp:
                    if resp.status == 200:
                        ver = (await resp.text()).strip().strip('"')
                        _LOGGER.info("VOICEVOX engine ready (version %s)", ver)
                        break
            except Exception:
                pass
            await asyncio.sleep(2)

        server = AsyncServer.from_uri(args.uri)
        _LOGGER.info(
            "wyoming-voicevox listening on %s (speaker=%d, speed=%.1f)",
            args.uri,
            args.speaker,
            args.speed_scale,
        )
        await server.run(
            lambda *a, **kw: VoicevoxHandler(wyoming_info, args, session, *a, **kw)
        )


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Wyoming adapter for VOICEVOX TTS")
    p.add_argument("--uri", default="tcp://0.0.0.0:10200", help="Wyoming server URI")
    p.add_argument(
        "--voicevox-url",
        default="http://voicevox-engine:50021",
        help="VOICEVOX engine base URL",
    )
    p.add_argument("--speaker", type=int, default=3, help="VOICEVOX speaker ID")
    p.add_argument("--speed-scale", type=float, default=1.0, help="Speaking speed (0.5–2.0)")
    p.add_argument("--debug", action="store_true")
    return p.parse_args()


if __name__ == "__main__":
    args = _parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    asyncio.run(main(args))
