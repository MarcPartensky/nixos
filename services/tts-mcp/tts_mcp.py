"""Serveur MCP voix (Phonon, Kokoro, OmniVoice, Ming, Chatterbox, Breeze).

Pourquoi un serveur HTTP sur le portable plutot qu'un CLI :
  - le portable est le seul noeud qui a les moteurs, les poids et la RTX 3060,
    donc TOUTE generation de voix y reste, quelle que soit la machine qui parle
    a l'agent ;
  - un process par moteur garde le modele chaud pendant que le serveur vit
    (le CLI recharge le modele a chaque appel : 0,7 s pour Phonon, 4 s pour
    Kokoro, 8 s pour OmniVoice, davantage pour Ming) ;
  - les rendus longs partent en job detache, un wav par replique, avec reprise
    automatique : une coupure de ssh ne perd pas le travail deja fait.

Transport : streamable HTTP, sur le tailnet (le pare-feu du portable ne fait
confiance qu'a l'interface tailscale0). Les fichiers restent sur le portable et
les outils renvoient leur chemin absolu : l'agent les rapatrie par scp/rsync.

Configuration : JSON lu dans $TTS_CONFIG (genere par services/tts-mcp du depot
nixos), avec la table des moteurs, les interpreters et les outils ffmpeg.
"""

import json
import os
import queue
import shutil
import signal
import subprocess
import sys
import threading
import time

from mcp.server.fastmcp import FastMCP

CONFIG_PATH = os.environ.get("TTS_CONFIG", "/etc/tts-mcp/engines.json")
with open(CONFIG_PATH, encoding="utf-8") as _f:
    CFG = json.load(_f)

BENCH = CFG["bench_dir"]
WORKER = CFG["worker"]
FFMPEG = CFG["ffmpeg"]
FFPROBE = CFG["ffprobe"]
MASTER_CHAIN = CFG["master_chain"]
ENGINES = CFG["engines"]
WARM_TTL = int(CFG.get("warm_ttl_seconds", 900))
JOBS_DIR = CFG["jobs_dir"]
OUT_DIR = CFG["out_dir"]
BASE_PATH = CFG.get("path", os.environ.get("PATH", "/run/current-system/sw/bin"))
BASE_LD = CFG.get("ld_library_path", os.environ.get("LD_LIBRARY_PATH", ""))
LOG_DIR = os.path.join(BENCH, "logs")
STARTED = time.time()

os.makedirs(JOBS_DIR, exist_ok=True)
os.makedirs(OUT_DIR, exist_ok=True)
os.makedirs(LOG_DIR, exist_ok=True)

mcp = FastMCP(
    "tts-laptop",
    host=CFG.get("host", "0.0.0.0"),
    port=int(CFG.get("port", 8092)),
    streamable_http_path="/mcp",
    json_response=True,
    stateless_http=True,
)

# ------------------------------------------------------------- utilitaires


def engine_env(spec):
    env = dict(os.environ)
    env["PATH"] = spec.get("path", BASE_PATH) + ":" + BASE_PATH
    env["LD_LIBRARY_PATH"] = spec.get("ld_library_path", BASE_LD)
    env.update(spec.get("env", {}))
    env.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    env.setdefault("TOKENIZERS_PARALLELISM", "false")
    return env


def engine_ok(spec):
    """Le moteur est-il utilisable ? (chemin de l'interpreteur present)"""
    py = spec.get("python")
    if py and not os.path.exists(py):
        return False, f"interpreteur absent : {py} (banc d'essai non monte ?)"
    if spec.get("kind") == "cli":
        b = spec.get("env", {}).get("TTS_BREEZE_BIN")
        if b and not os.path.exists(b):
            return False, f"binaire absent : {b}"
    return True, ""


def run(cmd, timeout=600, env=None):
    p = subprocess.run(
        cmd, capture_output=True, text=True, timeout=timeout, env=env
    )
    if p.returncode != 0:
        raise RuntimeError(f"{cmd[0]} a echoue ({p.returncode}) : {p.stderr[-500:]}")
    return p.stdout


def probe_duration(path):
    out = run([FFPROBE, "-v", "error", "-show_entries", "format=duration",
               "-of", "default=nw=1:nk=1", path], timeout=60)
    return float(out.strip())


def loudness(path):
    p = subprocess.run([FFMPEG, "-hide_banner", "-i", path, "-af", "volumedetect",
                        "-f", "null", "-"], capture_output=True, text=True, timeout=300)
    vals = {}
    for line in p.stderr.splitlines():
        for key in ("mean_volume", "max_volume"):
            if key + ":" in line:
                vals[key] = line.split(key + ":")[1].strip()
    return vals


def master(inp, out_wav, out_mp3=None):
    run([FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", inp,
         "-af", MASTER_CHAIN, "-ar", "24000", "-ac", "1", "-c:a", "pcm_s16le", out_wav])
    if out_mp3:
        run([FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-i", out_wav,
             "-b:a", "192k", out_mp3])
    return out_wav


def new_path(kind, label):
    stamp = time.strftime("%Y%m%d-%H%M%S")
    slug = "".join(c if c.isalnum() else "-" for c in (label or "")).strip("-")[:40]
    d = os.path.join(OUT_DIR, f"{stamp}-{slug or kind}")
    os.makedirs(d, exist_ok=True)
    return d


# ------------------------------------------------------------ pool chaud


class Warm:
    """Un moteur garde chaud : un process, une boucle JSONL, un modele charge."""

    def __init__(self, name, spec):
        self.name = name
        self.spec = spec
        self.proc = None
        self.lock = threading.RLock()
        self.lines = queue.Queue()
        self.last_used = 0.0
        self.hello = None
        self.err_path = os.path.join(LOG_DIR, f"tts-mcp-{name}.err")

    def start(self):
        if self.proc is not None and self.proc.poll() is None:
            return
        py = self.spec.get("python") or sys.executable
        with open(self.err_path, "ab", buffering=0) as errf:
            self.proc = subprocess.Popen(
                [py, WORKER, "--engine", self.name, "--serve"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errf,
                text=True, bufsize=1, env=engine_env(self.spec), cwd=BENCH,
            )
        threading.Thread(target=self._reader, daemon=True).start()
        # Le worker annonce son demarrage par une ligne "hello" : la lire ici,
        # sinon elle est consommee comme reponse du premier appel legitime.
        try:
            hello = json.loads(self.lines.get(timeout=int(self.spec.get("load_timeout", 300))))
        except queue.Empty:
            self.stop()
            raise RuntimeError(
                f"moteur {self.name} : pas de demarrage en "
                f"{self.spec.get('load_timeout', 300)}s (voir {self.err_path})"
            )
        except (TypeError, ValueError):
            self.stop()
            raise RuntimeError(f"moteur {self.name} : demarrage illisible (voir {self.err_path})")
        if not hello.get("ok"):
            self.stop()
            raise RuntimeError(f"moteur {self.name} : demarrage refuse : {hello}")
        self.hello = hello
        self.last_used = time.time()

    def _reader(self):
        proc = self.proc
        for line in proc.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def request(self, obj, timeout=600):
        with self.lock:
            if self.proc is None or self.proc.poll() is not None:
                self.start()
            self.last_used = time.time()
            try:
                self.proc.stdin.write(json.dumps(obj) + "\n")
                self.proc.stdin.flush()
            except BrokenPipeError:
                self.stop()
                raise RuntimeError(f"moteur {self.name} : pipe casse, relance le serveur")
            line = self._next_json(timeout)
            if line is None:
                self.stop()
                raise RuntimeError(
                    f"moteur {self.name} : process mort (voir {self.err_path})"
                )
            return line

    def _next_json(self, timeout):
        """Lit la prochaine reponse JSON en ignorant les lignes de bruit."""
        try:
            line = self.lines.get(timeout=timeout)
        except queue.Empty:
            # Le moteur ne repond pas dans les temps : le tuer pour eviter
            # qu'un modele a moitie charge bloque tous les appels suivants.
            self.stop()
            raise RuntimeError(
                f"moteur {self.name} : pas de reponse en {timeout}s "
                f"(voir {self.err_path})"
            )
        for _ in range(200):
            if line is None:
                return None
            try:
                return json.loads(line)
            except ValueError:
                try:
                    line = self.lines.get(timeout=15)
                except queue.Empty:
                    return None
        return None

    def stop(self):
        proc, self.proc = self.proc, None
        if proc and proc.poll() is None:
            try:
                proc.stdin.close()
            except Exception:  # noqa: BLE001
                pass
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()


class Pool:
    def __init__(self):
        self.warm = {}
        self.lock = threading.Lock()
        threading.Thread(target=self._janitor, daemon=True).start()

    def get(self, name):
        if name not in ENGINES:
            raise ValueError(f"moteur inconnu : {name} (dispo : {sorted(ENGINES)})")
        with self.lock:
            if name not in self.warm:
                self.warm[name] = Warm(name, ENGINES[name])
            return self.warm[name]

    def drop(self, name):
        with self.lock:
            w = self.warm.pop(name, None)
        if w:
            w.stop()

    def _janitor(self):
        while True:
            time.sleep(30)
            now = time.time()
            for name, w in list(self.warm.items()):
                if w.last_used and now - w.last_used > WARM_TTL:
                    if not job_running_for(name):
                        self.drop(name)

    def status(self):
        out = {}
        for name, w in list(self.warm.items()):
            alive = w.proc is not None and w.proc.poll() is None
            out[name] = {
                "chaud": alive,
                "inactif_s": round(time.time() - w.last_used) if w.last_used else None,
            }
        return out


POOL = Pool()


# ------------------------------------------------------------------ jobs


def job_file(job_id):
    return os.path.join(JOBS_DIR, job_id, "job.json")


def read_job(job_id):
    p = job_file(job_id)
    if not os.path.exists(p):
        raise ValueError(f"job inconnu : {job_id}")
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def write_job(job):
    p = job_file(job["id"])
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(job, f, ensure_ascii=False, indent=1)
    os.replace(tmp, p)


def pid_alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except (ProcessLookupError, ValueError, PermissionError):
        return False


def job_running_for(engine):
    for j in list_jobs():
        if j["engine"] == engine and j.get("state") == "en cours":
            return True
    return False


def job_progress(job_id):
    job = read_job(job_id)
    d = os.path.join(JOBS_DIR, job_id)
    parts = sorted(f for f in os.listdir(d) if f[:1].isdigit() and f.endswith(".wav"))
    job["parts_faites"] = len(parts)
    log = os.path.join(d, "job.log")
    tail = []
    if os.path.exists(log):
        with open(log, encoding="utf-8", errors="replace") as f:
            tail = f.read().splitlines()[-6:]
    done = any("DONE" in ln for ln in tail)
    erreur = next((ln for ln in reversed(tail) if ln.startswith("ERREUR")), None)
    if done:
        job["state"] = "termine"
    elif erreur:
        job["state"] = "echec"
        job["erreur"] = erreur
    elif pid_alive(job.get("pid")):
        job["state"] = "en cours"
    else:
        job["state"] = "mort" if job.get("state") == "en cours" else job.get("state", "?")
    write_job(job)
    job["log_tail"] = tail
    return job


def list_jobs():
    out = []
    if os.path.isdir(JOBS_DIR):
        for jid in sorted(os.listdir(JOBS_DIR)):
            try:
                out.append(read_job(jid))
            except Exception:  # noqa: BLE001
                continue
    return out


# ------------------------------------------------------------------ outils


@mcp.tool()
def status() -> dict:
    """Etat du serveur voix du portable : moteurs, GPU, jobs, disque.

    A appeler en premier quand un rendu echoue, ou avant de lancer un rendu
    long. `moteurs` donne pour chacun la disponibilite, le chemin de son
    interpreteur et la raison exacte d'une indisponibilite (banc d'essai
    demonte, venv absent). `gpu` donne la VRAM libre : les moteurs GPU
    (omni, ming, cb, breeze) la partagent avec le serveur LLM du portable.
    """
    moteurs = {}
    for name, spec in sorted(ENGINES.items()):
        ok, why = engine_ok(spec)
        moteurs[name] = {
            "disponible": ok,
            "raison": why or None,
            "gpu": bool(spec.get("gpu")),
            "langues": spec.get("languages", []),
            "voix_par_defaut": spec.get("default_voice", {}),
            "note": spec.get("note"),
        }
    gpu = ""
    try:
        gpu = run(["nvidia-smi", "--query-gpu=name,memory.used,memory.total,utilization.gpu",
                   "--format=csv,noheader"], timeout=30).strip()
    except Exception as exc:  # noqa: BLE001
        gpu = f"indisponible ({exc})"
    jobs = [
        {"id": j["id"], "engine": j["engine"], "state": j.get("state"),
         "parts": f"{j.get('parts_faites', 0)}/{j.get('parts_attendues')}",
         "debut": j.get("created")}
        for j in list_jobs()[-12:]
    ]
    disque = shutil.disk_usage(BENCH if os.path.exists(BENCH) else "/").free // 2**30
    return {
        "serveur": "tts-mcp sur le portable",
        "uptime_min": round((time.time() - STARTED) / 60, 1),
        "bench_dir": BENCH,
        "sorties": OUT_DIR,
        "jobs": jobs,
        "moteurs_chauds": POOL.status(),
        "gpu": gpu.split("\n"),
        "disque_libre_go": disque,
        "moteurs": moteurs,
    }


@mcp.tool()
def voices(engine: str = "kokoro", language: str | None = None) -> dict:
    """Catalogue des voix d'un moteur.

    `engine` parmi phonon, kokoro, omni, ming, cb, breeze. `language` filtre
    quand le moteur en a plusieurs (en, en-gb, fr...). Pour kokoro les noms
    commencent par la langue (af_/am_ anglais US, bf_/bm_ anglais GB, ff_/fm_
    francais) ; pour phonon ce sont des prenoms ; pour omni/ming/cb/breeze la
    voix est soit un profil interne, soit un wav de reference a passer a
    `ref_audio` (clonage).
    """
    spec = ENGINES.get(engine)
    if spec is None:
        return {"ok": False, "erreur": f"moteur inconnu : {engine}",
                "moteurs": sorted(ENGINES)}
    ok, why = engine_ok(spec)
    if not ok:
        return {"ok": False, "engine": engine, "erreur": why}
    if spec.get("voices_source") == "static":
        vs = spec.get("voices", [])
    else:
        w = POOL.get(engine)
        res = w.request({"action": "voices"}, timeout=int(spec.get("load_timeout", 300)))
        if not res.get("ok"):
            return {"ok": False, "engine": engine, "erreur": res.get("error")}
        vs = res["voices"]
    if language:
        vs = [v for v in vs if language.lower() in str(v.get("language", "")).lower()]
    return {"ok": True, "engine": engine, "nombre": len(vs), "voix": vs}


@mcp.tool()
def say(
    text: str,
    engine: str = "phonon",
    voice: str | None = None,
    language: str | None = None,
    speed: float | None = None,
    master_audio: bool = True,
    ref_audio: str | None = None,
    ref_text: str | None = None,
) -> dict:
    """Lit un texte court (moins de ~1500 caracteres) et renvoie un fichier audio.

    Le rendu se fait ICI, sur le portable, avec le modele chaud. `engine` :
    phonon (anglais, le plus rapide, CPU), kokoro (francais et anglais, CPU),
    omni (600+ langues, GPU, poids non commerciaux), ming, cb, breeze.

    - `voice` : nom du catalogue (`voices`), sinon voix par defaut du moteur.
    - `language` : "en", "fr", "en-gb"... selon le moteur.
    - `speed` : debit, 1.0 par defaut (omni tourne volontairement a 1.10).
    - `master_audio` : applique la chaine podcast (-16 LUFS, deesser,
      compression) et produit un mp3 a 192k, en plus du wav brut.
    - `ref_audio` (+ `ref_text`) : clonage d'une voix depuis un wav, pour les
      moteurs qui le supportent (omni, ming, cb, breeze).

    Renvoie les chemins SUR LE PORTABLE : rapatrier par
    `scp laptop:<chemin> ...`. Pour un texte long ou un dialogue, utiliser
    `render` (job detache, reprise sur incident).
    """
    spec = ENGINES.get(engine)
    if spec is None:
        return {"ok": False, "erreur": f"moteur inconnu : {engine}",
                "moteurs": sorted(ENGINES)}
    ok, why = engine_ok(spec)
    if not ok:
        return {"ok": False, "engine": engine, "erreur": why}
    lang = (language or spec.get("default_language") or "en").lower()
    if spec.get("languages") and lang not in spec["languages"]:
        return {"ok": False, "engine": engine, "erreur": f"langue non geree : {lang}",
                "langues": spec["languages"]}
    if len(text) > 6000:
        return {"ok": False, "erreur": "texte trop long pour say (6000 car max) : "
                "decouper en repliques et utiliser render"}
    d = new_path("say", voice or lang)
    wav = os.path.join(d, "brut.wav")
    req = {
        "action": "say", "text": text, "voice": voice or spec.get("default_voice", {}).get(lang),
        "language": lang, "speed": speed, "out": wav,
        "ref_audio": ref_audio, "ref_text": ref_text,
    }
    if job_running_for(engine):
        POOL.drop(engine)
    w = POOL.get(engine)
    res = w.request(req, timeout=int(spec.get("say_timeout", 900)))
    if not res.get("ok"):
        return {"ok": False, "engine": engine, "erreur": res.get("error")}
    out = {
        "ok": True, "engine": engine, "wav_brut": res["wav"],
        "duree_s": res["duration"], "voix": res.get("voice"), "langue": lang,
        "rtf": res.get("rtf"), "chargement_modele_s": res.get("load_s"),
    }
    if master_audio:
        m3 = os.path.join(d, "masterise.mp3")
        master(res["wav"], os.path.join(d, "masterise.wav"), m3)
        out["mp3_masterise"] = m3
        out["niveau"] = loudness(m3)
    return out


@mcp.tool()
def render(
    script: str,
    engine: str = "phonon",
    voice_a: str | None = None,
    voice_b: str | None = None,
    language: str | None = None,
    title: str | None = None,
    speed: float | None = None,
    limit: int = 0,
    ref_a: str | None = None,
    ref_b: str | None = None,
) -> dict:
    """Rend un dialogue long (script A|texte ligne par ligne) en job detache.

    Une replique par ligne, prefixee par son locuteur : "A|Bonjour." /
    "B|Bonjour, Marc." Les nombres doivent etre ecrits en mots (« dix mille »,
    pas « 10 000 ») : le G2P les lit mal. Le job reprend tout seul apres un
    incident (un wav par replique deja rendu est saute), donc `render` peut etre
    rappele avec le meme titre pour reprendre : le dossier du job est
    reutilise (`reprendre` le dit).

    - `voice_a` / `voice_b` : voix du catalogue (`voices`) pour chaque locuteur.
    - `limit` : ne rendre que les N premieres repliques (test d'ecoute avant
      un rendu de 20 minutes).

    Renvoie un `job_id` : suivre avec `job`, finaliser avec `finish`.
    """
    spec = ENGINES.get(engine)
    if spec is None:
        return {"ok": False, "erreur": f"moteur inconnu : {engine}",
                "moteurs": sorted(ENGINES)}
    ok, why = engine_ok(spec)
    if not ok:
        return {"ok": False, "engine": engine, "erreur": why}
    lang = (language or spec.get("default_language") or "en").lower()
    if spec.get("languages") and lang not in spec["languages"]:
        return {"ok": False, "engine": engine, "erreur": f"langue non geree : {lang}",
                "langues": spec["languages"]}
    turns = [ln for ln in script.splitlines() if "|" in ln and ln.split("|", 1)[1].strip()]
    if not turns:
        return {"ok": False, "erreur": "script vide : une replique par ligne, A|texte"}
    jid = f"{time.strftime('%Y%m%d-%H%M%S')}-{engine}-" + "".join(
        c if c.isalnum() else "-" for c in (title or "dialogue")).strip("-")[:40]
    jid = jid.rstrip("-")
    d = os.path.join(JOBS_DIR, jid)
    os.makedirs(d, exist_ok=True)
    script_file = os.path.join(d, "script.txt")
    reprendre = os.path.exists(script_file)
    with open(script_file, "w", encoding="utf-8") as f:
        f.write("\n".join(turns) + "\n")
    voices_map = {
        "A": voice_a or spec.get("default_voice", {}).get(lang),
        "B": voice_b or spec.get("default_voice", {}).get(lang),
    }
    req = {
        "script_file": script_file, "outdir": d, "voices": voices_map,
        "language": lang, "speed": speed, "limit": limit, "silence": 0.45,
        "refs": {"A": ref_a, "B": ref_b},
    }
    if job_running_for(engine):
        return {"ok": False, "engine": engine,
                "erreur": "un job tourne deja sur ce moteur ; attendre sa fin "
                          "(ou `kill_job`) avant d'en lancer un autre"}
    POOL.drop(engine)  # un job GPU + un modele chaud = deux fois la VRAM
    log_path = os.path.join(d, "job.log")
    py = spec.get("python") or sys.executable
    with open(log_path, "ab", buffering=0) as log:
        proc = subprocess.Popen(
            [py, WORKER, "--engine", engine, "--job", json.dumps(req, ensure_ascii=False)],
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
            env=engine_env(spec), cwd=BENCH, start_new_session=True,
        )
    job = {
        "id": jid, "engine": engine, "state": "en cours", "pid": proc.pid,
        "created": time.strftime("%Y-%m-%d %H:%M:%S"), "title": title,
        "langue": lang, "voix": voices_map, "parts_attendues": len(turns),
        "dossier": d, "log": log_path, "reprendre": reprendre,
    }
    write_job(job)
    return {"ok": True, "job_id": jid, "dossier": d, "pid": proc.pid,
            "repliques": len(turns), "reprendre": reprendre,
            "suivre": f"job('{jid}') puis finish('{jid}')"}


@mcp.tool()
def job(job_id: str) -> dict:
    """Avancement d'un rendu long : etat, repliques faites, 6 dernieres lignes de log.

    `state` vaut "en cours", "termine" (toutes les repliques, list.txt ecrit),
    "echec" (erreur du moteur, `erreur` donne la derniere ligne) ou "mort"
    (process disparu sans finir : relancer `render` avec le meme titre reprend).
    """
    return job_progress(job_id)


@mcp.tool()
def jobs() -> dict:
    """Liste les rendus du portable, du plus recent au plus ancien."""
    out = []
    for j in sorted(list_jobs(), key=lambda x: x.get("id", ""), reverse=True)[:20]:
        out.append({"id": j["id"], "engine": j["engine"], "state": j.get("state"),
                    "parts": f"{j.get('parts_faites', 0)}/{j.get('parts_attendues')}",
                    "titre": j.get("title"), "created": j.get("created")})
    return {"ok": True, "jobs": out, "dossier": JOBS_DIR}


@mcp.tool()
def finish(job_id: str, master_audio: bool = True) -> dict:
    """Assemble un job termine et applique le mastering : wav concatene + mp3.

    A appeler quand `job` dit "termine" (ou quand il ne reste que des repliques
    deja faites). Renvoie la duree, la taille et le niveau mesure
    (`mean_volume` autour de -17 dB, `max_volume` autour de -1.8 dB quand le
    mastering est bon). Les fichiers restent sur le portable : rapatrier par
    `scp laptop:<chemin>` avant de publier.
    """
    j = job_progress(job_id)
    d = j["dossier"]
    text_list = os.path.join(d, "list.txt")
    if not os.path.exists(text_list):
        return {"ok": False, "job_id": job_id, "state": j["state"],
                "erreur": "list.txt absent : rendu non termine (voir `job`)"}
    raw = os.path.join(d, "assemblage.wav")
    run([FFMPEG, "-y", "-hide_banner", "-loglevel", "error", "-f", "concat",
         "-safe", "0", "-i", text_list, "-ar", "24000", "-ac", "1", raw])
    out = {"ok": True, "job_id": job_id, "wav_brut": raw,
           "duree_min": round(probe_duration(raw) / 60, 2),
           "taille_mo": round(os.path.getsize(raw) / 2**20, 1)}
    if master_audio:
        wav = os.path.join(d, "final.wav")
        mp3 = os.path.join(d, "final.mp3")
        master(raw, wav, mp3)
        out["wav_masterise"] = wav
        out["mp3"] = mp3
        out["niveau"] = loudness(mp3)
        out["taille_mp3_mo"] = round(os.path.getsize(mp3) / 2**20, 1)
    return out


@mcp.tool()
def kill_job(job_id: str) -> dict:
    """Arrete un rendu en cours. Les repliques deja rendues restent sur le disque ;
    un `render` relance avec le meme titre reprend a la premiere manquante.
    """
    job = read_job(job_id)
    pid = job.get("pid")
    if not pid_alive(pid):
        job["state"] = "arrete"
        write_job(job)
        return {"ok": True, "job_id": job_id, "deja_mort": True}
    try:
        os.killpg(os.getpgid(int(pid)), signal.SIGTERM)
    except Exception:  # noqa: BLE001
        os.kill(int(pid), signal.SIGTERM)
    job["state"] = "arrete"
    write_job(job)
    return {"ok": True, "job_id": job_id, "arrete": pid}


if __name__ == "__main__":
    print(f"tts-mcp : {len(ENGINES)} moteurs, ecoute {CFG.get('host')}:{CFG.get('port')}/mcp",
          flush=True)
    try:
        mcp.run(transport="streamable-http")
    finally:
        for name in list(POOL.warm):
            POOL.drop(name)
