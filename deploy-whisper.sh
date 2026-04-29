#!/bin/bash
set -euo pipefail

echo "===> Creating whisper directory"
mkdir -p /opt/whisper

echo "===> Creating Python venv"
python3 -m venv /opt/whisper/venv
source /opt/whisper/venv/bin/activate

echo "===> Installing faster-whisper + FastAPI"
pip install --upgrade pip
pip install faster-whisper fastapi uvicorn python-multipart

echo "===> Writing whisper_api.py"
cat > /opt/whisper/whisper_api.py << 'PYEOF'
"""Whisper STT API — GPU-accelerated speech-to-text via faster-whisper.
Listens on port 5501, accepts WAV file uploads at POST /transcribe.
"""
import io
import logging
from fastapi import FastAPI, UploadFile, File
from faster_whisper import WhisperModel

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("whisper-stt")

app = FastAPI(title="Sovereign Whisper STT")

# Load model on startup — uses GPU 0 (shared with Ollama)
# base.en is fast and accurate for English telephony audio
model = None

@app.on_event("startup")
async def load_model():
    global model
    logger.info("Loading Whisper model (base.en) on GPU...")
    model = WhisperModel("base.en", device="cuda", device_index=0, compute_type="float16")
    logger.info("Whisper model loaded and ready")

@app.get("/health")
async def health():
    return {"status": "ok", "service": "whisper-stt", "model": "base.en"}

@app.post("/transcribe")
async def transcribe(file: UploadFile = File(...)):
    """Accept a WAV file upload, return transcribed text."""
    audio_bytes = await file.read()
    logger.info(f"Received audio: {len(audio_bytes)} bytes, content_type={file.content_type}")

    # faster-whisper can read from bytes via BytesIO
    audio_stream = io.BytesIO(audio_bytes)
    segments, info = model.transcribe(audio_stream, beam_size=1, language="en", vad_filter=True)

    text = " ".join(segment.text.strip() for segment in segments)
    logger.info(f"Transcribed: {text[:100]}")
    return {"text": text, "language": info.language, "duration": round(info.duration, 2)}
PYEOF

echo "===> Creating systemd service"
cat > /etc/systemd/system/whisper-stt.service << 'SVCEOF'
[Unit]
Description=Whisper STT API Server (faster-whisper, GPU)
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/whisper
ExecStart=/opt/whisper/venv/bin/uvicorn whisper_api:app --host 0.0.0.0 --port 5501
Restart=always
RestartSec=5
Environment=CUDA_VISIBLE_DEVICES=0

[Install]
WantedBy=multi-user.target
SVCEOF

echo "===> Enabling and starting whisper-stt service"
systemctl daemon-reload
systemctl enable whisper-stt
systemctl start whisper-stt

echo "===> DONE — Whisper STT running on port 5501"
