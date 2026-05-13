"""
screenai_brain.py
=================
Headless 'brain' helper process.

The native app shell launches this as a child process via `Process` and
communicates with it over stdin/stdout using newline-delimited JSON.
The brain handles everything platform-neutral:

  - Login HTTP POST to the auth endpoint
  - Scan HTTP POST to the scan endpoint
  - Usage GET
  - LaTeX → readable Unicode conversion of AI responses
  - Settings load/save under ~/Library/Application Support/
  - Machine-ID derivation from IOPlatformUUID

stdin   one JSON command per line
stdout  one JSON event  per line   (consumed by the app shell)
stderr  free-form log messages     (the app shell may capture for debugging)

This file is forked from the Windows-side `screenai_lockdown.py`. All Win32,
tkinter, ctypes, customtkinter, DLL-injection, and shared-memory code has
been stripped. The LaTeX converter, scan logic, login flow, and usage poll
are carried over verbatim where they were already platform-neutral.
"""

import sys
import os
import io
import json
import time
import base64
import hashlib
import platform
import re
import subprocess
import threading
from typing import Any, Dict, Optional

import requests
from PIL import Image


# =============================================================================
#  Exception types
# =============================================================================

class _DeviceLimitError(Exception):
    """Server rejected login because the account is already on N devices."""
    pass


# =============================================================================
#  LaTeX → readable Unicode
# =============================================================================
# AI providers return math as LaTeX (\frac{}{}, \sqrt{}, ^2, etc.). The
# Swift overlay renders the brain's output verbatim, so we convert here
# before sending the answer back. Not a full LaTeX renderer — just the
# common patterns that appear in student-facing math answers.

_GREEK = {
    'alpha':'α','beta':'β','gamma':'γ','delta':'δ','epsilon':'ε','varepsilon':'ε',
    'zeta':'ζ','eta':'η','theta':'θ','vartheta':'ϑ','iota':'ι','kappa':'κ',
    'lambda':'λ','mu':'μ','nu':'ν','xi':'ξ','omicron':'ο','pi':'π','varpi':'ϖ',
    'rho':'ρ','varrho':'ϱ','sigma':'σ','varsigma':'ς','tau':'τ','upsilon':'υ',
    'phi':'φ','varphi':'ϕ','chi':'χ','psi':'ψ','omega':'ω',
    'Gamma':'Γ','Delta':'Δ','Theta':'Θ','Lambda':'Λ','Xi':'Ξ','Pi':'Π',
    'Sigma':'Σ','Upsilon':'Υ','Phi':'Φ','Psi':'Ψ','Omega':'Ω',
}

_SYMBOLS = {
    'cdot':'·','times':'×','div':'÷','ast':'∗','star':'⋆','bullet':'•',
    'pm':'±','mp':'∓','oplus':'⊕','ominus':'⊖','otimes':'⊗','oslash':'⊘',
    'neq':'≠','ne':'≠','leq':'≤','le':'≤','geq':'≥','ge':'≥',
    'll':'≪','gg':'≫','approx':'≈','sim':'∼','simeq':'≃','cong':'≅','equiv':'≡',
    'propto':'∝',
    'sum':'Σ','prod':'∏','coprod':'∐','int':'∫','iint':'∬','iiint':'∭','oint':'∮',
    'infty':'∞','infin':'∞','partial':'∂','nabla':'∇',
    'in':'∈','notin':'∉','ni':'∋','subset':'⊂','supset':'⊃',
    'subseteq':'⊆','supseteq':'⊇','cup':'∪','cap':'∩','setminus':'∖',
    'emptyset':'∅','varnothing':'∅','forall':'∀','exists':'∃','nexists':'∄',
    'angle':'∠','measuredangle':'∡','parallel':'∥','perp':'⊥',
    'rightarrow':'→','to':'→','leftarrow':'←','gets':'←',
    'Rightarrow':'⇒','Leftarrow':'⇐','leftrightarrow':'↔','Leftrightarrow':'⇔',
    'mapsto':'↦','longrightarrow':'⟶','longleftarrow':'⟵',
    'circ':'°','degree':'°','prime':'′','dprime':'″',
    'dots':'…','ldots':'…','cdots':'⋯','vdots':'⋮','ddots':'⋱',
    'land':'∧','wedge':'∧','lor':'∨','vee':'∨','neg':'¬','lnot':'¬',
    'aleph':'ℵ','hbar':'ℏ','Re':'ℜ','Im':'ℑ','ell':'ℓ','wp':'℘',
    'therefore':'∴','because':'∵','square':'□','blacksquare':'■',
    'triangle':'△','triangledown':'▽',
    'leftharpoonup':'↼','rightharpoonup':'⇀',
    'lceil':'⌈','rceil':'⌉','lfloor':'⌊','rfloor':'⌋',
    'langle':'⟨','rangle':'⟩',
}

_SUPERSCRIPTS = {
    '0':'⁰','1':'¹','2':'²','3':'³','4':'⁴','5':'⁵','6':'⁶','7':'⁷','8':'⁸','9':'⁹',
    '+':'⁺','-':'⁻','=':'⁼','(':'⁽',')':'⁾',
    'a':'ᵃ','b':'ᵇ','c':'ᶜ','d':'ᵈ','e':'ᵉ','f':'ᶠ','g':'ᵍ','h':'ʰ','i':'ⁱ',
    'j':'ʲ','k':'ᵏ','l':'ˡ','m':'ᵐ','n':'ⁿ','o':'ᵒ','p':'ᵖ','r':'ʳ','s':'ˢ',
    't':'ᵗ','u':'ᵘ','v':'ᵛ','w':'ʷ','x':'ˣ','y':'ʸ','z':'ᶻ',
}

_SUBSCRIPTS = {
    '0':'₀','1':'₁','2':'₂','3':'₃','4':'₄','5':'₅','6':'₆','7':'₇','8':'₈','9':'₉',
    '+':'₊','-':'₋','=':'₌','(':'₍',')':'₎',
    'a':'ₐ','e':'ₑ','h':'ₕ','i':'ᵢ','j':'ⱼ','k':'ₖ','l':'ₗ','m':'ₘ','n':'ₙ',
    'o':'ₒ','p':'ₚ','r':'ᵣ','s':'ₛ','t':'ₜ','u':'ᵤ','v':'ᵥ','x':'ₓ',
}


def _try_super(body: str) -> Optional[str]:
    """Return body with each char mapped to a superscript Unicode glyph, or
    None if any char has no superscript form (caller falls back to '^(...)')."""
    out = []
    for c in body:
        if c in _SUPERSCRIPTS:
            out.append(_SUPERSCRIPTS[c])
        else:
            return None
    return ''.join(out)


def _try_sub(body: str) -> Optional[str]:
    out = []
    for c in body:
        if c in _SUBSCRIPTS:
            out.append(_SUBSCRIPTS[c])
        else:
            return None
    return ''.join(out)


def _delatex(text: str) -> str:
    """Convert common LaTeX math notation to readable Unicode/plaintext.

    Handles: $..$ delimiters, \\frac, \\sqrt, super/subscripts, Greek letters,
    comparison operators, set theory, arrows, decorations, \\boxed, etc.
    Falls through gracefully on unknown commands (strips the backslash).
    """
    if not text:
        return text
    # Fast path — if none of the LaTeX trigger chars are present, skip work.
    if not any(c in text for c in ('\\', '$', '^', '_')):
        return text

    s = text

    # 1. Strip math-mode delimiters (keep the content)
    s = re.sub(r'\$\$([^$]*)\$\$', r'\1', s)
    s = re.sub(r'\$([^$]*)\$',     r'\1', s)
    s = s.replace(r'\(', '').replace(r'\)', '')
    s = s.replace(r'\[', '').replace(r'\]', '')

    # 2. \begin{env} ... \end{env} markers (keep body)
    s = re.sub(r'\\begin\{[^}]+\}', '', s)
    s = re.sub(r'\\end\{[^}]+\}',   '', s)

    # 3. Text-passthrough commands: \text{x}, \mathbf{x}, etc. → x
    for cmd in ('text','textrm','textbf','textit','textsf','texttt',
                'mathrm','mathbf','mathit','mathsf','mathtt',
                'operatorname','mbox','hbox','emph'):
        s = re.sub(r'\\' + cmd + r'\{([^{}]*)\}', r'\1', s)

    # 4. Decoration commands (overline, hat, vec, etc.) → drop decoration
    for cmd in ('overline','underline','widetilde','widehat',
                'bar','hat','vec','tilde','dot','ddot','check','breve',
                'acute','grave','cancel','sout','phantom'):
        s = re.sub(r'\\' + cmd + r'\{([^{}]*)\}', r'\1', s)

    # 5. \boxed{x} → [x] (signals "this is the answer")
    s = re.sub(r'\\boxed\{([^{}]*)\}', r'[\1]', s)

    # 5b. \mathbb{R} → ℝ (set-theory letters used in math answers).
    _BB = {'C':'ℂ','H':'ℍ','N':'ℕ','P':'ℙ','Q':'ℚ','R':'ℝ','Z':'ℤ'}
    s = re.sub(r'\\mathbb\{([^{}]*)\}',
               lambda m: ''.join(_BB.get(c, c) for c in m.group(1)), s)
    s = re.sub(r'\\mathcal\{([^{}]*)\}',  r'\1', s)
    s = re.sub(r'\\mathfrak\{([^{}]*)\}', r'\1', s)
    s = re.sub(r'\\mathscr\{([^{}]*)\}',  r'\1', s)

    # 6. Fractions, roots, binomials — loop because they can be mutually
    #    nested (e.g. \frac{\sqrt{\pi}}{2}). Each pass collapses one level.
    for _ in range(8):
        new = re.sub(r'\\sqrt\[([^\]]+)\]\{([^{}]*)\}', r'(\1)√(\2)', s)
        new = re.sub(r'\\sqrt\{([^{}]*)\}', r'√(\1)', new)
        new = re.sub(r'\\d?frac\{([^{}]*)\}\{([^{}]*)\}', r'(\1)/(\2)', new)
        new = re.sub(r'\\binom\{([^{}]*)\}\{([^{}]*)\}', r'C(\1,\2)', new)
        if new == s: break
        s = new

    # 7. Bracketed super/subscripts: x^{abc}, x_{abc}
    def _sup(m: 're.Match[str]') -> str:
        body = m.group(1)
        c = _try_super(body)
        return c if c is not None else '^(' + body + ')'

    def _sub(m: 're.Match[str]') -> str:
        body = m.group(1)
        c = _try_sub(body)
        return c if c is not None else '_(' + body + ')'

    s = re.sub(r'\^\{([^{}]*)\}', _sup, s)
    s = re.sub(r'_\{([^{}]*)\}',  _sub, s)

    # 8. Single-char super/subscripts: x^2, x_n
    s = re.sub(r'\^([0-9a-zA-Z+\-])',
               lambda m: _SUPERSCRIPTS.get(m.group(1), '^' + m.group(1)), s)
    s = re.sub(r'_([0-9a-zA-Z+\-])',
               lambda m: _SUBSCRIPTS.get(m.group(1), '_' + m.group(1)), s)

    # 9. \left( \right) → just the bracket
    s = re.sub(r'\\left\s*([\(\[\|\{\.])',
               lambda m: '' if m.group(1) == '.' else m.group(1), s)
    s = re.sub(r'\\right\s*([\)\]\|\}\.])',
               lambda m: '' if m.group(1) == '.' else m.group(1), s)

    # 10. Greek letters (longest first to avoid prefix collisions)
    for name, sym in sorted(_GREEK.items(), key=lambda x: -len(x[0])):
        s = re.sub(r'\\' + name + r'(?![a-zA-Z])', sym, s)

    # 11. Misc symbols (longest first)
    for name, sym in sorted(_SYMBOLS.items(), key=lambda x: -len(x[0])):
        s = re.sub(r'\\' + name + r'(?![a-zA-Z])', sym, s)

    # 12. \\ → newline; spacing commands → space
    s = re.sub(r'\\\\\s*', '\n', s)
    s = re.sub(r'\\(quad|qquad|,|;|:|!|\s)', ' ', s)

    # 13. Strip leftover braces around single tokens: {x} → x
    for _ in range(3):
        new = re.sub(r'\{([^{}]*)\}', r'\1', s)
        if new == s: break
        s = new

    # 14. Any remaining \word commands — drop the backslash, keep the word
    s = re.sub(r'\\([a-zA-Z]+)', r'\1', s)

    # 15. Collapse runs of whitespace introduced by command stripping
    s = re.sub(r' {2,}', ' ', s)
    s = re.sub(r'\n{3,}', '\n\n', s)

    return s


# =============================================================================
#  Machine-ID (macOS hardware UUID)
# =============================================================================

def get_machine_id() -> str:
    """Stable SHA-256 hex digest unique to this Mac.
    Reads IOPlatformUUID from `ioreg` plus hostname. Same shape as the
    Windows version (sha256 hex), so the screenai.site backend can compare
    against device-limit records without caring which OS produced it."""
    uuid_str = ""
    try:
        out = subprocess.check_output(
            ["ioreg", "-d2", "-c", "IOPlatformExpertDevice"],
            text=True, timeout=2,
        )
        for line in out.splitlines():
            if "IOPlatformUUID" in line:
                uuid_str = line.split("=")[-1].strip().strip('"')
                break
    except Exception:
        pass
    try:
        host = platform.node() or ""
    except Exception:
        host = ""
    return hashlib.sha256(f"{uuid_str}|{host}".encode("utf-8")).hexdigest()


# =============================================================================
#  Backend endpoints
# =============================================================================
# NOTE: These literal strings end up in the compiled binary. For v1 we leave
# them in plaintext; if Respondus ever scans process memory for known cheat-
# tool URLs we can chunk + base64-decode them at runtime.

AUTH_URL  = "https://screenai.site/api/auth/login"
SCAN_URL  = "https://screenai.site/api/scan"
USAGE_URL = "https://screenai.site/api/usage"


# =============================================================================
#  Provider mapping
# =============================================================================

_PROVIDER_NAMES = ["grok", "openai", "gemini", "claude"]


def prov_label(name: str) -> str:
    """Human-readable provider name used in error messages."""
    return {
        "grok":   "Grok",
        "openai": "ChatGPT",
        "gemini": "Gemini",
        "claude": "Claude",
    }.get(name, name.title() if name else "AI")


# =============================================================================
#  Settings (persisted to ~/Library/Application Support/Color Calibration/)
# =============================================================================

# CALIB_SETTINGS_DIR env var overrides the default location — used by
# the test suite to point at a tempdir so unit tests don't clobber the
# real settings file.  In production the Swift app does NOT set this.
SETTINGS_DIR  = os.environ.get(
    "CALIB_SETTINGS_DIR",
    os.path.expanduser("~/Library/Application Support/Color Calibration"),
)
SETTINGS_FILE = os.path.join(SETTINGS_DIR, "settings.json")

# Same fields as the Windows version with two changes:
#   - "boot_mode" / "bubble" replaced by "panel_enabled" + "bubble_enabled"
#     so both modes can be active simultaneously (per the macOS plan).
#   - "ldb_dir" removed (no DLL injection on Mac).
SETTINGS_DEFAULT: Dict[str, Any] = {
    "resp_mode":      1,        # 0=minimal 1=concise 2=detailed
    "panel_enabled":  True,     # main overlay panel visible
    "bubble_enabled": False,    # cursor bubble visible
    "bubble_follow":  True,     # bubble follows cursor after answer
    "txtsz":          1,        # 0=small 1=med 2=large
    "display_secs":   12,       # bubble auto-hide seconds (3-60)
    "corner":         0,        # 0=TR 1=TL 2=BR 3=BL
    "inv_mul":        3,        # invisible-tab size multiplier (2-6)
    "ctx_on":         False,    # context memory across scans
    "inv_mode":       False,    # invisible-tab mode persisted state
    "ai_provider":    "grok",   # "grok" | "openai" | "gemini" | "claude"
    "dismiss_zone":   False,    # opposite-corner dismiss zone (bubble mode)
    # Week 4 — appearance preferences
    "theme_mode":         0,    # 0=dark 1=light (ThemeMode raw)
    "transparency_mode":  1,    # 0=full 1=medium 2=low (TransparencyMode raw)
}


def _load_settings() -> Dict[str, Any]:
    try:
        with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        out = dict(SETTINGS_DEFAULT)
        # Only keep known keys — silently drop anything unrecognised so
        # settings from an older / newer build don't crash us.
        out.update({k: v for k, v in data.items() if k in SETTINGS_DEFAULT})
        return out
    except Exception:
        return dict(SETTINGS_DEFAULT)


def _save_settings(s: Dict[str, Any]) -> None:
    try:
        os.makedirs(SETTINGS_DIR, exist_ok=True)
        with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
            json.dump(s, f, indent=2)
    except Exception as e:
        emit_log("err", f"settings save failed: {e}")


# =============================================================================
#  IPC primitives — JSON-over-stdio
# =============================================================================
#
# Protocol:
#   - Swift → brain:  one JSON object per line on stdin
#                     {"cmd": "<name>", ...args}
#   - brain → Swift:  one JSON object per line on stdout
#                     {"evt": "<name>", ...payload}
#   - stderr is reserved for free-form human-readable logs; the Swift app
#     may capture it for debugging but doesn't parse it.
#
# All stdout writes go through `emit()` which holds a mutex — multiple
# worker threads can call it concurrently without interleaving output.

_IO_LOCK = threading.Lock()


def emit(evt: Dict[str, Any]) -> None:
    """Write a single event line to stdout. Thread-safe; flushed immediately."""
    with _IO_LOCK:
        try:
            sys.stdout.write(json.dumps(evt, ensure_ascii=False) + "\n")
            sys.stdout.flush()
        except Exception:
            # If stdout dies the parent is gone — nothing we can do.
            pass


def emit_log(level: str, msg: str) -> None:
    """Emit a structured log event AND mirror to stderr for human reading."""
    try:
        sys.stderr.write(f"[{level}] {msg}\n")
        sys.stderr.flush()
    except Exception:
        pass
    emit({"evt": "log", "level": level, "msg": msg})


# =============================================================================
#  Brain state
# =============================================================================

class BrainState:
    """Mutable state shared across command handlers."""
    def __init__(self) -> None:
        self.token: Optional[str] = None
        self.settings: Dict[str, Any] = _load_settings()
        # Last successful scan — used for context follow-ups when ctx_on is true.
        self.last_b64: Optional[str] = None
        self.last_answer: Optional[str] = None
        self.lock = threading.Lock()


# =============================================================================
#  Command handlers
# =============================================================================

def handle_login(state: BrainState, cmd: Dict[str, Any]) -> None:
    email = cmd.get("email", "")
    pw    = cmd.get("password", "")
    mid   = cmd.get("machine_id") or get_machine_id()

    if not email or not pw:
        emit({"evt": "login_err", "code": "bad_creds",
              "msg": "Email and password required."})
        return

    try:
        r = requests.post(AUTH_URL, json={
            "email": email,
            "password": pw,
            "machine_id": mid,
        }, timeout=15)
    except requests.exceptions.Timeout:
        emit({"evt": "login_err", "code": "network",
              "msg": "Login timed out — check your internet."})
        return
    except requests.exceptions.ConnectionError:
        emit({"evt": "login_err", "code": "network",
              "msg": "Connection error — check your internet."})
        return
    except Exception as e:
        emit({"evt": "login_err", "code": "network",
              "msg": f"Network error: {e}"})
        return

    if r.status_code == 401:
        emit({"evt": "login_err", "code": "bad_creds",
              "msg": "Incorrect email or password."})
        return
    if r.status_code == 403:
        # Distinguish device-limit (specific error text) from "no plan"
        err_text = ""
        try:
            err_text = (r.json().get("error") or "")
        except Exception:
            pass
        if "device" in err_text.lower():
            emit({"evt": "login_err", "code": "device_limit",
                  "msg": err_text or "Account already in use on 2 devices."})
        else:
            emit({"evt": "login_err", "code": "no_plan",
                  "msg": "No active plan — subscribe at screenai.site"})
        return
    if not r.ok:
        emit({"evt": "login_err", "code": "network",
              "msg": f"Login failed ({r.status_code})."})
        return

    try:
        token = r.json()["token"]
    except Exception:
        emit({"evt": "login_err", "code": "network",
              "msg": "Server returned an invalid response."})
        return

    with state.lock:
        state.token = token
    emit({"evt": "login_ok", "token": token})


def handle_scan(state: BrainState, cmd: Dict[str, Any]) -> None:
    """Take a base64-encoded screenshot, crop, resize, POST to /api/scan."""
    if not state.token:
        emit({"evt": "scan_err", "msg": "Not logged in."})
        return

    img_b64  = cmd.get("image_b64", "")
    mode     = int(cmd.get("mode", state.settings.get("resp_mode", 1)))
    provider = cmd.get("provider") or state.settings.get("ai_provider", "grok")
    use_ctx  = bool(cmd.get("use_context", state.settings.get("ctx_on", False)))

    if not img_b64:
        emit({"evt": "scan_err", "msg": "No image provided."})
        return

    emit({"evt": "scan_progress", "stage": "preparing"})

    # Decode → crop top chrome → resize to 1280-wide → JPEG encode.
    # Matches the Windows-side image pipeline so the AI prompt sees the same
    # framing and scale on both platforms.
    try:
        raw = base64.b64decode(img_b64)
        img = Image.open(io.BytesIO(raw)).convert("RGB")
        CROP_TOP = max(100, int(img.height * 0.165))
        if img.height > CROP_TOP + 200:
            img = img.crop((0, CROP_TOP, img.width, img.height))
        MAX_W = 1280
        if img.width > MAX_W:
            ratio = MAX_W / img.width
            img = img.resize((MAX_W, int(img.height * ratio)), Image.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=85)
        scan_b64 = base64.b64encode(buf.getvalue()).decode()
    except Exception as e:
        emit({"evt": "scan_err", "msg": f"Image processing failed: {e}"})
        return

    # Build request body
    body: Dict[str, Any] = {
        "image": scan_b64,
        "mode": mode,
        "provider": provider,
    }
    if use_ctx and state.last_b64 and state.last_answer:
        body["context_image"]  = state.last_b64
        body["context_answer"] = state.last_answer

    label       = prov_label(provider)
    switch_hint = " — switch to a different AI in the dropdown"

    emit({"evt": "scan_progress", "stage": "waiting"})

    # Single attempt with a 90-second read timeout. Reasoning models can take
    # 30-60s legitimately; retrying just doubles the wait.
    try:
        resp = requests.post(
            SCAN_URL,
            headers={
                "Authorization": f"Bearer {state.token}",
                "Content-Type":  "application/json",
            },
            json=body,
            timeout=(10, 90),
        )
    except requests.exceptions.Timeout:
        emit({"evt": "scan_err", "msg": f"{label} timed out{switch_hint}"})
        return
    except requests.exceptions.ConnectionError:
        emit({"evt": "scan_err", "msg": "Connection error — check your internet"})
        return
    except Exception as e:
        emit({"evt": "scan_err", "msg": f"Network error: {e}"})
        return

    emit({"evt": "scan_progress", "stage": "parsing"})

    # Parse JSON, or surface the actual body when the server returns HTML
    # (Cloudflare 502/503 pages, etc.) so the user gets a useful error
    # instead of a generic "invalid JSON".
    data: Optional[Dict[str, Any]] = None
    try:
        data = resp.json()
    except Exception:
        body_text = (resp.text or "").strip()
        preview   = body_text[:120].replace("\n", " ")
        if not body_text:
            msg = f"{label} returned an empty response"
        elif resp.status_code in (502, 503, 504):
            msg = f"{label} backend is overloaded ({resp.status_code})"
        elif "<html" in body_text.lower() or "<!doctype" in body_text.lower():
            msg = f"{label} unavailable ({resp.status_code})"
        else:
            msg = f"{label} error ({resp.status_code}): {preview}"
        emit({"evt": "scan_err", "msg": msg + switch_hint})
        return

    # Surface usage info whenever the server includes it
    if isinstance(data, dict) and "tokens_used" in data:
        emit({
            "evt": "usage",
            "provider":          data.get("provider", provider),
            "tokens_used":       data.get("tokens_used"),
            "tokens_limit":      data.get("tokens_limit"),
            "tokens_remaining":  data.get("tokens_remaining"),
        })

    if not resp.ok:
        err = (data or {}).get("error", f"{label} error {resp.status_code}")
        # 401/403 are auth/plan issues — don't suggest "switch providers"
        if resp.status_code in (401, 403):
            emit({"evt": "scan_err", "msg": err})
        else:
            emit({"evt": "scan_err", "msg": err + switch_hint})
        return

    answer = ((data or {}).get("answer") or "").strip()
    if not answer:
        emit({"evt": "scan_err", "msg": f"{label} returned no answer{switch_hint}"})
        return

    answer = _delatex(answer)

    with state.lock:
        state.last_b64    = scan_b64
        state.last_answer = answer

    emit({
        "evt": "scan_ok",
        "answer":           answer,
        "provider":         (data or {}).get("provider", provider),
        "tokens_used":      (data or {}).get("tokens_used"),
        "tokens_remaining": (data or {}).get("tokens_remaining"),
    })


def handle_fetch_usage(state: BrainState, cmd: Dict[str, Any]) -> None:
    """GET /api/usage and emit the full per-provider usage map."""
    if not state.token:
        emit_log("warn", "fetch_usage: not logged in")
        return
    try:
        r = requests.get(
            USAGE_URL,
            headers={"Authorization": f"Bearer {state.token}"},
            timeout=10,
        )
        if r.ok:
            emit({"evt": "usage_full", "data": r.json()})
        else:
            emit_log("warn", f"fetch_usage HTTP {r.status_code}")
    except Exception as e:
        emit_log("warn", f"fetch_usage failed: {e}")


def handle_get_setting(state: BrainState, cmd: Dict[str, Any]) -> None:
    key = cmd.get("key", "")
    if key not in SETTINGS_DEFAULT:
        emit_log("warn", f"Unknown setting key: {key}")
        return
    with state.lock:
        val = state.settings.get(key)
    emit({"evt": "setting_value", "key": key, "value": val})


def handle_get_all_settings(state: BrainState, cmd: Dict[str, Any]) -> None:
    with state.lock:
        snapshot = dict(state.settings)
    emit({"evt": "all_settings", "values": snapshot})


def handle_set_setting(state: BrainState, cmd: Dict[str, Any]) -> None:
    key = cmd.get("key", "")
    val = cmd.get("value")
    if key not in SETTINGS_DEFAULT:
        emit_log("warn", f"Unknown setting key: {key}")
        return
    with state.lock:
        state.settings[key] = val
        _save_settings(state.settings)
    emit({"evt": "setting_value", "key": key, "value": val})


def handle_get_machine_id(state: BrainState, cmd: Dict[str, Any]) -> None:
    emit({"evt": "machine_id", "value": get_machine_id()})


def handle_logout(state: BrainState, cmd: Dict[str, Any]) -> None:
    with state.lock:
        state.token = None
        state.last_b64 = None
        state.last_answer = None
    emit({"evt": "logged_out"})


def handle_ping(state: BrainState, cmd: Dict[str, Any]) -> None:
    """Liveness check — Swift can periodically ping to confirm the brain is alive."""
    emit({"evt": "pong", "t": time.time()})


def handle_shutdown(state: BrainState, cmd: Dict[str, Any]) -> None:
    emit({"evt": "shutdown_ok"})
    # Flush before exiting so the Swift app gets the final event.
    try:
        sys.stdout.flush()
        sys.stderr.flush()
    except Exception:
        pass
    os._exit(0)


_HANDLERS = {
    "login":             handle_login,
    "scan":              handle_scan,
    "fetch_usage":       handle_fetch_usage,
    "get_setting":       handle_get_setting,
    "get_all_settings":  handle_get_all_settings,
    "set_setting":       handle_set_setting,
    "get_machine_id":    handle_get_machine_id,
    "logout":            handle_logout,
    "ping":              handle_ping,
    "shutdown":          handle_shutdown,
}

# Slow / network-bound commands run in worker threads so a 90 s scan doesn't
# block subsequent stdin reads. Everything else runs inline on the main loop
# so order is preserved (critical for cases like `get_machine_id` → `shutdown`
# where the response MUST flush before exit).
_ASYNC_COMMANDS = {"login", "scan", "fetch_usage"}


# =============================================================================
#  Dispatch
# =============================================================================

def dispatch(state: BrainState, line: str) -> None:
    """Parse a stdin line and dispatch. Slow commands run on a worker thread;
    fast commands run inline to preserve ordering with subsequent commands."""
    try:
        cmd = json.loads(line)
    except Exception as e:
        emit_log("err", f"Bad JSON from host: {e}")
        return
    name = cmd.get("cmd", "")
    h = _HANDLERS.get(name)
    if not h:
        emit_log("err", f"Unknown command: {name}")
        return
    if name in _ASYNC_COMMANDS:
        threading.Thread(
            target=h, args=(state, cmd), daemon=True,
            name=f"cmd-{name}",
        ).start()
    else:
        try:
            h(state, cmd)
        except Exception as e:
            emit_log("err", f"Handler {name} crashed: {e}")


# =============================================================================
#  Entry point
# =============================================================================

def main() -> None:
    # Critical: line-buffered stdout/stderr so events flush immediately.
    # Otherwise the Swift app sees nothing until the buffer fills.
    try:
        sys.stdout.reconfigure(line_buffering=True)
        sys.stderr.reconfigure(line_buffering=True)
    except Exception:
        pass

    state = BrainState()
    emit({"evt": "ready", "version": "1.0.0"})

    # Read commands until parent dies or sends EOF/shutdown.
    try:
        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue
            dispatch(state, line)
    except (KeyboardInterrupt, EOFError):
        pass

    emit_log("info", "stdin EOF — exiting")
    os._exit(0)


if __name__ == "__main__":
    main()
