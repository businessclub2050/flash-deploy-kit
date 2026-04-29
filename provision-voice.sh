#!/usr/bin/env bash
#
# Voice VM Provisioning Script — VM 103
# Target: Debian 13 (Trixie) on Proxmox VE (Q35/OVMF, no GPUs)
#
# ARCHITECTURE: Tailscale Funnel + Twilio Media Streams (NO Asterisk, NO SIP)
#
#   Twilio calls your phone number → hits webhook URL via Tailscale Funnel →
#   returns TwiML with <Connect><Stream> → bidirectional WebSocket audio →
#   Whisper STT (VM 201) → LangGraph brain (VM 102) → Piper TTS (this VM) →
#   audio back to caller over WebSocket.
#
#   No port forwards. No public IP exposure. Tailscale's edge servers handle
#   inbound HTTPS/WSS. Your OPNsense stays completely dark.
#
# PREREQUISITES:
#   1. Create VM 103 on the hypervisor (run setup-voice-vm.sh create on the hypervisor first)
#   2. Install Debian 13 via Proxmox noVNC console:
#      - Guided partitioning → "All files in one partition"
#      - Root password: <set during Debian install>
#      - Skip non-root user creation
#      - Select SSH server only (no desktop)
#   3. After Debian install, on the hypervisor:
#        qm set 103 --delete ide2 --boot order=scsi0
#   4. Set static IP via console if DHCP didn't assign:
#        See setup-voice-vm.sh output for ifconfig commands
#   5. Copy this script from the hypervisor and run as root:
#        scp /root/provision-voice.sh root@10.42.0.103:/root/
#        ssh root@10.42.0.103
#        chmod +x /root/provision-voice.sh
#        /root/provision-voice.sh
#
# WHAT GETS INSTALLED:
#   - Python 3 + FastAPI + WebSockets (Twilio Media Streams handler)
#   - Piper TTS (text-to-speech, CPU-only, sub-second latency)
#   - Tailscale + Funnel (public HTTPS endpoint for Twilio webhooks)
#   - Static IP 10.42.0.103/24, SSH key auth
#
# WHAT IS NOT INSTALLED (no GPU on this VM):
#   - No Whisper STT (runs on VM 201 with GPU for speed)
#   - No Ollama, ComfyUI, LangGraph
#   - No Asterisk (not needed — Twilio handles PSTN via webhook + WebSocket)
#
# VOICE PIPELINE (Tailscale Funnel approach):
#   Phone call → Twilio → HTTPS webhook (Tailscale Funnel → this VM)
#     → TwiML response starts bidirectional WebSocket audio stream
#     → audio chunks → Whisper STT API on VM 201 (:5501) → text
#     → text → LangGraph API on VM 102 (:8000) → response text
#     → response text → Piper TTS on this VM (:5500) → μ-law audio
#     → audio back to caller over the same WebSocket
#
set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
STATIC_IP="10.42.0.103"
GATEWAY="10.42.0.1"
DNS="10.42.0.1"
INTERFACE="ens18"
WHISPER_API="http://10.42.0.100:5501"
LANGGRAPH_API="http://10.42.0.102:8000"
PIPER_PORT=5500
VOICE_SERVER_PORT=8443

# SSH public keys (the hypervisor host + workstation)
HYPERVISOR_PUBKEY="ssh-rsa AAAA...REPLACE_WITH_YOUR_PUBKEY... user@host"
WORKSTATION_PUBKEY="ssh-ed25519 AAAA...REPLACE_WITH_YOUR_PUBKEY... user@host"

log() { echo -e "\n===> $1\n"; }

# ============================================================================
# 1. Base system
# ============================================================================
log "Updating base system"
apt-get update
apt-get upgrade -y

log "Installing base packages"
apt-get install -y \
    build-essential \
    git curl wget htop tmux gnupg lsb-release \
    ca-certificates \
    python3 python3-pip python3-venv \
    sox libsox-fmt-all \
    qemu-guest-agent

systemctl enable --now qemu-guest-agent

# ============================================================================
# 2. Piper TTS (CPU-only text-to-speech)
# ============================================================================
log "Installing Piper TTS"

PIPER_DIR="/opt/piper"
mkdir -p "${PIPER_DIR}"

# Download Piper binary
PIPER_VERSION="2023.11.14-2"
PIPER_URL="https://github.com/rhasspy/piper/releases/download/${PIPER_VERSION}/piper_linux_x86_64.tar.gz"
curl -fsSL "${PIPER_URL}" | tar -xz -C "${PIPER_DIR}" --strip-components=1

# Download a good English voice (Amy, medium quality — natural sounding)
VOICE_DIR="${PIPER_DIR}/voices"
mkdir -p "${VOICE_DIR}"
curl -fsSL -o "${VOICE_DIR}/en_US-amy-medium.onnx" \
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx"
curl -fsSL -o "${VOICE_DIR}/en_US-amy-medium.onnx.json" \
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/amy/medium/en_US-amy-medium.onnx.json"

# Create Python venv for Piper HTTP API wrapper
python3 -m venv "${PIPER_DIR}/venv"
"${PIPER_DIR}/venv/bin/pip" install fastapi uvicorn

# Create Piper HTTP API server
cat > "${PIPER_DIR}/piper_api.py" << 'PYEOF'
"""
Piper TTS HTTP API
POST /tts       {"text": "Hello"} → returns WAV audio
POST /tts/mulaw {"text": "Hello"} → returns raw μ-law 8kHz audio (for Twilio)
GET  /health    → {"status": "ok"}
"""
import subprocess
import tempfile
import os
import struct
from fastapi import FastAPI
from fastapi.responses import Response
from pydantic import BaseModel

app = FastAPI(title="Piper TTS API")

PIPER_BIN = "/opt/piper/piper"
VOICE_MODEL = "/opt/piper/voices/en_US-amy-medium.onnx"


class TTSRequest(BaseModel):
    text: str


def wav_to_mulaw_8k(wav_bytes):
    """Convert WAV to 8kHz μ-law raw audio (Twilio's native format).
    Piper outputs 22050Hz 16-bit PCM. We downsample and encode to μ-law."""
    # Skip WAV header (44 bytes)
    pcm_data = wav_bytes[44:]
    # Parse as 16-bit signed PCM
    samples = struct.unpack(f"<{len(pcm_data)//2}h", pcm_data)

    # Downsample from 22050 to 8000 Hz (simple linear interpolation)
    ratio = 22050 / 8000
    resampled = []
    i = 0.0
    while int(i) < len(samples):
        resampled.append(samples[int(i)])
        i += ratio

    # Encode to μ-law (ITU-T G.711)
    BIAS = 0x84
    CLIP = 32635
    mulaw_bytes = bytearray()
    for sample in resampled:
        sign = 0
        if sample < 0:
            sign = 0x80
            sample = -sample
        if sample > CLIP:
            sample = CLIP
        sample += BIAS
        exponent = 7
        for exp_val in [0x4000, 0x2000, 0x1000, 0x0800, 0x0400, 0x0200, 0x0100]:
            if sample >= exp_val:
                break
            exponent -= 1
        mantissa = (sample >> (exponent + 3)) & 0x0F
        mulaw_byte = ~(sign | (exponent << 4) | mantissa) & 0xFF
        mulaw_bytes.append(mulaw_byte)

    return bytes(mulaw_bytes)


@app.post("/tts")
def text_to_speech(req: TTSRequest):
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        out_path = f.name
    try:
        proc = subprocess.run(
            [PIPER_BIN, "--model", VOICE_MODEL, "--output_file", out_path],
            input=req.text, capture_output=True, text=True, timeout=30,
        )
        if proc.returncode != 0:
            return Response(content=f"Piper error: {proc.stderr}", status_code=500)
        with open(out_path, "rb") as f:
            audio = f.read()
        return Response(content=audio, media_type="audio/wav")
    finally:
        if os.path.exists(out_path):
            os.unlink(out_path)


@app.post("/tts/mulaw")
def text_to_speech_mulaw(req: TTSRequest):
    """Return raw 8kHz μ-law audio for Twilio Media Streams."""
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        out_path = f.name
    try:
        proc = subprocess.run(
            [PIPER_BIN, "--model", VOICE_MODEL, "--output_file", out_path],
            input=req.text, capture_output=True, text=True, timeout=30,
        )
        if proc.returncode != 0:
            return Response(content=f"Piper error: {proc.stderr}", status_code=500)
        with open(out_path, "rb") as f:
            wav_data = f.read()
        mulaw_data = wav_to_mulaw_8k(wav_data)
        return Response(content=mulaw_data, media_type="audio/basic")
    finally:
        if os.path.exists(out_path):
            os.unlink(out_path)


@app.get("/health")
def health():
    return {"status": "ok", "voice": "en_US-amy-medium"}
PYEOF

# Create systemd service for Piper API
cat > /etc/systemd/system/piper-tts.service << EOF
[Unit]
Description=Piper TTS API Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${PIPER_DIR}
ExecStart=${PIPER_DIR}/venv/bin/uvicorn piper_api:app --host 0.0.0.0 --port ${PIPER_PORT}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable piper-tts

# ============================================================================
# 3. Voice server (Twilio webhook + Media Streams WebSocket handler)
# ============================================================================
log "Setting up Twilio voice server"

VOICE_SRV="/opt/voice-server"
mkdir -p "${VOICE_SRV}"

python3 -m venv "${VOICE_SRV}/venv"
"${VOICE_SRV}/venv/bin/pip" install fastapi uvicorn websockets httpx

cat > "${VOICE_SRV}/voice_server.py" << 'PYEOF'
"""
Twilio Voice Server — handles webhooks and Media Streams WebSocket.

Endpoints:
  POST /voice          — Twilio webhook: returns TwiML to start Media Stream
  WS   /media-stream   — bidirectional WebSocket: receives caller audio,
                          sends AI audio back
  GET  /health         — health check

Call flow:
  1. Twilio calls POST /voice when someone dials your number
  2. We return TwiML: <Connect><Stream url="wss://this-host/media-stream"/>
  3. Twilio opens a WebSocket to /media-stream
  4. We receive audio chunks (μ-law 8kHz), buffer until silence
  5. Send buffered audio to Whisper STT (VM 201) → text
  6. Send text to LangGraph (VM 102) → AI response text
  7. Send response text to Piper TTS (this VM) → μ-law audio
  8. Send μ-law audio chunks back over WebSocket → caller hears AI
  9. Loop until caller hangs up or AI says goodbye
"""
import asyncio
import base64
import json
import os
import struct
import logging

from fastapi import FastAPI, WebSocket, Request
from fastapi.responses import Response
import httpx

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("voice-server")

app = FastAPI(title="Sovereign Voice Server")

# Configuration from environment
WHISPER_API = os.environ.get("WHISPER_API", "http://10.42.0.100:5501")
LANGGRAPH_API = os.environ.get("LANGGRAPH_API", "http://10.42.0.102:8000")
PIPER_API = os.environ.get("PIPER_API", "http://127.0.0.1:5500")
FUNNEL_HOST = os.environ.get("FUNNEL_HOST", "voice.your-tailnet.ts.net")


@app.post("/voice")
async def voice_webhook(request: Request):
    """Twilio calls this when someone dials your number.
    Returns TwiML that starts a bidirectional Media Stream."""
    twiml = f"""<?xml version="1.0" encoding="UTF-8"?>
<Response>
    <Say voice="alice">Please wait while I connect you to the AI assistant.</Say>
    <Connect>
        <Stream url="wss://{FUNNEL_HOST}/media-stream" />
    </Connect>
</Response>"""
    return Response(content=twiml, media_type="application/xml")


@app.websocket("/media-stream")
async def media_stream(ws: WebSocket):
    """Bidirectional WebSocket for Twilio Media Streams.

    Twilio sends JSON messages with base64-encoded μ-law audio.
    We accumulate audio, detect silence, transcribe, get AI response,
    synthesize speech, and send audio chunks back.
    """
    await ws.accept()
    logger.info("Media Stream WebSocket connected")

    stream_sid = None
    audio_buffer = bytearray()
    silence_threshold = 50  # consecutive silent frames → process (50 × 20ms = 1s)
    silence_count = 0
    conversation_history = [
        {
            "role": "system",
            "content": (
                "You are a helpful AI phone assistant. Keep responses concise "
                "and conversational — the caller is listening, not reading. "
                "Limit responses to 2-3 sentences. If the conversation is done, "
                "end with 'Goodbye.'"
            ),
        }
    ]
    max_turns = 10
    turn_count = 0
    greeting_sent = False

    try:
        async for message in ws.iter_text():
            data = json.loads(message)
            event = data.get("event")

            if event == "start":
                stream_sid = data["start"]["streamSid"]
                logger.info(f"Stream started: {stream_sid}")

                # Send greeting immediately
                if not greeting_sent:
                    greeting_sent = True
                    greeting = "Hello, this is the Sovereign AI assistant. How can I help you?"
                    await send_tts_to_caller(ws, stream_sid, greeting)

            elif event == "media":
                # Twilio sends base64 μ-law audio chunks (~20ms, 160 bytes each)
                payload = base64.b64decode(data["media"]["payload"])
                audio_buffer.extend(payload)

                # Simple silence detection: μ-law silence bytes are 0xFF/0x7F
                is_silent = all(b in (0xFF, 0x7F, 0xFE, 0x7E) for b in payload)
                if is_silent:
                    silence_count += 1
                else:
                    silence_count = 0

                # Process when we have speech + 1 second of silence
                if (
                    len(audio_buffer) > 3200  # at least 0.4s of audio
                    and silence_count >= silence_threshold
                    and turn_count < max_turns
                ):
                    turn_count += 1
                    audio_data = bytes(audio_buffer)
                    audio_buffer.clear()
                    silence_count = 0

                    # STT → AI → TTS → send back
                    await process_turn(
                        ws, stream_sid, audio_data, conversation_history
                    )

                    # Check if AI said goodbye
                    if (
                        conversation_history
                        and conversation_history[-1].get("role") == "assistant"
                        and "goodbye" in conversation_history[-1]["content"].lower()
                    ):
                        logger.info("AI said goodbye, ending call")
                        break

            elif event == "stop":
                logger.info("Stream stopped")
                break

    except Exception as e:
        logger.error(f"WebSocket error: {e}")
    finally:
        logger.info(f"Call ended after {turn_count} turns")


async def process_turn(ws, stream_sid, audio_data, conversation_history):
    """Process one conversation turn: STT → AI → TTS → send audio."""

    # 1. Speech-to-Text (Whisper on VM 201)
    user_text = await speech_to_text(audio_data)
    if not user_text.strip():
        logger.info("Empty transcription, skipping turn")
        return

    logger.info(f"Caller said: {user_text}")

    # 2. Get AI response (LangGraph on VM 102)
    ai_response = await get_ai_response(user_text, conversation_history)
    logger.info(f"AI response: {ai_response}")

    # Update conversation history
    conversation_history.append({"role": "user", "content": user_text})
    conversation_history.append({"role": "assistant", "content": ai_response})

    # 3. TTS → send audio back to caller
    await send_tts_to_caller(ws, stream_sid, ai_response)


async def speech_to_text(mulaw_audio: bytes) -> str:
    """Send μ-law audio to Whisper STT API, return transcribed text.
    Wraps raw μ-law in a WAV header for the Whisper API."""

    # Create minimal WAV header for 8kHz μ-law mono
    num_samples = len(mulaw_audio)
    wav_header = struct.pack(
        "<4sI4s4sIHHIIHH4sI",
        b"RIFF",
        36 + num_samples,
        b"WAVE",
        b"fmt ",
        18,      # fmt chunk size (18 for non-PCM)
        7,       # format: μ-law
        1,       # channels: mono
        8000,    # sample rate
        8000,    # byte rate
        1,       # block align
        8,       # bits per sample
        b"data",
        num_samples,
    )
    wav_data = wav_header + mulaw_audio

    async with httpx.AsyncClient(timeout=30.0) as client:
        files = {"file": ("audio.wav", wav_data, "audio/wav")}
        resp = await client.post(f"{WHISPER_API}/transcribe", files=files)
        resp.raise_for_status()
        result = resp.json()
        return result.get("text", "")


async def get_ai_response(user_text: str, conversation_history: list) -> str:
    """Send text to LangGraph API, return AI response text."""
    messages = conversation_history + [{"role": "user", "content": user_text}]
    payload = {
        "model": "sovereign-node",
        "messages": messages,
        "stream": False,
    }
    async with httpx.AsyncClient(timeout=120.0) as client:
        resp = await client.post(
            f"{LANGGRAPH_API}/v1/chat/completions", json=payload,
        )
        resp.raise_for_status()
        result = resp.json()
        return result["choices"][0]["message"]["content"]


async def send_tts_to_caller(ws: WebSocket, stream_sid: str, text: str):
    """Convert text to μ-law audio via Piper and send to Twilio over WebSocket."""
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(f"{PIPER_API}/tts/mulaw", json={"text": text})
        resp.raise_for_status()
        mulaw_audio = resp.content

    # Send in 160-byte chunks (20ms at 8kHz μ-law) — real-time pacing
    chunk_size = 160
    for i in range(0, len(mulaw_audio), chunk_size):
        chunk = mulaw_audio[i : i + chunk_size]
        payload = base64.b64encode(chunk).decode("ascii")
        msg = json.dumps({
            "event": "media",
            "streamSid": stream_sid,
            "media": {"payload": payload},
        })
        await ws.send_text(msg)
        # Pace to real-time (~20ms per chunk)
        await asyncio.sleep(0.02)


@app.get("/health")
def health():
    return {"status": "ok", "service": "sovereign-voice-server"}
PYEOF

# Environment file
cat > "${VOICE_SRV}/.env" << EOF
WHISPER_API=${WHISPER_API}
LANGGRAPH_API=${LANGGRAPH_API}
PIPER_API=http://127.0.0.1:${PIPER_PORT}
FUNNEL_HOST=voice.your-tailnet.ts.net
EOF

# Systemd service — listens on localhost only (Funnel handles TLS + public exposure)
cat > /etc/systemd/system/voice-server.service << EOF
[Unit]
Description=Sovereign Voice Server (Twilio Media Streams)
After=network.target piper-tts.service tailscaled.service
Wants=piper-tts.service

[Service]
Type=simple
User=root
WorkingDirectory=${VOICE_SRV}
EnvironmentFile=${VOICE_SRV}/.env
ExecStart=${VOICE_SRV}/venv/bin/uvicorn voice_server:app --host 127.0.0.1 --port ${VOICE_SERVER_PORT}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable voice-server

# ============================================================================
# 4. Tailscale + Funnel
# ============================================================================
log "Installing Tailscale"

curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg | \
    tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list | \
    tee /etc/apt/sources.list.d/tailscale.list

apt-get update
apt-get install -y tailscale
systemctl enable tailscaled

# ============================================================================
# 5. Network — static IP
# ============================================================================
log "Configuring static network"

cat > /etc/network/interfaces << EOF
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

allow-hotplug ${INTERFACE}
iface ${INTERFACE} inet static
        address ${STATIC_IP}/24
        gateway ${GATEWAY}
        dns-nameservers ${DNS}
EOF

# ============================================================================
# 6. SSH setup
# ============================================================================
log "Configuring SSH"

mkdir -p /root/.ssh
chmod 700 /root/.ssh
cat > /root/.ssh/authorized_keys << EOF
${HYPERVISOR_PUBKEY}
${WORKSTATION_PUBKEY}
EOF
chmod 600 /root/.ssh/authorized_keys

cat > /etc/rc.local << 'RCEOF'
#!/bin/bash
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  dpkg-reconfigure openssh-server
  systemctl restart sshd
fi
RCEOF
chmod +x /etc/rc.local

# ============================================================================
# 7. Final cleanup
# ============================================================================
log "Final cleanup"

apt-get clean
rm -rf /var/lib/apt/lists/*

journalctl --vacuum-time=1d
find /var/log -type f -name "*.gz" -delete
find /var/log -type f -name "*.old" -delete
find /var/log -type f -name "*.[0-9]" -delete
cat /dev/null > /var/log/wtmp
cat /dev/null > /var/log/btmp
cat /dev/null > /root/.bash_history
unset HISTFILE

rm -f /etc/ssh/ssh_host_*

log "DONE — Voice VM provisioning complete!"
echo ""
echo "============================================================"
echo " POST-PROVISIONING STEPS (do these after reboot)"
echo "============================================================"
echo ""
echo "  1. Reboot:"
echo "       shutdown -r now"
echo ""
echo "  2. Verify Piper TTS:"
echo "       curl http://localhost:${PIPER_PORT}/health"
echo ""
echo "  3. Join Tailscale (approve the auth URL in your browser):"
echo "       tailscale up --accept-dns=false --hostname=voice"
echo ""
echo "  4. Enable Tailscale Funnel (exposes voice server to internet via Tailscale):"
echo "       tailscale funnel ${VOICE_SERVER_PORT}"
echo ""
echo "     This gives you a public URL like:"
echo "       https://voice.your-tailnet.ts.net"
echo ""
echo "     To run Funnel in background (persists across reboots):"
echo "       tailscale funnel --bg ${VOICE_SERVER_PORT}"
echo ""
echo "  5. Verify Funnel is working (from ANY device, even outside your network):"
echo "       curl https://voice.your-tailnet.ts.net/health"
echo "       # Should return: {\"status\":\"ok\",\"service\":\"sovereign-voice-server\"}"
echo ""
echo "  6. Start voice server:"
echo "       systemctl start voice-server"
echo ""
echo "  7. Configure Twilio webhook (in browser):"
echo "       a. Go to https://console.twilio.com → Phone Numbers → your number"
echo "       b. Under 'A call comes in':"
echo "          - Keep: Webhook"
echo "          - URL: https://voice.your-tailnet.ts.net/voice"
echo "          - HTTP: HTTP POST"
echo "       c. Save"
echo ""
echo "  8. Test: Call your Twilio number from a verified caller ID"
echo "       (Trial accounts only accept calls from verified numbers)"
echo "       The AI should answer and have a conversation!"
echo ""
echo "  NOTE: Whisper STT must be running on VM 201 (:5501) for speech"
echo "  recognition to work. That's a separate deployment step."
echo ""
