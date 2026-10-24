#!/usr/bin/env python3
import fcntl
import glob
import html
import json
import os
import random
import re
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone

# Change Here For Your Container Name
CONTAINER = "minecraft-server"
# ===== Settings =====
MINECRAFT_PATH = "/root/minecraft/data"
BASE_DIR = "/root/shammat"
RESPONSES_FILE = f"{BASE_DIR}/responses.json"
TEXTS_FILE = f"{BASE_DIR}/texts.json"                    # all bot texts (change language here only)
BACKUP_PLAYERS_FILE = f"{BASE_DIR}/backup_players.json"  # in-game names allowed to run !backup
STATS_FILE = f"{BASE_DIR}/stats.json"
STATE_FILE = f"{BASE_DIR}/state.json"
OFFSET_FILE = f"{BASE_DIR}/tg_offset"
WHITELIST_FILE = f"{MINECRAFT_PATH}/whitelist.json"
TG_ENV = f"{BASE_DIR}/.telegram.env"
BACKUP_CMD = [f"{BASE_DIR}/backup.sh", "--now"]
BACKUP_DIR = "/root/backups"
BACKUP_LOG = f"{BASE_DIR}/backup.log"
LOCK_FILE = "/tmp/shammat_backup.lock"
BACKUP_COUNTDOWN = 60          # seconds of warning when players are online
FRIENDS = []   # if ALL of them are online, deaths/advancements skip Telegram
SMART_TG_PREFIXES = ("death_", "advancement", "join", "leave")  # categories that follow the rule above ["death_", "advancement", "join", "leave"]
BOT_NAME = "Shammat"
POLL_TIMEOUT = 50
MAX_AGE = 120                  # ignore Telegram commands older than this (seconds)
RESYNC_SECONDS = 60            # how often to re-read the online list from the server
RESUME_MAX_AGE = 600           # resume log reading after restart only if state is newer than this
RANDOM_AMBIENT_BOOT_AT = time.time()
LINE = "━━━━━━━━━━━━━━━━━━"
# ====================


def log(msg):
    print(f"[{datetime.now():%F %T}] {msg}", flush=True)


def load_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


ENV = load_env(TG_ENV)
TOKEN = ENV["BOT_TOKEN"]
MAIN_CHAT = str(ENV["CHAT_ID"])
EXTRA_CHAT = ENV.get("GROUP_CHAT_ID", "")
ALLOWED_CHATS = {c for c in (MAIN_CHAT, EXTRA_CHAT) if c}
ADMIN_IDS = {x.strip() for x in ENV.get("TG_ADMIN_IDS", "").split(",") if x.strip()}
API = f"https://api.telegram.org/bot{TOKEN}"

# ---------- shared state ----------
STATE_LOCK = threading.Lock()
ONLINE_LOCK = threading.Lock()
SAVE_LOCK = threading.Lock()
RLOCK = threading.Lock()
SLOCK = threading.Lock()
online = set()
known = set()
LAST_TS = ""
suppress_leaves = False
countdown_active = False
cancel_event = threading.Event()
cancel_by = ""


# ---------- json helpers ----------
def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def save_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


# ---------- texts (loaded from TEXTS_FILE) ----------
TEXTS_LOCK = threading.Lock()
_texts = {"mtime": None, "data": {}}


def load_texts(force=False):
    """(Re)load TEXTS_FILE when it changed. On a bad file the last good texts are kept."""
    with TEXTS_LOCK:
        try:
            mtime = os.path.getmtime(TEXTS_FILE)
        except OSError as e:
            if _texts["mtime"] != "missing":
                log(f"Texts file unavailable: {e}")
                _texts["mtime"] = "missing"
            return bool(_texts["data"])
        if not force and mtime == _texts["mtime"]:
            return True
        _texts["mtime"] = mtime
        try:
            with open(TEXTS_FILE, encoding="utf-8") as f:
                data = json.load(f)
            if not isinstance(data, dict):
                raise ValueError("top level must be an object")
            _texts["data"] = data
            return True
        except Exception as e:
            log(f"Texts file invalid, keeping previous texts: {e}")
            return bool(_texts["data"])


def txt_raw(key):
    load_texts()
    with TEXTS_LOCK:
        val = _texts["data"].get(key)
    if val is None:
        log(f"Missing text key: {key}")
    return val


def txt(key, **fields):
    """Return the text for `key` with {placeholders} filled. {line} and {bot} are always available."""
    val = txt_raw(key)
    if not isinstance(val, str):
        return key
    base = {"line": LINE, "bot": BOT_NAME}
    base.update(fields)
    return fmt(val, base)


# ---------- backup players (loaded from BACKUP_PLAYERS_FILE) ----------
_backup_players = {"mtime": None, "data": []}


def get_backup_players():
    """Names allowed to run !backup in game. Empty list = everyone (same as before).
    The file is re-read when it changes; an invalid file keeps the last good list."""
    with TEXTS_LOCK:
        if not os.path.exists(BACKUP_PLAYERS_FILE):
            try:
                save_json(BACKUP_PLAYERS_FILE, {"backup_players": []})
            except Exception as e:
                log(f"Could not create {BACKUP_PLAYERS_FILE}: {e}")
        try:
            mtime = os.path.getmtime(BACKUP_PLAYERS_FILE)
        except OSError:
            return list(_backup_players["data"])
        if mtime == _backup_players["mtime"]:
            return list(_backup_players["data"])
        _backup_players["mtime"] = mtime
        try:
            with open(BACKUP_PLAYERS_FILE, encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                data = data.get("backup_players", [])
            if not isinstance(data, list):
                raise ValueError("backup_players must be a list")
            _backup_players["data"] = [str(x) for x in data]
        except Exception as e:
            log(f"Backup players file invalid, keeping previous list: {e}")
        return list(_backup_players["data"])


# ---------- persistent state ----------
def save_state():
    with SAVE_LOCK:
        with ONLINE_LOCK:
            snap = {"online": sorted(online), "known": sorted(known),
                    "last_ts": LAST_TS, "saved_at": int(time.time())}
        try:
            save_json(STATE_FILE, snap)
        except Exception as e:
            log(f"Could not save state: {e}")


def load_state():
    global LAST_TS
    st = load_json(STATE_FILE, {})
    with ONLINE_LOCK:
        online.update(st.get("online", []))
        known.update(st.get("known", []))
        known.update(FRIENDS)
    LAST_TS = st.get("last_ts", "")
    # also learn names from the server whitelist
    for entry in load_json(WHITELIST_FILE, []):
        name = entry.get("name") if isinstance(entry, dict) else None
        if name:
            with ONLINE_LOCK:
                known.add(name)
    return st


def get_online():
    with ONLINE_LOCK:
        return set(online)


def is_known(name):
    low = name.lower()
    with ONLINE_LOCK:
        return name in known or name in online or low in {f.lower() for f in FRIENDS}


def mark_online(name):
    with ONLINE_LOCK:
        changed = name not in online
        online.add(name)
        known.add(name)
    if changed:
        save_state()


def mark_offline(name):
    with ONLINE_LOCK:
        online.discard(name)
        empty = not online
    save_state()
    return empty


def set_online(names):
    with ONLINE_LOCK:
        online.clear()
        online.update(names)
        known.update(names)
    save_state()


def friends_both_online():
    for f in list(known):
        if "fakeplayer" not in f.lower():
            if "chunkplayer" not in f.lower():
                if f.lower() not in [x.lower() for x in FRIENDS]:
                    FRIENDS.append(f.lower())
    cur = {
        n.lower()
        for n in get_online()
        if "fakeplayer" not in n.lower()
    }

    return all(
        f.lower() in cur
        for f in FRIENDS
        if "fakeplayer" not in f.lower()
    )


# ---------- Telegram ----------
def esc(s):
    return html.escape(str(s), quote=False)


def tg_api(method, params=None, timeout=30):
    data = urllib.parse.urlencode(params or {}).encode()
    try:
        with urllib.request.urlopen(f"{API}/{method}", data=data, timeout=timeout) as r:
            return json.load(r)
    except Exception as e:
        log(f"Telegram {method} failed: {e}")
        return None


def tg_send(text, chat=None, buttons=None, html_mode=False):
    params = {"chat_id": chat or MAIN_CHAT, "text": text,
              "disable_web_page_preview": "true"}
    if html_mode:
        params["parse_mode"] = "HTML"
    if buttons:
        params["reply_markup"] = json.dumps({"inline_keyboard": buttons})
    return tg_api("sendMessage", params)


def tg_answer_callback(cb_id, text=""):
    tg_api("answerCallbackQuery", {"callback_query_id": cb_id, "text": text})


def menu_text():
    return txt("menu.text")


def menu_buttons():
    return [
        [{"text": txt("menu.btn_online"), "callback_data": "online"},
         {"text": txt("menu.btn_status"), "callback_data": "status"}],
        [{"text": txt("menu.btn_deaths"), "callback_data": "deaths"},
         {"text": txt("menu.btn_roast"), "callback_data": "roast"}],
        [{"text": txt("menu.btn_lastbackup"), "callback_data": "lastbackup"}],
    ]


def register_commands():
    cmds = [(c, txt(f"cmd.{c}")) for c in
            ("menu", "online", "status", "deaths", "roast", "say",
             "lastbackup", "backup", "cancel")]
    tg_api("setMyCommands", {"commands": json.dumps(
        [{"command": c, "description": d} for c, d in cmds])})
    
# ---------- Minecraft (RCON through docker) ----------
def rcon(cmd):
    try:
        r = subprocess.run(["docker", "exec", CONTAINER, "rcon-cli", cmd],
                           capture_output=True, text=True, timeout=20)
        return r.stdout.strip()
    except Exception as e:
        log(f"rcon failed: {e}")
        return ""


def game_say(text, color="yellow"):
    comp = [{"text": f"[{BOT_NAME}] ", "color": "gold", "bold": True},
            {"text": text, "color": color}]
    out = rcon("tellraw @a " + json.dumps(comp))
    log(f"Game tellraw attempted; response={out!r}")


def refresh_online():
    """Ask the server who is online. Returns None if the server did not answer."""
    out = rcon("list")
    m = re.search(r"online:\s*(.*)", out)
    if not m:
        return None
    names = {n.strip() for n in m.group(1).split(",") if n.strip()}
    set_online(names)
    return names


def resync_loop():
    while True:
        time.sleep(RESYNC_SECONDS)
        try:
            if not backup_running():
                refresh_online()
            save_state()
        except Exception as e:
            log(f"Resync error: {e}")


# ---------- responses (shuffle bag) ----------
class SafeDict(dict):
    def __missing__(self, key):
        return "{" + key + "}"


def fmt(text, fields):
    try:
        return text.format_map(SafeDict(fields))
    except Exception:
        return text


def line_key(line):
    return line.get("game") or line.get("tg") or ""


def pick_line(category, **fields):
    with RLOCK:
        data = load_json(RESPONSES_FILE, None)
        if data is None:
            log("responses.json is missing or invalid, skipping reply.")
            return None
        cat = data.get("categories", {}).get(category)
        if not cat or not cat.get("lines"):
            log(f"No response lines configured for category: {category}")
            return None
        lines = cat["lines"]
        avail = cat.get("available_value", False)

        def eligible():
            return [l for l in lines if l.get("used", avail) == avail]

        pool = eligible()
        if not pool:
            avail = not avail
            cat["available_value"] = avail
            pool = eligible()
        if not pool:
            return None
        last = cat.get("last")
        if len(pool) > 1:
            pool = [l for l in pool if line_key(l) != last]
        chosen = random.choice(pool)
        chosen["used"] = not avail
        cat["last"] = line_key(chosen)
        save_json(RESPONSES_FILE, data)

    game = chosen.get("game") or chosen.get("tg") or ""
    tg = chosen.get("tg") or chosen.get("game") or ""
    return fmt(game, fields), fmt(tg, fields)


def announce(category, chat=None, to_game=True, to_tg=True, **fields):
    res = pick_line(category, **fields)
    if not res:
        return
    game_text, tg_text = res
    # Smart rule: when all friends are in the server, they see it in game, so skip Telegram
    if to_tg and chat is None and category.startswith(SMART_TG_PREFIXES) and friends_both_online():
        to_tg = False
    if to_game:
        game_say(game_text)
    if to_tg:
        tg_send(tg_text, chat)


# ---------- stats ----------
def add_death(player):
    with SLOCK:
        s = load_json(STATS_FILE, {})
        d = s.setdefault("deaths", {})
        d[player] = d.get(player, 0) + 1
        save_json(STATS_FILE, s)
        return d[player]


def deaths_top(limit=5):
    with SLOCK:
        d = load_json(STATS_FILE, {}).get("deaths", {})
    return sorted(d.items(), key=lambda kv: kv[1], reverse=True)[:limit]


# ---------- backup ----------
def backup_running():
    fd = os.open(LOCK_FILE, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    except OSError:
        return True
    finally:
        os.close(fd)


def request_backup(who):
    global countdown_active
    with STATE_LOCK:
        if countdown_active:
            return "countdown"
        if backup_running():
            return "busy"
        countdown_active = True
    cancel_event.clear()
    threading.Thread(target=backup_worker, args=(who,), daemon=True).start()
    return "started"


def cancel_backup(who):
    global cancel_by
    with STATE_LOCK:
        if not countdown_active:
            return False
        cancel_by = who
    cancel_event.set()
    return True


def backup_worker(who):
    global countdown_active
    try:
        if get_online():
            announce("backup_countdown", player=who, seconds=BACKUP_COUNTDOWN)
            if cancel_event.wait(BACKUP_COUNTDOWN):
                announce("backup_cancelled", player=cancel_by or txt("fallback.someone"))
                return
            announce("backup_start", player=who)
            time.sleep(2)
        else:
            tg_send(txt("backup.no_players_tg", player=who))
        logf = open(BACKUP_LOG, "a")
        subprocess.Popen(BACKUP_CMD, stdout=logf, stderr=logf, start_new_session=True)
    except Exception as e:
        log(f"backup worker error: {e}")
    finally:
        with STATE_LOCK:
            countdown_active = False
            

# ---------- formatted Telegram texts ----------
def fmt_uptime(secs):
    d, rem = divmod(secs, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    return (f"{d}d " if d else "") + f"{h}h {m}m"


def text_online():
    names = refresh_online()
    if names is None:
        names = get_online()
        note = txt("online.stale_note")
    else:
        note = ""
    if not names:
        return txt("online.empty", note=note)
    rows = "\n".join(txt("online.row", name=esc(n)) for n in sorted(names))
    return txt("online.list", count=len(names), rows=rows, note=note)

def text_deaths():
    top = deaths_top()
    if not top:
        return txt("deaths.empty")
    medals = ["🥇", "🥈", "🥉", "4️⃣", "5️⃣"]
    rows = "\n".join(txt("deaths.row", medal=medals[i], name=esc(n), count=c) for i, (n, c) in enumerate(top))
    return txt("deaths.list", rows=rows)


def text_status():
    r = subprocess.run(["docker", "inspect", "-f", "{{.State.Status}}|{{.State.StartedAt}}", CONTAINER], capture_output=True, text=True)
    if r.returncode != 0 or "|" not in r.stdout:
        return txt("status.not_found")
    status, started = r.stdout.strip().split("|", 1)
    icon = "🟢" if status == "running" else "🔴"
    lines = [txt("status.title"), LINE, txt("status.state", icon=icon, status=esc(status))]
    if status == "running":
        t = datetime.strptime(started[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
        secs = int((datetime.now(timezone.utc) - t).total_seconds())
        lines.append(txt("status.uptime", uptime=fmt_uptime(secs)))
        names = refresh_online()
        if names is not None:
            lines.append(txt("status.players", count=len(names)))
    if backup_running():
        lines.append(txt("status.backup_running"))
    return "\n".join(lines)


def text_lastbackup():
    dirs = sorted(glob.glob(f"{BACKUP_DIR}/minecraft_*/"), key=os.path.getmtime, reverse=True)
    if not dirs:
        return txt("lastbackup.none")
    newest = dirs[0]
    size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(newest) for f in fs)
    when = datetime.fromtimestamp(os.path.getmtime(newest)).strftime("%Y-%m-%d %H:%M")
    return txt("lastbackup.info",
             name=esc(os.path.basename(newest.rstrip('/'))),
             when=when,
             size=f"{size / 1024 / 1024:.1f}",
             count=len(dirs))
    

def handle_tg(upd, m):
    chat = str(m["chat"]["id"])
    if chat not in ALLOWED_CHATS:
        return
    if time.time() - m.get("date", 0) > MAX_AGE:
        return
    text = m.get("text")
    if not text:
        return

    is_channel = "channel_post" in upd
    uid = str(m.get("from", {}).get("id", ""))
    is_admin = (is_channel and chat == MAIN_CHAT) or uid in ADMIN_IDS
    who = (m.get("from", {}).get("first_name") or m.get("chat", {}).get("title") or txt("fallback.telegram"))

    raw = re.sub(r"@\w+", "", text).strip()
    low = re.sub(r"\s+", " ", raw.lower())
    parts = raw.split(None, 1)
    head = parts[0].lower() if parts else ""
    arg = parts[1].strip() if len(parts) > 1 else ""

    if low in ("backup now", "/backup now", "/backup", "/backup_now", "/backupnow"):
        if not is_admin:
            tg_send(txt("backup.admin_only"), chat, html_mode=True)
            return
        status = request_backup(who)
        if status == "busy":
            tg_send(txt("backup.busy"), chat, html_mode=True)
        elif status == "countdown":
            tg_send(txt("backup.countdown_running"), chat, html_mode=True)
        else:
            tg_send(txt("backup.received"), chat, html_mode=True)
    elif head == "/cancel":
        if not is_admin:
            tg_send(txt("cancel.admin_only"), chat, html_mode=True)
            return
        if cancel_backup(who):
            tg_send(txt("cancel.done"), chat, html_mode=True)
        else:
            tg_send(txt("cancel.nothing_tg"), chat, html_mode=True)
    elif head == "/online":
        tg_send(text_online(), chat, html_mode=True)
    elif head == "/status":
        tg_send(text_status(), chat, html_mode=True)
    elif head == "/lastbackup":
        tg_send(text_lastbackup(), chat, html_mode=True)
    elif head == "/deaths":
        tg_send(text_deaths(), chat, html_mode=True)
    elif head == "/say":
        if not arg:
            tg_send(txt("say.usage"), chat, html_mode=True)
        else:
            comp = [{"text": txt("say.game_tag"), "color": "aqua", "bold": True},
                    {"text": f"{who}: {arg}", "color": "white"}]
            rcon("tellraw @a " + json.dumps(comp))
            tg_send(txt("say.sent"), chat, html_mode=True)
    elif head == "/roast":
        names = list(get_online())
        if not names:
            tg_send(txt("roast.nobody"), chat, html_mode=True)
        else:
            announce("roast", chat=chat, player=random.choice(names), by=who)
    elif head in ("/help", "/start", "/menu"):
        tg_send(menu_text(), chat, buttons=menu_buttons(), html_mode=True)
        

def handle_callback(cb):
    msg = cb.get("message") or {}
    chat = str(msg.get("chat", {}).get("id", ""))
    if chat not in ALLOWED_CHATS:
        return
    data = cb.get("data", "")
    who = cb.get("from", {}).get("first_name", txt("fallback.callback_user"))
    tg_answer_callback(cb["id"])

    if data == "online":
        tg_send(text_online(), chat, html_mode=True)
    elif data == "status":
        tg_send(text_status(), chat, html_mode=True)
    elif data == "deaths":
        tg_send(text_deaths(), chat, html_mode=True)
    elif data == "lastbackup":
        tg_send(text_lastbackup(), chat, html_mode=True)
    elif data == "roast":
        names = list(get_online())
        if not names:
            tg_send(txt("roast.nobody"), chat, html_mode=True)
        else:
            announce("roast", chat=chat, player=random.choice(names), by=who)


def tg_loop():
    try:
        offset = int(open(OFFSET_FILE).read().strip())
    except Exception:
        offset = 0
    tg_api("deleteWebhook")
    log("Telegram listener started.")
    while True:
        resp = tg_api("getUpdates", {
            "offset": offset, "timeout": POLL_TIMEOUT,
            "allowed_updates": json.dumps(["message", "channel_post", "callback_query"])},
            timeout=POLL_TIMEOUT + 20)
        if not resp or not resp.get("ok"):
            time.sleep(5)
            continue
        for upd in resp["result"]:
            offset = upd["update_id"] + 1
            with open(OFFSET_FILE, "w") as f:
                f.write(str(offset))
            try:
                if "callback_query" in upd:
                    handle_callback(upd["callback_query"])
                    continue
                m = upd.get("channel_post") or upd.get("message")
                if m:
                    handle_tg(upd, m)
            except Exception as e:
                log(f"Telegram handler error: {e}")


# ---------- in-game commands ----------
def handle_chat_command(player, text):
    cmd, _, arg = text.strip().partition(" ")
    cmd = cmd.lower()
    arg = arg.strip()

    if cmd == "!help":
        help_colors = ["yellow", "green", "red", "green", "green", "green", "green"]
        for n, line in enumerate(txt_raw("help.game") or []):
            game_say(line, help_colors[n] if n < len(help_colors) else "green")
    elif cmd == "!backup":
        backup_players = get_backup_players()
        if backup_players and player not in backup_players:
            announce("backup_denied", player=player)
            return
        status = request_backup(player)
        if status == "busy":
            announce("backup_busy", to_tg=False, player=player)
        elif status == "countdown":
            game_say(txt("backup.countdown_game"), "yellow")
    elif cmd == "!cancel":
        if not cancel_backup(player):
            game_say(txt("cancel.nothing_game"), "gray")
    elif cmd == "!tg":
        if not arg:
            game_say(txt("tg.usage_game"), "gray")
        else:
            tg_send(txt("tg.to_telegram", player=esc(player), message=esc(arg)), html_mode=True)
            game_say(txt("tg.sent_game"), "green")
    elif cmd == "!roast":
        targets = [p for p in get_online() if p != player] or [player]
        announce("roast", to_tg=True, player=random.choice(targets), by=player)
    elif cmd == "!deaths":
        top = deaths_top(3)
        if not top:
            game_say(txt("deaths.none_game"), "gray")
        else:
            game_say(txt("deaths.top_game", list=txt("deaths.top_sep").join(
                txt("deaths.top_item", name=n, count=c) for n, c in top)), "red")
    elif cmd == "!online":
        game_say(txt("online.count_game", count=len(get_online())), "green")

# ---------- log parsing ----------
# Supports "[time] [Thread/INFO]: msg" and Fabric style "[time] [Thread/INFO] (Minecraft) msg"
LOG_RE = re.compile(r"^\[[^\]]*\](?: \[[^\]]*\])*:? (?:\([^)]*\) )?(.*)$")
PREFIX_RE = re.compile(r"^\[Not Secure\] ")
SYSTEM_CHAT_RE = re.compile(r"^System chat:\s*", re.IGNORECASE)
JOIN_RE = re.compile(r"^(\w{1,16}) joined the game$")
LEAVE_RE = re.compile(r"^(\w{1,16}) left the game$")
ADV_RE = re.compile(r"^(\w{1,16}) has (?:made the advancement|completed the challenge|reached the goal) \[(.+)\]$")
CHAT_RE = re.compile(r"^<(\w{1,16})> (.*)$")
DEATH_LINE_RE = re.compile(r"^(\w{1,16}) (.+)$")

DEATH_HINTS = (
    "was slain", "was shot", "was killed", "was blown up", "blew up", "was fireballed",
    "was pummeled", "was pricked", "was impaled", "was squashed", "was skewered",
    "was stung", "was struck", "was poked", "was burned", "was roasted", "was frozen",
    "was obliterated", "was doomed", "was squished", "fell", "hit the ground",
    "drowned", "burned to death", "went up in flames", "walked into", "tried to swim",
    "starved", "suffocated", "withered away", "froze to death", "died",
    "didn't want to live", "discovered the floor", "experienced kinetic energy",
    "left the confines",
)


def classify_death(rest):
    r = rest.lower()
    km = re.search(r" by (.+?)(?: using .+)?$", rest)
    killer = km.group(1) if km else ""
    if "fell out of the world" in r or "confines" in r or "void" in r:
        return "death_void", killer
    if "lava" in r:
        return "death_lava", killer
    if "drowned" in r:
        return "death_drown", killer
    if "blew up" in r or "blown up" in r:
        return "death_explosion", killer
    if killer:
        if killer in get_online() or is_known(killer):
            return "death_pvp", killer
        return "death_mob", killer
    if any(w in r for w in ("burned", "flames", "fire")):
        return "death_fire", killer
    if "starved" in r:
        return "death_starve", killer
    if any(w in r for w in ("fell", "hit the ground", "doomed to fall")):
        return "death_fall", killer
    return "death_generic", killer


def handle_log_line(text):
    global suppress_leaves
    m = LOG_RE.match(text)
    if not m:
        return
    msg = PREFIX_RE.sub("", m.group(1))
    # Some Fabric/server versions wrap death messages as "System chat: <player> ...".
    msg = SYSTEM_CHAT_RE.sub("", msg)

    if msg.startswith("Stopping"):
        suppress_leaves = True
        return
    if msg.startswith("Done ("):
        suppress_leaves = False
        set_online(set())
        announce("server_ready", to_game=False)
        return

    jm = JOIN_RE.match(msg)
    if jm:
        name = jm.group(1)
        mark_online(name)
        threading.Timer(3, announce, args=("join",), kwargs={"player": name}).start()
        return

    lm = LEAVE_RE.match(msg)
    if lm:
        name = lm.group(1)
        empty = mark_offline(name)
        if not suppress_leaves:
            announce("leave", to_game=False, player=name)
            if empty:
                announce("server_empty", to_game=False)
        return

    am = ADV_RE.match(msg)
    if am:
        mark_online(am.group(1))      # whoever gets an advancement is online
        announce("advancement", player=am.group(1), advancement=am.group(2))
        return

    cm = CHAT_RE.match(msg)
    if cm:
        mark_online(cm.group(1))      # whoever chats is online
        if cm.group(2).startswith("!"):
            threading.Thread(target=handle_chat_command, args=(cm.group(1), cm.group(2)), daemon=True).start()
        return

    # Death detection does not depend on the online list, only on a known player name
    dm = DEATH_LINE_RE.match(msg)
    if dm:
        victim, rest = dm.group(1), dm.group(2)
        looks_like_death = any(h in rest.lower() for h in DEATH_HINTS)
        if looks_like_death:
            if not is_known(victim):
                log(f"Death-like log line ignored because player is unknown: {msg!r}")
                return
            mark_online(victim)       # a dead player was online
            cat, killer = classify_death(rest)
            count = add_death(victim)
            log(f"Detected death: player={victim}, category={cat}, killer={killer or 'unknown'}")
            announce(cat, player=victim, killer=killer, count=count)
            return


def initial_since():
    """Resume from the saved log position after a restart, if it is recent enough."""
    if LAST_TS:
        try:
            t = datetime.strptime(LAST_TS[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
            if (datetime.now(timezone.utc) - t).total_seconds() < RESUME_MAX_AGE:
                return LAST_TS
        except Exception:
            pass
    return str(int(time.time()))


def log_loop():
    global LAST_TS
    since = initial_since()
    ts_re = re.compile(r"^\d{4}-\d\d-\d\dT")
    last_saved = time.time()
    while True:
        cmd = ["docker", "logs", "-f", "--timestamps", "--since", since, CONTAINER]
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, errors="replace", bufsize=1)
            for raw in proc.stdout:
                raw = raw.rstrip("\r\n")
                ts, _, text = raw.partition(" ")
                if not ts_re.match(ts):
                    continue
                if LAST_TS and ts <= LAST_TS:
                    continue
                LAST_TS = ts
                try:
                    handle_log_line(text)
                except Exception as e:
                    log(f"Log handler error: {e}")
                if time.time() - last_saved > 15:
                    save_state()
                    last_saved = time.time()
            proc.wait()
        except Exception as e:
            log(f"Log follower error: {e}")
        if LAST_TS:
            since = LAST_TS
        save_state()
        time.sleep(3)

def random_ambient_tick():
    try:
        now = time.time()
        state = load_json(RESPONSES_FILE, {})

        if not isinstance(state, dict):
            state = {}
            
        def random_interval():
            roll = random.random()
            if roll < 0.42:
                return random.randint(5 * 60, 15 * 60)
            if roll < 0.76:
                return random.randint(15 * 60, 30 * 60)
            if roll < 0.94:
                return random.randint(30 * 60, 45 * 60)
            return random.randint(45 * 60, 75 * 60)

        next_send = state.get("next_send_at")

        if not isinstance(next_send, (int, float)):
            state["next_send_at"] = now + random_interval()
            save_json(RESPONSES_FILE, state)
            return

        if next_send <= RANDOM_AMBIENT_BOOT_AT:
            state["next_send_at"] = now + random_interval()
            state["rescheduled_after_restart_at"] = now
            save_json(RESPONSES_FILE, state)
            return

        if now < next_send:
            return

        players = list(get_online())

        with ONLINE_LOCK:
            known_players = list(known)

        hour = datetime.now().hour
        player = random.choice(players) if players else (
            random.choice(known_players) if known_players else txt("fallback.friend")
        )

        if not players:
            category = "ambient_empty"
        elif hour >= 23 or hour < 5:
            category = (
                "ambient_late"
                if random.random() < 0.58
                else "ambient_online"
            )
        else:
            category = "ambient_online"

        result = pick_line(
            category,
            player=player,
            count=len(players),
            hour=datetime.now().strftime("%H:%M"),
        )

        if not result:
            state["next_send_at"] = now + random_interval()
            save_json(RESPONSES_FILE, state)
            return

        game_text, tg_text = result

        state["next_send_at"] = now + random_interval()
        state["last_attempt_at"] = now
        state["last_category"] = category

        save_json(RESPONSES_FILE, state)

        channels = []

        if players:
            game_say(game_text, "gray")
            channels.append("game")

            if random.random() < 0.24:
                tg_send(tg_text)
                channels.append("telegram")
        else:
            tg_send(tg_text)
            channels.append("telegram")

        sent_at = time.time()

        history = state.get("history", [])
        if not isinstance(history, list):
            history = []

        history.append({
            "timestamp": sent_at,
            "datetime_utc": datetime.fromtimestamp(
                sent_at, timezone.utc
            ).isoformat(),
            "category": category,
            "message": game_text if players else tg_text,
            "channels": channels,
        })

        state["history"] = history[-100:]
        state["last_sent_at"] = sent_at

        save_json(RESPONSES_FILE, state)

    except Exception as e:
        log(f"Random ambient error: {e}")

def main():
    log(f"Bot starting (container: {CONTAINER}).")
    if not load_texts(force=True):
        log(f"Cannot start: {TEXTS_FILE} is missing or invalid.")
        raise SystemExit(1)
    st = load_state()
    log(f"Loaded state: online={sorted(online)} known={len(known)}")
    refresh_online()   # authoritative if the server answers, otherwise keep the saved state
    threading.Thread(target=tg_loop, daemon=True).start()
    threading.Thread(target=resync_loop, daemon=True).start()
    register_commands()
    random_ambient_tick()
    tg_send(txt("boot.started"), html_mode=True)
    log_loop()


if __name__ == "__main__":
    main()
