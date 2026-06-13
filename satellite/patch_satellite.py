import pathlib
import re

SATELLITE_PY = pathlib.Path(
    "/usr/local/lib/python3.11/site-packages/wyoming_satellite/satellite.py"
)

src = SATELLITE_PY.read_text()

OLD = "        run_pipeline = RunPipeline(start_stage=start_stage, end_stage=end_stage).event()\n        await self.event_to_server(run_pipeline)"
NEW = (
    "        # restart_on_end=True: HA auto-restarts the pipeline after TTS\n"
    "        # without waiting for another RunSatellite event.\n"
    "        run_pipeline = RunPipeline(start_stage=start_stage, end_stage=end_stage).event()\n"
    "        run_pipeline.data['restart_on_end'] = True\n"
    "        await self.event_to_server(run_pipeline)"
)

assert OLD in src, f"Patch target not found. Nearby context:\n{src[src.find('run_pipeline = RunPipeline')-100:src.find('run_pipeline = RunPipeline')+200]}"
patched = src.replace(OLD, NEW)
SATELLITE_PY.write_text(patched)
print("Patch applied: restart_on_end=True injected into RunPipeline event data")
