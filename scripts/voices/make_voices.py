"""Makes the narrator's voice presets (#60) from scripts/voices/voices.json.

Run through scripts/make-voices.sh, which orders the steps and keeps the GPU ones at low priority.
Every step skips work whose output already exists, so a run can be stopped and started again.

    design    VoiceDesign says each new voice's reference sentence, several candidates each (GPU)
    asr       Whisper transcribes every candidate and preview that has no transcript yet (GPU)
    install   picks the best candidate whose transcript matches, writes Resources/Voices/<id>.{wav,json}
    previews  the app's own narrator (Neural Engine) reads the preview text in each installed voice
    finish    checks each preview, writes it as AAC .m4a, and records the voice's pace in its JSON
    report    one line per voice: candidates, rejections, pace, pitch
    audition  copies the previews, with readable names and an index, into a folder

Work files go to build/voices/<id>/ (gitignored).
"""
import gc
import json
import re
import shutil
import subprocess
import sys
import unicodedata
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[2]
SPEC = json.loads((Path(__file__).parent / "voices.json").read_text())
VOICES = ROOT / "Resources/Voices"
WORK = ROOT / "build/voices"
SR = 24_000
LANGUAGE = {"en": "English", "fr": "French"}

# Unread's own measure of quiet (Speech.quietLevel, Speech.window): peak under 0.01 in 10 ms windows.
QUIET, WINDOW = 0.01, 240
# The London storyteller's clip: 32 ms before the voice, 177 ms after it. New clips are cut the same way.
LEAD, TAIL = 0.05, 0.18
# Pacing: 0.5 s between sentences. Each sentence keeps 50 ms of its own quiet a side.
GAP, EDGE = 0.5, 0.05
# A designed clip must say its sentence at a natural pace (voiced characters a second) and in 4–8 s.
PACE_RANGE, SECONDS_RANGE = (13.0, 19.0), (4.0, 8.0)
# Median pitch a woman's or a man's voice is expected to be on the right side of, in Hz.
PITCH_LIMIT = {"woman": 150, "man": 175}


def voices(*, new_only=False):
    return [v for v in SPEC["voices"] if not (new_only and v.get("keep"))]


def work(v):
    d = WORK / v["id"]
    d.mkdir(parents=True, exist_ok=True)
    return d


def candidates(v):
    return [work(v) / f"cand-{k}.wav" for k in range(v.get("candidates", SPEC["candidates"]))]


def read(path):
    audio, sr = sf.read(path, dtype="float32")
    assert sr == SR and audio.ndim == 1, f"{path}: expected mono {SR} Hz"
    return audio


def write(path, audio):
    sf.write(path, np.clip(audio, -1, 1), SR, subtype="PCM_16")


def snapshot(role):
    """The model at its pinned revision, downloaded once into the Hugging Face cache."""
    from huggingface_hub import snapshot_download
    m = SPEC["models"][role]
    return snapshot_download(m["repo"], revision=m["revision"])


def free(model):
    import mlx.core as mx
    del model
    gc.collect()
    mx.clear_cache()


# MARK: audio measures

def loud_windows(audio):
    n = len(audio) // WINDOW
    return np.abs(audio[: n * WINDOW]).reshape(n, WINDOW).max(1) >= QUIET


def voiced_span(audio):
    """First and last voiced sample, as Unread's Speech would trim them."""
    loud = np.flatnonzero(loud_windows(audio))
    if loud.size == 0:
        return 0, 0
    return loud[0] * WINDOW, (loud[-1] + 1) * WINDOW


def longest_pause(audio):
    loud = loud_windows(audio)
    idx = np.flatnonzero(loud)
    if idx.size == 0:
        return 0.0
    run = best = 0
    for q in loud[idx[0]: idx[-1]]:
        run = 0 if q else run + 1
        best = max(best, run)
    return best * WINDOW / SR


def pitch_track(audio):
    """F0 in Hz per 40 ms frame (20 ms hop), voiced frames only: normalized autocorrelation, 60–400 Hz."""
    n, hop, lo, hi = 960, 480, SR // 400, SR // 60
    out = []
    for i in range(0, len(audio) - n - hi, hop):
        frame = audio[i: i + n + hi] - audio[i: i + n + hi].mean()
        head = frame[:n]
        energy = float(head @ head)
        if np.sqrt(energy / n) < 0.02:
            continue
        r = np.array([head @ frame[lag: lag + n] for lag in range(lo, hi)])
        norms = np.sqrt(energy * np.array([frame[lag: lag + n] @ frame[lag: lag + n] for lag in range(lo, hi)]))
        nr = r / np.maximum(norms, 1e-9)
        k = int(np.argmax(nr))
        if nr[k] > 0.6:
            out.append(SR / (lo + k))
    return np.array(out)


def pitch_measures(audio):
    """Median F0 and the share of frame-to-frame steps bigger than 7 semitones (cracks, octave slips)."""
    f0 = pitch_track(audio)
    if f0.size < 10:
        return None, None
    semis = 12 * np.log2(f0)
    jumps = float(np.mean(np.abs(np.diff(semis)) > 7))
    return float(np.median(f0)), jumps


# MARK: transcripts

def words(text):
    text = unicodedata.normalize("NFC", text.lower()).replace("’", "'")
    text = re.sub(r"[^\w' ]+", " ", text.replace("-", " "))
    return [w.strip("'") for w in text.split() if w.strip("'")]


def word_errors(said, expected):
    a, b = words(said), words(expected)
    d = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(b) + 1):
            prev, d[j] = d[j], min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] != b[j - 1]))
    return d[len(b)]


def transcript(wav):
    path = wav.with_suffix(".txt")
    return path.read_text().strip() if path.exists() else None


# MARK: steps

def design():
    import mlx.core as mx
    from mlx_audio.tts.utils import load_model
    jobs = [(v, k, path) for v in voices(new_only=True) if not (VOICES / f"{v['id']}.wav").exists()
            for k, path in enumerate(candidates(v)) if not path.exists()]
    if not jobs:
        return print("design: nothing to do")
    model = load_model(snapshot("design"))
    for v, k, path in jobs:
        mx.random.seed(k + 1)
        rs = model.generate_voice_design(text=SPEC["reference"][v["language"]], instruct=v["description"],
                                         language=LANGUAGE[v["language"]])
        audio = np.concatenate([np.asarray(r.audio, np.float32).reshape(-1) for r in rs])
        write(path, audio)
        print(f"design {v['id']} {k}: {len(audio) / SR:.1f} s", flush=True)
    free(model)


def asr():
    from mlx_audio.stt import load
    jobs = [(v, wav) for v in voices() for wav in candidates(v) + [work(v) / "preview.wav"]
            if wav.exists() and transcript(wav) is None]
    if not jobs:
        return print("asr: nothing to do")
    model = load(snapshot("asr"))
    for v, wav in jobs:
        text = model.generate(str(wav), language=v["language"], return_timestamps=False).text.strip()
        wav.with_suffix(".txt").write_text(text + "\n")
        print(f"asr {v['id']} {wav.name}: {text}", flush=True)
    free(model)


def judge(v, wav):
    """A candidate clip's measures, and why it's rejected (empty: usable)."""
    audio, text = read(wav), SPEC["reference"][v["language"]]
    start, end = voiced_span(audio)
    seconds = (end - start) / SR
    f0, jumps = pitch_measures(audio[start:end])
    said = transcript(wav)
    m = {"file": wav.name, "said": said, "errors": None if said is None else word_errors(said, text),
         "seconds": round(seconds, 2), "pace": round(len(text) / max(seconds, 1e-3), 1),
         "pause": round(longest_pause(audio), 2), "peak": round(float(np.abs(audio).max()), 2),
         "f0": f0 and round(f0), "jumps": jumps and round(jumps, 3)}
    why = []
    if m["errors"] is None:
        why.append("no transcript")
    elif m["errors"]:
        why.append(f"transcript off by {m['errors']} word(s): {said!r}")
    if not SECONDS_RANGE[0] <= seconds <= SECONDS_RANGE[1]:
        why.append(f"{seconds:.1f} s long")
    if not PACE_RANGE[0] <= m["pace"] <= PACE_RANGE[1]:
        why.append(f"pace {m['pace']} c/s")
    if m["pause"] > 0.7:
        why.append(f"{m['pause']} s pause inside")
    if m["peak"] >= 0.99:
        why.append("clipped")
    if f0 is None:
        why.append("no pitch")
    elif v["gender"] == "woman" and f0 < PITCH_LIMIT["woman"]:
        why.append(f"pitch {f0:.0f} Hz, low for a woman")
    elif v["gender"] == "man" and f0 > PITCH_LIMIT["man"]:
        why.append(f"pitch {f0:.0f} Hz, high for a man")
    if jumps is not None and jumps > 0.08:
        why.append(f"unsteady pitch ({jumps:.0%} jumps)")
    m["rejected"] = why
    return m


def install():
    for v in voices(new_only=True):
        wav, meta = VOICES / f"{v['id']}.wav", VOICES / f"{v['id']}.json"
        if wav.exists():
            continue
        judged = [judge(v, c) for c in candidates(v) if c.exists()]
        (work(v) / "candidates.json").write_text(json.dumps(judged, indent=1, ensure_ascii=False))
        usable = [m for m in judged if not m["rejected"]]
        if not usable:
            print(f"install {v['id']}: no usable candidate; " + "; ".join(f"{m['file']}: {', '.join(m['rejected'])}" for m in judged))
            continue
        # The pace nearest 15.5 c/s (natural; the London storyteller's clip is ~11.6), and the steadiest pitch:
        # each 1% of pitch jumps past 2% weighs like 0.3 c/s. Jumps are partly the tracker's octave slips on high voices.
        best = min(usable, key=lambda m: abs(m["pace"] - 15.5) + 30 * max(0, m["jumps"] - 0.02))
        audio = read(work(v) / best["file"])
        start, end = voiced_span(audio)
        audio = audio[max(0, start - int(LEAD * SR)): end + int(TAIL * SR)]
        # The London clip's loudness: speech RMS ~0.1, peaks ~0.6.
        voiced = audio[np.abs(audio) > QUIET]
        audio *= min(0.1 / np.sqrt(np.mean(voiced ** 2)), 0.9 / np.abs(audio).max())
        write(wav, audio)
        write_meta(v, {"audio": wav.name, "transcript": SPEC["reference"][v["language"]], "candidate": best["file"]})
        print(f"install {v['id']}: {best['file']} ({best['pace']} c/s, F0 {best['f0']} Hz)")


def write_meta(v, extra):
    path = VOICES / f"{v['id']}.json"
    meta = json.loads(path.read_text()) if path.exists() else {}
    meta.update({"name": v["name"], "language": v["language"], "summary": v["summary"], "description": v["description"],
                 "source": "Designed with Qwen3-TTS 1.7B VoiceDesign from the description above. A synthetic voice, not a real person's."})
    meta.update(extra)
    meta.pop("candidate", None)
    order = ["name", "language", "summary", "description", "source", "audio", "transcript", "preview", "pace"]
    path.write_text(json.dumps({k: meta[k] for k in order if k in meta}, indent=2, ensure_ascii=False) + "\n")


def previews(app):
    for v in voices():
        out = work(v) / "preview.wav"
        if out.exists() or not (VOICES / f"{v['id']}.json").exists():
            continue
        cmd = [app, "--narrate", *SPEC["preview"][v["language"]], "--voice", v["id"], "--runs", "1", "--out", str(out)]
        log = subprocess.run(cmd, capture_output=True, text=True)
        (work(v) / "preview.log").write_text(log.stdout + log.stderr)
        print(f"previews {v['id']}: " + ("ok" if out.exists() else f"failed, see {work(v) / 'preview.log'}"), flush=True)


def sentences_of(audio):
    """The preview's sentences: `--narrate` puts 0.5 s of digital silence after each."""
    zero = np.abs(audio) == 0
    cuts, run, start = [], 0, 0
    for i, z in enumerate(zero):
        if z:
            run += 1
            continue
        if run >= int(0.4 * SR):
            cuts.append(audio[start: i - run])
            start = i
        run = 0
    cuts.append(audio[start: len(audio) - run])
    return [c for c in cuts if c.size]


def finish():
    for v in voices():
        wav, m4a = work(v) / "preview.wav", VOICES / f"{v['id']}-preview.m4a"
        if not wav.exists() or m4a.exists():
            continue
        texts = SPEC["preview"][v["language"]]
        said = transcript(wav)
        parts = sentences_of(read(wav))
        if said is None or len(parts) != len(texts):
            print(f"finish {v['id']}: {'no transcript' if said is None else f'{len(parts)} sentences'}, skipped")
            continue
        errors = word_errors(said, " ".join(texts))
        spans = [voiced_span(p) for p in parts]
        paces = [len(t) / ((e - s) / SR) for t, (s, e) in zip(texts, spans)]
        pitch = [pitch_measures(p[s:e]) for p, (s, e) in zip(parts, spans)]
        medians = [f for f, _ in pitch if f]
        check = {"errors": errors, "said": said, "paces": [round(p, 1) for p in paces],
                 "f0": [round(f) for f in medians], "jumps": [round(j, 3) for _, j in pitch if j is not None],
                 "f0_spread_semitones": round(12 * np.log2(max(medians) / min(medians)), 1)}
        (work(v) / "preview.json").write_text(json.dumps(check, indent=1, ensure_ascii=False))
        if errors > 1:
            print(f"finish {v['id']}: preview transcript off by {errors} words: {said!r}; not shipped")
            continue
        # As reading plays it: 50 ms of each sentence's quiet kept a side, 0.5 s between them.
        edge, gap = int(EDGE * SR), np.zeros(int(GAP * SR), np.float32)
        joined = []
        for p, (s, e) in zip(parts, spans):
            joined += [p[max(0, s - edge): e + edge], gap]
        trimmed = work(v) / "preview-paced.wav"
        write(trimmed, np.concatenate(joined[:-1]))
        subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "48000", "-q", "127", str(trimmed), str(m4a)], check=True)
        write_meta(v, {"preview": m4a.name, "pace": round(float(np.median(paces)), 1)})
        print(f"finish {v['id']}: {m4a.stat().st_size // 1024} KB, pace {np.median(paces):.1f} c/s, F0 {check['f0']}, "
              f"{errors} word error(s)")


def report():
    rows = []
    for v in voices():
        cands = work(v) / "candidates.json"
        judged = json.loads(cands.read_text()) if cands.exists() else []
        preview = work(v) / "preview.json"
        p = json.loads(preview.read_text()) if preview.exists() else {}
        meta = VOICES / f"{v['id']}.json"
        pace = json.loads(meta.read_text()).get("pace") if meta.exists() else None
        rows.append({"id": v["id"], "language": v["language"], "candidates": len(judged),
                     "rejected": {m["file"]: m["rejected"] for m in judged if m["rejected"]},
                     "pace": pace, "preview": p})
        rej = "; ".join(f"{f}: {', '.join(r)}" for f, r in rows[-1]["rejected"].items())
        print(f"{v['language']} {v['id']:22} pace {pace or '–':>4}  preview errors {p.get('errors', '–')}  "
              f"F0 {p.get('f0', '–')} spread {p.get('f0_spread_semitones', '–')} st  "
              f"{len(judged) - len(rows[-1]['rejected'])}/{len(judged)} usable  {rej}")
    (WORK / "report.json").write_text(json.dumps(rows, indent=1, ensure_ascii=False))


def audition(folder):
    out = Path(folder).expanduser()
    out.mkdir(parents=True, exist_ok=True)
    index = []
    for lang in ("en", "fr"):
        n = 0
        for v in voices():
            m4a = VOICES / f"{v['id']}-preview.m4a"
            if v["language"] != lang or not m4a.exists():
                continue
            n += 1
            name = f"{lang.upper()} {n:02d} {v['name']} ({v['gender']}).m4a"
            shutil.copy(m4a, out / name)
            meta = json.loads((VOICES / f"{v['id']}.json").read_text())
            index.append(f"{name}\n  {v['summary']}. Pace {meta.get('pace')} characters a second.\n  {v['description']}\n")
    (out / "index.txt").write_text("\n".join(index))
    print(f"audition: {len(index)} previews in {out}")


if __name__ == "__main__":
    step, rest = sys.argv[1], sys.argv[2:]
    {"design": design, "asr": asr, "install": install, "finish": finish, "report": report,
     "previews": lambda: previews(*rest), "audition": lambda: audition(*rest)}[step]()
