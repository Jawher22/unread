"""Judges the narrator's reading quality against fixed passages (#75). Run through scripts/eval.sh.

    passages              assembles fixtures/eval/passages/ from fixtures/eval.txt
    elevenlabs [models]   the ElevenLabs reference for each passage (ELEVENLABS_API_KEY), or lists the models
    score RUN…            Whisper word errors, pitch spread and pauses for each run's WAVs
    ab A B                a blind A/B page for two runs; choices go to fixtures/eval/ab/
    rate RUN              each passage next to the ElevenLabs reference, scored 1–5; to fixtures/eval/ratings/

A run is fixtures/eval/runs/<name>/ (written by `Unread --eval`), or "elevenlabs" for the references.
"""
import json
import random
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import make_voices as mv  # noqa: E402

ROOT = mv.ROOT
EVAL = ROOT / "fixtures/eval"
PASSAGES = EVAL / "passages"
REFERENCES = EVAL / "elevenlabs"
SR = mv.SR
# Quiet inside a passage that counts as a pause, in seconds (shorter is a stop consonant or a breath).
MIN_PAUSE = 0.15


def manifest():
    rows = []
    for line in (ROOT / "fixtures/eval.txt").read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            rows.append(line.split())
    return rows


def passages():
    PASSAGES.mkdir(parents=True, exist_ok=True)
    for row in manifest():
        pid, source = row[0], row[1]
        if source == "original":
            text = (ROOT / f"fixtures/eval-original/{pid}.txt").read_text().strip()
        else:
            page = ROOT / f"fixtures/corpus/{source}.expected.txt"
            if not page.exists():
                print(f"{pid}: no {page.relative_to(ROOT)}; run scripts/save-corpus.sh")
                continue
            lines = page.read_text().splitlines()
            paragraphs = []
            for span in row[2].split("|"):
                a, _, b = span.partition("-")
                paragraphs.append("\n".join(lines[int(a) - 1: int(b or a)]))
            text = "\n\n".join(paragraphs)
        (PASSAGES / f"{pid}.txt").write_text(text + "\n")
    texts = list(PASSAGES.glob("*.txt"))
    print(f"passages: {len(texts)} in {PASSAGES.relative_to(ROOT)}, {sum(len(spoken(p.stem)) for p in texts)} characters")


def spoken(pid):
    """The passage as one text: sentences joined, paragraphs a blank line apart."""
    text = (PASSAGES / f"{pid}.txt").read_text().strip()
    return "\n\n".join(" ".join(p.split("\n")) for p in text.split("\n\n"))


def run_dir(name):
    return REFERENCES if name == "elevenlabs" else EVAL / "runs" / name


# MARK: ElevenLabs references

def elevenlabs(*rest):
    import os
    key = os.environ.get("ELEVENLABS_API_KEY")
    if not key:
        sys.exit("ELEVENLABS_API_KEY is not set")

    def call(path, body=None):
        req = urllib.request.Request(f"https://api.elevenlabs.io{path}", data=body and json.dumps(body).encode(),
                                     headers={"xi-api-key": key, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            sys.exit(f"elevenlabs {path}: HTTP {e.code}: {e.read().decode(errors='replace')[:500]}")

    if rest and rest[0] == "models":
        for m in json.loads(call("/v1/models")):
            print(f"{m['model_id']:28} {m.get('name', '')}")
        return
    config = json.loads((EVAL / "elevenlabs.json").read_text()) if (EVAL / "elevenlabs.json").exists() else {}
    model, voice = config.get("model"), config.get("voice")
    if not model or not voice:
        sys.exit(f'write {EVAL.relative_to(ROOT)}/elevenlabs.json: {{"model": "<model_id>", "voice": "<voice_id>"}}')
    REFERENCES.mkdir(parents=True, exist_ok=True)
    for txt in sorted(PASSAGES.glob("*.txt")):
        wav = REFERENCES / f"{txt.stem}.wav"
        if wav.exists():
            continue
        pcm = call(f"/v1/text-to-speech/{voice}?output_format=pcm_24000", {"text": spoken(txt.stem), "model_id": model})
        mv.write(wav, np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768)
        print(f"elevenlabs {txt.stem}: {len(pcm) / 2 / SR:.1f} s", flush=True)
    (REFERENCES / "run.json").write_text(json.dumps({"model": model, "voice": voice}, indent=1))


# MARK: scores

# Whisper hears 30 s at a time and drops words at the seam, so a passage is cut at its pauses into pieces under this.
PIECE = 25.0


def pieces(audio):
    """`audio` cut in the middle of pauses, each piece under PIECE seconds where a pause allows."""
    loud = mv.loud_windows(audio)
    cuts, start, run = [0], 0, 0
    best = None
    for i, q in enumerate(loud):
        if not q:
            run += 1
            continue
        if run * mv.WINDOW / SR >= MIN_PAUSE:
            best = (i - run // 2) * mv.WINDOW
        run = 0
        if (i * mv.WINDOW - start) / SR > PIECE and best and best > start:
            cuts.append(best)
            start, best = best, None
    return [audio[a:b] for a, b in zip(cuts, cuts[1:] + [len(audio)])]


def transcribe(wavs):
    """Whisper's transcript of each WAV, cached beside it until the WAV changes."""
    stale = [w for w in wavs if not w.with_suffix(".txt").exists() or w.with_suffix(".txt").stat().st_mtime < w.stat().st_mtime]
    if stale:
        import tempfile
        from mlx_audio.stt import load
        model = load(mv.snapshot("asr"))
        with tempfile.TemporaryDirectory() as tmp:
            for w in stale:
                said = []
                for k, piece in enumerate(pieces(mv.read(w))):
                    path = Path(tmp) / f"{k}.wav"
                    mv.write(path, piece)
                    said.append(model.generate(str(path), language="en", return_timestamps=False).text.strip())
                w.with_suffix(".txt").write_text(" ".join(said) + "\n")
                print(f"asr {w.parent.name}/{w.name}", flush=True)
        mv.free(model)
    return {w.stem: w.with_suffix(".txt").read_text().strip() for w in wavs}


def pauses(audio):
    """Quiet runs inside the voiced span, in seconds."""
    loud = mv.loud_windows(audio)
    idx = np.flatnonzero(loud)
    runs, run = [], 0
    for q in loud[idx[0]: idx[-1] + 1] if idx.size else []:
        if q:
            if run * mv.WINDOW / SR >= MIN_PAUSE:
                runs.append(run * mv.WINDOW / SR)
            run = 0
        else:
            run += 1
    return runs


def measure(wav, said, expected):
    audio = mv.read(wav)
    start, end = mv.voiced_span(audio)
    f0 = mv.pitch_track(audio[start:end])
    semis = 12 * np.log2(f0) if f0.size else np.array([0.0])
    gaps = pauses(audio)
    return {"errors": mv.word_errors(said, expected), "words": len(mv.words(expected)),
            "seconds": round(len(audio) / SR, 2),
            "pitch_spread": round(float(np.percentile(semis, 90) - np.percentile(semis, 10)), 1),
            "f0": round(float(np.median(f0))) if f0.size else None,
            "pauses": len(gaps), "pause_median": round(float(np.median(gaps)), 2) if gaps else 0.0,
            "pause_max": round(max(gaps), 2) if gaps else 0.0}


def score(*names):
    if not names:
        sys.exit("score: name at least one run")
    table = {}
    for name in names:
        d = run_dir(name)
        wavs = sorted(d.glob("*.wav"))
        if not wavs:
            sys.exit(f"score: no WAVs in {d}")
        said = transcribe(wavs)
        rows = {w.stem: measure(w, said[w.stem], spoken(w.stem)) for w in wavs}
        (d / "score.json").write_text(json.dumps({"passages": rows, "transcripts": said}, indent=1))
        table[name] = rows
    ids = sorted(set().union(*[set(r) for r in table.values()]))
    print(f"\n{'passage':20}" + "".join(f"{n[:22]:>24}" for n in names))
    print(f"{'':20}" + "".join(f"{'wer  spread  pauses':>24}" for _ in names))
    for pid in ids:
        cells = []
        for n in names:
            m = table[n].get(pid)
            cells.append(f"{m['errors'] / m['words']:5.1%} {m['pitch_spread']:5.1f}st {m['pauses']:3d}/{m['pause_max']:.1f}s" if m else "–")
        print(f"{pid:20}" + "".join(f"{c:>24}" for c in cells))
    print()
    for n in names:
        rows = table[n].values()
        errors, words = sum(r["errors"] for r in rows), sum(r["words"] for r in rows)
        print(f"{n}: WER {errors / words:.1%} ({errors}/{words} words), pitch spread median "
              f"{np.median([r['pitch_spread'] for r in rows]):.1f} semitones, "
              f"{sum(r['seconds'] for r in rows):.0f} s of audio, longest pause {max(r['pause_max'] for r in rows):.1f} s")


# MARK: listening pages

PAGE = """<!doctype html><meta charset=utf-8><title>%(title)s</title>
<style>
:root{color-scheme:light dark;--fg:#1d1d1f;--bg:#fbfbfd;--card:#fff;--line:#d2d2d7;--accent:#0071e3}
@media (prefers-color-scheme:dark){:root{--fg:#f5f5f7;--bg:#161617;--card:#1d1d1f;--line:#424245;--accent:#2997ff}}
body{font:15px/1.5 -apple-system,system-ui,sans-serif;color:var(--fg);background:var(--bg);max-width:760px;margin:32px auto;padding:0 16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 20px;margin:16px 0}
.text{white-space:pre-wrap;opacity:.75;font-size:14px}
audio{width:100%%;margin:6px 0}
button{font:inherit;padding:6px 14px;border-radius:8px;border:1px solid var(--line);background:none;color:inherit;cursor:pointer}
button.on{background:var(--accent);border-color:var(--accent);color:#fff}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:6px 0}
.label{width:90px;font-weight:600}
#save{background:var(--accent);color:#fff;border:none;padding:10px 20px}
</style>
<h1>%(title)s</h1><p>%(help)s</p><div id=cards></div><p><button id=save>Save</button> <span id=status></span></p>
<script>
const items = %(items)s, mode = "%(mode)s", picks = {};
const cards = document.getElementById("cards");
function buttons(key, options) {
  const row = document.createElement("span");
  for (const o of options) {
    const b = document.createElement("button"); b.textContent = o;
    b.onclick = () => { picks[key] = o; row.querySelectorAll("button").forEach(x => x.classList.toggle("on", x === b)); };
    row.append(b);
  }
  return row;
}
items.forEach((it, i) => {
  const c = document.createElement("div"); c.className = "card";
  c.innerHTML = `<b>${i + 1}. ${it.id}</b><div class=text></div>`;
  c.querySelector(".text").textContent = it.text;
  for (const [label, src] of it.audio) {
    const r = document.createElement("div"); r.className = "row";
    r.innerHTML = `<span class=label>${label}</span><audio controls preload=none src="${src}"></audio>`;
    c.append(r);
  }
  if (mode === "ab") {
    const r = document.createElement("div"); r.className = "row"; r.innerHTML = "<span class=label>Better</span>";
    r.append(buttons(it.id, ["A", "B", "Same"])); c.append(r);
  } else {
    for (const axis of ["prosody", "seams", "emotion"]) {
      const r = document.createElement("div"); r.className = "row"; r.innerHTML = `<span class=label>${axis}</span>`;
      r.append(buttons(it.id + "/" + axis, ["1", "2", "3", "4", "5"])); c.append(r);
    }
  }
  cards.append(c);
});
document.getElementById("save").onclick = async () => {
  const r = await fetch("/save", {method: "POST", body: JSON.stringify(picks)});
  document.getElementById("status").textContent = await r.text();
};
</script>"""


def serve(title, help_text, mode, items, files, save):
    """Serves the page on localhost until Ctrl-C; `files` maps URL paths to WAVs; `save(picks)` returns a message."""
    page = PAGE % {"title": title, "help": help_text, "mode": mode, "items": json.dumps(items)}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def reply(self, body, kind):
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/":
                return self.reply(page.encode(), "text/html; charset=utf-8")
            if self.path in files:
                return self.reply(files[self.path].read_bytes(), "audio/wav")
            self.send_error(404)

        def do_POST(self):
            picks = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            self.reply(save(picks).encode(), "text/plain; charset=utf-8")

    server = ThreadingHTTPServer(("127.0.0.1", 8765), Handler)
    print(f"open http://127.0.0.1:8765  (Ctrl-C when done)", flush=True)
    if sys.stdout.isatty():
        import subprocess
        subprocess.run(["open", "http://127.0.0.1:8765"], check=False)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


def ab(a=None, b=None):
    if not a or not b:
        sys.exit("ab: name two runs")
    ids = sorted({w.stem for w in run_dir(a).glob("*.wav")} & {w.stem for w in run_dir(b).glob("*.wav")})
    same = [pid for pid in ids if (run_dir(a) / f"{pid}.wav").read_bytes() == (run_dir(b) / f"{pid}.wav").read_bytes()]
    if same:
        print(f"left out, identical in both runs: {', '.join(same)}")
    ids = [pid for pid in ids if pid not in same]
    rng = random.Random()
    order = {pid: rng.random() < 0.5 for pid in ids}   # True: A is run b
    rng.shuffle(ids)
    files, items = {}, []
    for pid in ids:
        first, second = (b, a) if order[pid] else (a, b)
        files[f"/{pid}/A.wav"], files[f"/{pid}/B.wav"] = run_dir(first) / f"{pid}.wav", run_dir(second) / f"{pid}.wav"
        items.append({"id": pid, "text": spoken(pid), "audio": [["A", f"/{pid}/A.wav"], ["B", f"/{pid}/B.wav"]]})

    def save(picks):
        votes = {a: 0, b: 0, "same": 0}
        detail = {}
        for pid, pick in picks.items():
            first, second = (b, a) if order[pid] else (a, b)
            winner = {"A": first, "B": second}.get(pick, "same")
            votes[winner] += 1
            detail[pid] = winner
        out = EVAL / "ab" / f"{a}__{b}__{time.strftime('%Y%m%d-%H%M%S')}.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps({"a": a, "b": b, "votes": votes, "picks": detail}, indent=1))
        decided = votes[a] + votes[b]
        share = votes[b] / decided if decided else 0
        message = (f"{b} preferred in {votes[b]} of {decided} decided pairs ({share:.0%}), {a} in {votes[a]}, "
                   f"{votes['same']} the same. Saved {out.relative_to(ROOT)}")
        print(message, flush=True)
        return message

    serve(f"Blind A/B, {len(ids)} passages", "Each pair is the same passage read two ways, in random order. "
          "Listen to both, pick the better reading (or Same), then Save. Which run is which stays hidden until you save.",
          "ab", items, files, save)


def rate(name=None):
    if not name:
        sys.exit("rate: name a run")
    ids = sorted({w.stem for w in run_dir(name).glob("*.wav")} & {w.stem for w in REFERENCES.glob("*.wav")})
    files, items = {}, []
    for pid in ids:
        files[f"/{pid}/unread.wav"], files[f"/{pid}/elevenlabs.wav"] = run_dir(name) / f"{pid}.wav", REFERENCES / f"{pid}.wav"
        items.append({"id": pid, "text": spoken(pid),
                      "audio": [["ElevenLabs", f"/{pid}/elevenlabs.wav"], ["Unread", f"/{pid}/unread.wav"]]})

    def save(picks):
        scores = {}
        for key, value in picks.items():
            pid, axis = key.split("/")
            scores.setdefault(axis, []).append(int(value))
        out = EVAL / "ratings" / f"{name}__{time.strftime('%Y%m%d-%H%M%S')}.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps({"run": name, "picks": picks}, indent=1))
        message = ", ".join(f"{axis} {np.mean(v):.1f}" for axis, v in sorted(scores.items())) + f". Saved {out.relative_to(ROOT)}"
        print(message, flush=True)
        return message

    serve(f"{name} against ElevenLabs", "How close does Unread come to the ElevenLabs reading? 1 is far, 5 is as good. "
          "Prosody: stress, intonation, phrasing. Seams: how sentences and paragraphs join. Emotion: does it feel the text.",
          "rate", items, files, save)


if __name__ == "__main__":
    step, rest = sys.argv[1], sys.argv[2:]
    {"passages": passages, "elevenlabs": lambda: elevenlabs(*rest), "score": lambda: score(*rest),
     "ab": lambda: ab(*rest), "rate": lambda: rate(*rest)}[step]()
