#!/usr/bin/env python3
"""Worker de rendu TTS : un process par moteur, le modele charge une fois.

Appele par le serveur MCP (`tts-mcp`) DANS l'interpreteur du moteur, donc
chaque moteur garde ses propres dependances sans contaminer les autres :

    <python-du-moteur> worker.py --engine phonon --serve

Modes :

  --serve          boucle JSONL sur stdin/stdout, garde le modele chaud
  --once <json>    un seul texte (JSON en argument ou sur stdin), puis sortie
  --job  <json>    script A|B en une passe, un wav par replique, reprise
  --voices         catalogue des voix du moteur, puis sortie

Requete de rendu :

    {"action":"say","text":...,"voice":...,"language":...,"speed":1.0,
     "out":"/chemin.wav","ref_audio":...,"ref_text":...}

Reponse : {"ok":true,"wav":...,"duration":..,"sr":..,"load_s":..,"gen_s":..,
           "rtf":..,"voice":..}
Erreur : {"ok":false,"error":"..."}
"""

import argparse
import json
import os
import re
import sys
import time
import wave

import numpy as np  # noqa: F401  (tous les environnements de moteur en ont)

SILENCE_S = 0.45

# Vocabulaire ferme des profils OmniVoice (le modele refuse la prose).
OMNI_PROFILES = [
    "female, young adult, high pitch",
    "female, middle-aged, moderate pitch",
    "female, elderly, low pitch",
    "male, young adult, moderate pitch",
    "male, middle-aged, moderate pitch",
    "male, elderly, low pitch",
    "female, whisper",
    "male, whisper",
]


def write16(path, audio, sr):
    """Ecrit un wav mono 16 bits normalise en crete (comme le banc d'essai)."""
    a = np.asarray(audio, dtype=np.float32).squeeze()
    peak = float(np.max(np.abs(a))) if a.size else 0.0
    if peak > 0:
        a = a / peak * 0.95
    pcm = (a * 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(int(sr))
        w.writeframes(pcm.tobytes())


def wav_duration(path):
    with wave.open(path, "rb") as w:
        return w.getnframes() / float(w.getframerate())


def env(name, default=None):
    v = os.environ.get(name)
    return v if v else default


# --------------------------------------------------------------- moteurs


class Engine:
    """Un moteur = un modele et une voix par appel."""

    name = "base"
    sample_rate = 24000
    gpu = False

    def __init__(self):
        self.load_s = 0.0

    def say(self, req):
        raise NotImplementedError

    def voices(self):
        return []

    def describe(self):
        return {
            "engine": self.name,
            "gpu": self.gpu,
            "load_s": round(self.load_s, 2),
            "sample_rate": self.sample_rate,
            "voices": self.voices(),
        }


class Phonon(Engine):
    """Phonon 31M (gradium, Apache-2.0) : anglais, CPU, rapide.

    Le catalogue (gradium/phonon-voices) couvre en/de/es/fr/pt, mais les voix
    non anglaises exigent le modele 40m-multilingual, gate sur Hugging Face :
    sans HF_TOKEN accepte, seul l'anglais est disponible.
    """

    name = "phonon"

    def __init__(self):
        super().__init__()
        import ptts

        self.ptts = ptts
        self.quant = env("TTS_PHONON_QUANT", "q8")
        self.models = json.loads(
            env(
                "TTS_PHONON_MODELS",
                '{"en": "hf://gradium/phonon-31m-en",'
                ' "multi": "hf://gradium/phonon-40m-multilingual"}',
            )
        )
        self.cache = {}
        self._voices = None

    def _tts(self, language):
        model = self.models.get(language) or self.models["multi"]
        key = (model, language)
        if key not in self.cache:
            t0 = time.time()
            t = self.ptts.TTS(model, lang=language, quant=self.quant)
            self.load_s += time.time() - t0
            self.cache[key] = t
        return self.cache[key]

    def say(self, req):
        tts = self._tts(req.get("language") or "en")
        audio = tts.synth(req["text"], voice=req.get("voice") or "Harper")
        return np.asarray(audio, dtype=np.float32), int(tts.sample_rate)

    def voices(self):
        if self._voices is None:
            self._voices = list(self.ptts.catalog_voices())
        return self._voices


class Kokoro(Engine):
    """Kokoro 82M v1.0 (hexgrad, Apache-2.0) : FR (1 voix) et EN, CPU."""

    name = "kokoro"
    lang_codes = {
        "en": "a",
        "en-us": "a",
        "en-gb": "b",
        "fr": "f",
        "es": "e",
        "it": "i",
        "pt": "p",
        "hi": "h",
        "ja": "j",
        "zh": "z",
    }
    prefix_lang = {
        "a": "en-us",
        "b": "en-gb",
        "e": "es",
        "f": "fr",
        "h": "hi",
        "i": "it",
        "j": "ja",
        "p": "pt",
        "z": "zh",
    }

    def __init__(self):
        super().__init__()
        from kokoro import KPipeline

        self.KPipeline = KPipeline
        self.cache = {}

    def _pipe(self, language):
        code = self.lang_codes.get(language or "en", "a")
        if code not in self.cache:
            t0 = time.time()
            self.cache[code] = self.KPipeline(lang_code=code)
            self.load_s += time.time() - t0
        return self.cache[code]

    def say(self, req):
        pipe = self._pipe(req.get("language"))
        voice = req.get("voice") or ("ff_siwis" if req.get("language") == "fr" else "af_heart")
        chunks = [
            np.asarray(a, dtype=np.float32)
            for _, _, a in pipe(req["text"], voice=voice, speed=float(req.get("speed") or 1.0))
        ]
        return np.concatenate(chunks), 24000

    def voices(self):
        root = env("TTS_KOKORO_VOICES_DIR")
        out = []
        if root and os.path.isdir(root):
            for f in sorted(os.listdir(root)):
                if f.endswith(".pt"):
                    stem = f[:-3]
                    out.append(
                        {
                            "name": stem,
                            "language": self.prefix_lang.get(stem[:1], "?"),
                            "gender": "F" if stem[1].startswith("f") else "M",
                        }
                    )
        return out


class Omni(Engine):
    """OmniVoice 0,6B (k2-fsa) : 600+ langues, GPU, poids CC-BY-NC.

    Pas de multi-locuteur : la voix est un profil du vocabulaire ferme
    OMNI_PROFILES, ou un clonage par wav de reference (`ref_audio`).
    """

    name = "omni"
    gpu = True

    def __init__(self):
        super().__init__()
        import torch

        from omnivoice.models.omnivoice import OmniVoice

        self.torch = torch
        t0 = time.time()
        self.model = OmniVoice.from_pretrained(
            env("TTS_OMNI_MODEL", "k2-fsa/OmniVoice"),
            device_map=env("TTS_OMNI_DEVICE", "cuda"),
            dtype=torch.float16,
        )
        self.load_s = time.time() - t0
        self.sample_rate = int(self.model.sampling_rate)

    def say(self, req):
        kw = {
            "language": req.get("language") or "fr",
            "num_step": int(req.get("num_step") or 24),
            "guidance_scale": float(req.get("guidance_scale") or 2.6),
            "speed": float(req.get("speed") or 1.10),
        }
        if req.get("ref_audio"):
            kw["ref_audio"] = req["ref_audio"]
            if req.get("ref_text"):
                kw["ref_text"] = req["ref_text"]
        else:
            kw["instruct"] = req.get("voice") or OMNI_PROFILES[0]
        audios = self.model.generate(text=req["text"], **kw)
        a = audios[0]
        a = a.detach().cpu().numpy() if hasattr(a, "detach") else np.asarray(a)
        return np.squeeze(a).astype(np.float32), self.sample_rate

    def voices(self):
        return [
            {"name": p, "language": "fr,en,600+", "kind": "profil instruct"}
            for p in OMNI_PROFILES
        ] + [{"name": "<chemin.wav>", "language": "*", "kind": "clonage (ref_audio)"}]


class Ming(Engine):
    """Ming-3.0-tts 0,5B (inclusionAI, MIT) : FR/EN et 5 autres, GPU."""

    name = "ming"
    gpu = True

    def __init__(self):
        super().__init__()
        from ming_tts import MingTTS

        t0 = time.time()
        self.model = MingTTS(
            env("TTS_MING_MODEL", "inclusionAI/Ming-3.0-tts-0.5B"),
            device=env("TTS_MING_DEVICE", "cuda:0"),
            text_normalization=False,
        )
        self.load_s = time.time() - t0

    def say(self, req):
        out = req["out"]
        voice = req.get("voice") or "US_Emma"
        if req.get("ref_audio"):
            self.model.synthesize(
                task="MULTILINGUAL",
                text=req["text"],
                language_id="fr" if req.get("language") == "fr" else "English",
                prompt_wav_path=req["ref_audio"],
                prompt_text=req.get("ref_text") or "",
                use_spk_emb=True,
                output_path=out,
            )
        elif voice.startswith("freeform:"):
            self.model.synthesize(
                task="FREEFORM",
                text=req["text"],
                instruction=voice.split(":", 1)[1],
                use_zero_spk_emb=True,
                output_path=out,
            )
        else:
            self.model.synthesize(
                task="IP",
                text=req["text"],
                controls={"ip": voice},
                use_zero_spk_emb=True,
                output_path=out,
            )
        import soundfile as sf

        a, sr = sf.read(out, dtype="float32")
        return np.asarray(a, dtype=np.float32).squeeze(), int(sr), out

    def voices(self):
        return [
            {"name": "US_Emma", "language": "en-us", "kind": "voix interne"},
            {"name": "UK_George", "language": "en-gb", "kind": "voix interne"},
            {"name": "freeform:<instruction>", "language": "*", "kind": "description"},
            {"name": "<chemin.wav>", "language": "fr,en", "kind": "clonage (ref_audio + ref_text)"},
        ]


class Chatterbox(Engine):
    """Chatterbox Multilingual V3 (Resemble AI, MIT, retire en 2026) : GPU.

    Sortie filigranee (Perth) : a savoir avant publication.
    """

    name = "cb"
    gpu = True

    def __init__(self):
        super().__init__()
        from chatterbox.mtl_tts import ChatterboxMultilingualTTS

        local = env("TTS_CB_MODEL_DIR")
        t0 = time.time()
        if local and os.path.exists(os.path.join(local, "t3_mtl23ls_v2.safetensors")):
            self.model = ChatterboxMultilingualTTS.from_local(local, device="cuda")
        else:
            self.model = ChatterboxMultilingualTTS.from_pretrained(device="cuda")
        self.load_s = time.time() - t0
        self.sample_rate = int(self.model.sr)

    def say(self, req):
        import torch

        lang = req.get("language") or "en"
        kw = {"language_id": lang}
        if req.get("ref_audio"):
            kw["audio_prompt_path"] = req["ref_audio"]
        with torch.no_grad():
            wav = self.model.generate(req["text"], **kw)
        a = wav.detach().cpu().numpy() if hasattr(wav, "detach") else np.asarray(wav)
        return np.asarray(a, dtype=np.float32).squeeze(), self.sample_rate

    def voices(self):
        return [
            {"name": "builtin", "language": "en", "kind": "voix interne"},
            {"name": "<chemin.wav>", "language": "23 langues", "kind": "clonage (ref_audio)"},
        ]


class Breeze(Engine):
    """Breeze TTS 2 (GGUF q4_k, binaire Vulkan) : EN/ZH, GPU, licence recherche."""

    name = "breeze"
    gpu = True

    def __init__(self):
        super().__init__()
        self.bin = env("TTS_BREEZE_BIN")
        self.gguf = env("TTS_BREEZE_GGUF")
        if not self.bin or not os.path.exists(self.bin):
            raise RuntimeError(f"binaire breeze absent : {self.bin}")
        if not self.gguf or not os.path.exists(self.gguf):
            raise RuntimeError(f"poids breeze absents : {self.gguf}")
        self.load_s = 1.0  # le binaire charge le modele a chaque appel

    def say(self, req):
        import subprocess

        out = req["out"]
        cmd = [self.bin, self.gguf]
        if req.get("ref_audio"):
            cmd += ["--ref-audio", req["ref_audio"]]
            if req.get("ref_text"):
                cmd += ["--ref-text", req["ref_text"]]
        elif req.get("voice") and req["voice"] != "builtin":
            cmd += ["--voice", req["voice"]]
        cmd += [
            "--instruction",
            req.get("voice_instruct") or "Speak clearly and naturally.",
            "--text",
            req["text"],
            "--output",
            out,
        ]
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
        if p.returncode != 0 or not os.path.exists(out):
            raise RuntimeError("breeze-cli : " + (p.stderr or p.stdout)[-800:])
        return None, 24000, out

    def voices(self):
        import subprocess

        try:
            p = subprocess.run(
                [self.bin, self.gguf, "--list-voices"], capture_output=True, text=True, timeout=60
            )
        except Exception as exc:  # noqa: BLE001
            return [{"name": "builtin", "language": "en,zh", "kind": f"erreur: {exc}"}]
        names = [ln.strip() for ln in p.stdout.splitlines() if ln.strip()]
        return [{"name": "builtin", "language": "en,zh", "kind": "instruction"}] + [
            {"name": n, "language": "en,zh", "kind": "voix sauvee"} for n in names[:50]
        ]


ENGINES = {
    "phonon": Phonon,
    "kokoro": Kokoro,
    "omni": Omni,
    "ming": Ming,
    "cb": Chatterbox,
    "breeze": Breeze,
}


# ------------------------------------------------------------------ modes


def do_say(engine, req):
    t_gen = time.time()
    result = engine.say(req)
    if len(result) == 3:
        audio, sr, path = result
        if audio is not None:
            write16(path, audio, sr)
        out = path
    else:
        audio, sr = result
        write16(req["out"], audio, sr)
        out = req["out"]
    gen = time.time() - t_gen
    dur = wav_duration(out)
    return {
        "ok": True,
        "engine": engine.name,
        "wav": out,
        "duration": round(dur, 2),
        "sr": int(sr),
        "load_s": round(engine.load_s, 2),
        "gen_s": round(gen, 2),
        "rtf": round(gen / dur, 3) if dur else None,
        "voice": req.get("voice"),
        "language": req.get("language"),
    }


def parse_turns(path):
    turns = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or "|" not in line:
                continue
            spk, _, txt = line.partition("|")
            if txt.strip():
                turns.append((spk.strip().upper(), txt.strip()))
    return turns


def do_job(engine, req, log=print):
    outdir = req["outdir"]
    os.makedirs(outdir, exist_ok=True)
    turns = parse_turns(req["script_file"])
    if req.get("limit"):
        turns = turns[: req["limit"]]
    voices = req.get("voices") or {}
    refs = req.get("refs") or {}
    log(f"moteur {engine.name} | {len(turns)} repliques | voix {voices}")
    total = 0.0
    t_gen = time.time()
    for i, (spk, txt) in enumerate(turns):
        out = os.path.join(outdir, f"{i:03d}.wav")
        if os.path.exists(out) and os.path.getsize(out) > 1000:
            total += wav_duration(out)
            log(f"[{i + 1}/{len(turns)}] deja fait")
            continue
        t = time.time()
        sub = {
            "text": txt,
            "voice": voices.get(spk),
            "language": req.get("language"),
            "speed": req.get("speed"),
            "ref_audio": refs.get(spk),
            "ref_text": req.get("ref_texts", {}).get(spk) if req.get("ref_texts") else None,
            "out": out,
        }
        result = engine.say(sub)
        if len(result) == 3:
            audio, sr, path = result
            if audio is not None:
                write16(path, audio, sr)
        else:
            audio, sr = result
            write16(out, audio, sr)
        dur = wav_duration(out)
        total += dur
        log(
            f"[{i + 1}/{len(turns)}] {spk} {len(txt)} car -> {dur:.1f}s audio "
            f"en {time.time() - t:.1f}s | cumul {total / 60:.1f} min audio, "
            f"{(time.time() - t_gen) / 60:.1f} min calcul"
        )
    sil = os.path.join(outdir, "_silence.wav")
    if not os.path.exists(sil):
        write16(sil, np.zeros(int(SILENCE_S * 24000), dtype=np.float32), 24000)
    with open(os.path.join(outdir, "list.txt"), "w") as f:
        for i in range(len(turns)):
            p = os.path.join(outdir, f"{i:03d}.wav")
            if os.path.exists(p):
                f.write(f"file '{p}'\nfile '{sil}'\n")
    log(
        f"RENDU {engine.name} TERMINE | {total / 60:.1f} min d'audio en "
        f"{(time.time() - t_gen) / 60:.1f} min de calcul"
    )
    return {"ok": True, "parts": len(turns), "audio_min": round(total / 60, 2)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True, choices=sorted(ENGINES))
    ap.add_argument("--serve", action="store_true")
    ap.add_argument("--once")
    ap.add_argument("--job")
    ap.add_argument("--voices", action="store_true")
    args = ap.parse_args()

    # Certains moteurs ecrivent sur stdout (loguru de ming, avertissements de
    # huggingface) : le protocole JSONL garde un canal prive (dup de fd 1) et
    # tout le reste part sur stderr, sinon une ligne de bruit fait echouer le
    # decodage cote serveur.
    chan = os.fdopen(os.dup(1), "w", buffering=1)
    os.dup2(2, 1)

    def emit(obj):
        chan.write(json.dumps(obj) + "\n")

    if args.voices:
        engine = ENGINES[args.engine]()
        emit({"ok": True, "engine": engine.name, "voices": engine.voices()})
        return

    if args.job:
        req = json.loads(args.job)
        outdir = req["outdir"]
        os.makedirs(outdir, exist_ok=True)
        logf = open(os.path.join(outdir, "job.log"), "a", buffering=1)
        logf.write(f"=== debut {time.strftime('%Y-%m-%d %H:%M:%S')}\n")

        def log(line):
            print(line, flush=True)
            logf.write(line + "\n")

        engine = ENGINES[args.engine]()
        log(f"modele charge en {engine.load_s:.1f}s")
        try:
            res = do_job(engine, req, log)
            log("DONE " + json.dumps(res))
        except Exception as exc:  # noqa: BLE001
            log(f"ERREUR {type(exc).__name__}: {exc}")
            raise
        return

    if args.once:
        req = json.loads(args.once)
        engine = ENGINES[args.engine]()
        try:
            emit(do_say(engine, req))
        except Exception as exc:  # noqa: BLE001
            emit({"ok": False, "error": f"{type(exc).__name__}: {exc}"})
        return

    engine = ENGINES[args.engine]()
    emit({"ok": True, "hello": engine.name, "load_s": round(engine.load_s, 2)})
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception as exc:  # noqa: BLE001
            emit({"ok": False, "error": f"json invalide: {exc}"})
            continue
        action = req.get("action", "say")
        if action == "quit":
            emit({"ok": True, "bye": True})
            break
        if action == "ping":
            emit({"ok": True, "engine": engine.name, "load_s": round(engine.load_s, 2)})
            continue
        if action == "voices":
            emit({"ok": True, "engine": engine.name, "voices": engine.voices()})
            continue
        try:
            emit(do_say(engine, req))
        except Exception as exc:  # noqa: BLE001
            emit({"ok": False, "error": f"{type(exc).__name__}: {exc}"})


if __name__ == "__main__":
    main()
