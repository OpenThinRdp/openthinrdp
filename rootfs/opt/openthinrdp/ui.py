#!/usr/bin/python3
# OpenThinRDP screens for the user, all on the background of the site (gradient BG_TOP/BG_BOTTOM, the background
# picture above a white card). Started by kiosk.sh (and schedule.sh, browser.sh), which handle what follows.
#
#   ui.py login ...      sign-in screen: card with user, password, Sign in; clock and date top left, information and
#                        settings top right (with the network, --t-net), power (restart, shut down) bottom right, web
#                        button and device bottom left.
#                        Exit: 10 = sign in ("user|password|" on stdout), 3 = settings, 4 = diagnostics, 8 = the network
#                        (Wi-Fi page), 5 = shut down, 6 = restart, 7 = web button. "--class=OtrLogin" stays on the
#                        command line: kiosk.sh
#                        closes it with pkill -f -- '--class=OtrLogin'.
#   ui.py message ...    a message: icon, heading, text, buttons (--button LABEL:CODE, in this order; --primary CODE
#                        is drawn as the main one, --default CODE has the focus, so Enter presses it).
#                        --timeout N: closes after N seconds with code 70 (a bar shows the time left).
#                        --progress: reads the yad progress protocol on stdin (a number = percent, "# text" = text)
#                        and ends with code 0 at the end of the input.
#                        --update: progress of the software update that is installing; ends when it is over.
#   ui.py toast ...      small notice in the top right corner with the progress of the software update; ends with it.
#                        --while-file PATH: a plain notice (no bar, warning icon) that stays while PATH exists
#                        (remote-screen.sh: "Remote assistance active").
#   ui.py form ...       the settings of the device: sections on the left, every field with its hint (spec on stdin,
#                        see below). Exit: 0 = save (KEY=value lines on stdout), 11 = close, 12 = terminal.
#   ui.py pin ...        the settings PIN: 0 = OK (the PIN on stdout), 11 = cancel.
#   ui.py text ...       a text read from stdin as it arrives (diagnostics), with Close.
#   ui.py wifi ...       the Wi-Fi: networks around, one chosen, its password, connect and the result here (wifi.sh).
#                        Texts on stdin ("key<TAB>text"). Exit: 0 = a network joined, 11 = closed.
import argparse, locale, math, os, subprocess, sys, time
import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
from gi.repository import Gtk, Gdk, GdkPixbuf, GLib

MODE = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('-') else 'login'
ap = argparse.ArgumentParser()
for a in ('class', 'title', 'heading', 'text', 'small', 'info', 'note', 'user', 'logo', 'splash', 'top', 'bottom',
          'web', 'icon', 'timeout', 'primary', 'default', 'lang',
          't-user', 't-password', 't-signin', 't-shutdown', 't-restart', 't-settings', 't-diag', 't-power',
          't-save', 't-close', 't-terminal', 't-net',
          'open-power'):     # open-power: tests only, the power menu open (for a screenshot)
    ap.add_argument('--' + a, default='')
ap.add_argument('--button', action='append', default=[])
ap.add_argument('--progress', action='store_true')
ap.add_argument('--update', action='store_true')
ap.add_argument('--while-file', default='')
A = ap.parse_args(sys.argv[2:] if MODE != 'login' or (len(sys.argv) > 1 and sys.argv[1] == 'login') else sys.argv[1:])
try:
    locale.setlocale(locale.LC_ALL, "")      # day and month in the language of the system
except locale.Error:
    pass

PROGRESS_FILE = '/run/openthinrdp-update-progress'   # "percent version", written by auto-update.sh and install.sh
ACCENT = '#2563eb'

def rgb(h, default):
    c = Gdk.RGBA()
    return c if c.parse(h or default) else (c.parse(default) and c)

CSS = b"""
.card { background: #ffffff; border-radius: 16px; padding: 30px 34px 26px 34px; }
.heading { color: #1f2937; font-size: 17px; font-weight: bold; }
.text { color: #374151; font-size: 14px; }
.small, .note { color: #64748b; font-size: 12px; }
.card entry { min-height: 40px; font-size: 15px; border-radius: 8px; border: 1px solid #cbd5e1; background: #f8fafc;
              color: #111827; padding: 0 10px; box-shadow: none; }
.card entry:focus { border-color: #2563eb; background: #ffffff; }
.signin, .primary { background: #2563eb; color: #ffffff; font-size: 15px; font-weight: bold; min-height: 42px;
          border-radius: 8px; border: none; box-shadow: none; background-image: none; text-shadow: none; padding: 0 18px; }
.signin:hover, .primary:hover { background: #1d4ed8; }
.secondary { background: #eef2f7; color: #1f2937; font-size: 15px; min-height: 42px; border-radius: 8px; border: none;
             box-shadow: none; background-image: none; text-shadow: none; padding: 0 18px; }
.secondary:hover { background: #e2e8f0; }
.primary:focus, .secondary:focus { outline-color: #93c5fd; }
progressbar trough { min-height: 8px; border-radius: 4px; background: #e5e7eb; border: none; }
progressbar progress { min-height: 8px; border-radius: 4px; background: #2563eb; border: none; }
.corner { background: rgba(255,255,255,0.10); border-radius: 22px; border: none; box-shadow: none; background-image: none;
          min-width: 44px; min-height: 44px; padding: 0; }
.corner:hover { background: rgba(255,255,255,0.22); }
.webbtn { background: rgba(255,255,255,0.10); color: #ffffff; border-radius: 22px; border: none; box-shadow: none;
          background-image: none; min-height: 44px; padding: 0 18px; font-size: 14px; text-shadow: none; }
.webbtn:hover { background: rgba(255,255,255,0.22); }
.clock { color: #ffffff; font-size: 34px; font-weight: 300; }
.date, .device { color: rgba(255,255,255,0.75); font-size: 13px; }
popover { background: #ffffff; border-radius: 10px; }
popover button { background: transparent; border: none; box-shadow: none; background-image: none; color: #111827;
                 font-size: 14px; min-height: 38px; padding: 0 18px; }
popover button:hover { background: #eef2f7; }
.toast { background: #ffffff; border-radius: 12px; padding: 14px 18px; }
.card combobox button { min-height: 40px; font-size: 15px; border-radius: 8px; border: 1px solid #cbd5e1; background: #f8fafc;
                        background-image: none; box-shadow: none; color: #111827; padding: 0 10px; text-shadow: none; }
.card combobox button:focus { border-color: #2563eb; }
.field { color: #1f2937; font-size: 14px; font-weight: bold; }
.hint { color: #64748b; font-size: 12px; }
.card entry.readonly { background: #f1f5f9; color: #475569; }
stacksidebar { border-right: 1px solid #e5e7eb; }
stacksidebar list { background: transparent; }
stacksidebar separator { min-height: 0; background: transparent; }
stacksidebar row { padding: 11px 16px; border-radius: 8px; margin: 0 10px 2px 0; color: #1f2937; font-size: 14px; }
stacksidebar row:selected { background: #dbeafe; color: #1d4ed8; }
stacksidebar row:hover:not(:selected) { background: #f1f5f9; }
.mono { font-family: Monospace; font-size: 13px; color: #111827; }
.netpill { background: rgba(255,255,255,0.10); color: #ffffff; border-radius: 22px; border: none; box-shadow: none;
           background-image: none; min-height: 44px; padding: 0 16px; font-size: 14px; text-shadow: none; }
.netpill:hover { background: rgba(255,255,255,0.22); }
.netpill.down { background: rgba(220,38,38,0.85); }
.wifirow { padding: 10px 12px; border-radius: 8px; }
.wifiname { color: #111827; font-size: 15px; }
.wifimeta { color: #64748b; font-size: 12px; }
.result-ok { color: #15803d; font-size: 14px; font-weight: bold; }
.result-err { color: #b91c1c; font-size: 14px; font-weight: bold; }
.result-busy { color: #1d4ed8; font-size: 14px; }
"""

# icons drawn here: the image has no icon theme. White on the background, coloured in a card.
COLORS = {'info': (0.15, 0.39, 0.92), 'ok': (0.09, 0.64, 0.29), 'warn': (0.85, 0.47, 0.02),
          'error': (0.86, 0.15, 0.15), 'power': (0.15, 0.39, 0.92), 'busy': (0.15, 0.39, 0.92),
          'update': (0.15, 0.39, 0.92)}

def icon(kind, size=22, color=(1, 1, 1), alpha=0.92):
    d = Gtk.DrawingArea(halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER); d.set_size_request(size, size)
    state = {'a': 0.0}
    def draw(w, cr):
        s = size; c = s / 2; r, g, b = color
        cr.set_source_rgba(r, g, b, alpha); cr.set_line_width(max(2.0, s / 11)); cr.set_line_cap(1)
        if kind == 'power':
            cr.arc(c, c + s * 0.04, s * 0.36, -math.pi / 2 + 0.75, 3 * math.pi / 2 - 0.75); cr.stroke()
            cr.move_to(c, s * 0.09); cr.line_to(c, c + s * 0.04); cr.stroke()
        elif kind in ('info', 'error', 'warn'):
            cr.arc(c, c, s * 0.42, 0, 2 * math.pi); cr.stroke()
            if kind == 'info':
                cr.arc(c, s * 0.30, s * 0.06, 0, 2 * math.pi); cr.fill()
                cr.move_to(c, s * 0.44); cr.line_to(c, s * 0.74); cr.stroke()
            else:
                cr.move_to(c, s * 0.26); cr.line_to(c, s * 0.58); cr.stroke()
                cr.arc(c, s * 0.72, s * 0.06, 0, 2 * math.pi); cr.fill()
        elif kind == 'ok':
            cr.arc(c, c, s * 0.42, 0, 2 * math.pi); cr.stroke()
            cr.move_to(s * 0.30, s * 0.52); cr.line_to(s * 0.45, s * 0.66); cr.line_to(s * 0.71, s * 0.37); cr.stroke()
        elif kind in ('busy', 'update'):
            cr.set_source_rgba(r, g, b, 0.18); cr.arc(c, c, s * 0.40, 0, 2 * math.pi); cr.stroke()
            cr.set_source_rgba(r, g, b, alpha); cr.arc(c, c, s * 0.40, state['a'], state['a'] + 1.6); cr.stroke()
        elif kind == 'gear':
            for i in range(8):
                cr.save(); cr.translate(c, c); cr.rotate(i * math.pi / 4); cr.rectangle(-2, -s * 0.47, 4, s * 0.2)
                cr.fill(); cr.restore()
            cr.arc(c, c, s * 0.30, 0, 2 * math.pi); cr.stroke()
            cr.arc(c, c, s * 0.11, 0, 2 * math.pi); cr.stroke()
    d.connect('draw', draw)
    if kind in ('busy', 'update'):
        def spin():
            state['a'] = (state['a'] + 0.25) % (2 * math.pi); d.queue_draw(); return True
        GLib.timeout_add(50, spin)
    return d

# The network the device is on, read as the kiosk user (no root): the cable first (a carrier), else the Wi-Fi it
# is joined to. ('wired'|'wifi'|'none', name of the Wi-Fi, bars 0-4, address or '')
def net_state():
    def addr(i):
        try:
            out = subprocess.run(['ip', '-4', '-o', 'addr', 'show', 'dev', i, 'scope', 'global'], capture_output=True, text=True, timeout=3).stdout
            return out.split()[3].split('/')[0] if out.split() else ''
        except Exception:
            return ''
    try:
        nics = sorted(os.listdir('/sys/class/net'))
    except OSError:
        nics = []
    for i in nics:
        if i.startswith(('en', 'eth')):
            try:
                if open('/sys/class/net/%s/carrier' % i).read().strip() == '1':
                    return ('wired', '', 4, addr(i))
            except OSError:
                pass
    for i in nics:
        if i.startswith('wl'):
            try:
                out = subprocess.run(['/usr/sbin/iw', 'dev', i, 'link'], capture_output=True, text=True, timeout=3).stdout
            except Exception:
                out = ''
            if 'Connected' in out:
                ssid, dbm = '', -90
                for l in out.splitlines():
                    l = l.strip()
                    if l.startswith('SSID:'): ssid = l[5:].strip()
                    elif l.startswith('signal:'):
                        try: dbm = int(float(l.split()[1]))
                        except (IndexError, ValueError): pass
                return ('wifi', ssid, bars(dbm), addr(i))
    return ('none', '', 0, '')

def bars(dbm):
    return 4 if dbm >= -55 else 3 if dbm >= -65 else 2 if dbm >= -75 else 1

# the icon of a network, its kind and bars changed later (st['kind'], st['bars']): wifi (arcs, the empty ones faint),
# wired (a plug), none (a Wi-Fi crossed out)
def net_icon(kind='none', level=0, size=20, color=(1, 1, 1)):
    d = Gtk.DrawingArea(valign=Gtk.Align.CENTER); d.set_size_request(size, size)
    st = {'kind': kind, 'bars': level, 'color': color}
    def draw(w, cr):
        s = size; r, g, b = st['color']; cr.set_line_width(max(2.0, s / 10)); cr.set_line_cap(1)
        if st['kind'] == 'wired':
            cr.set_source_rgba(r, g, b, 0.95)
            cr.rectangle(s * 0.28, s * 0.22, s * 0.44, s * 0.34); cr.stroke()
            cr.move_to(s * 0.40, s * 0.22); cr.line_to(s * 0.40, s * 0.08); cr.stroke()
            cr.move_to(s * 0.60, s * 0.22); cr.line_to(s * 0.60, s * 0.08); cr.stroke()
            cr.move_to(s * 0.50, s * 0.56); cr.line_to(s * 0.50, s * 0.92); cr.stroke()
            return
        cx, cy = s / 2, s * 0.86
        for k in range(1, 4):
            on = st['kind'] == 'wifi' and st['bars'] >= k + 1
            cr.set_source_rgba(r, g, b, 0.95 if on else 0.30)
            cr.arc(cx, cy, s * 0.22 * k, -math.pi * 0.78, -math.pi * 0.22); cr.stroke()
        cr.set_source_rgba(r, g, b, 0.95 if st['kind'] == 'wifi' else 0.30); cr.arc(cx, cy, s * 0.07, 0, 2 * math.pi); cr.fill()
        if st['kind'] == 'none':
            cr.set_source_rgba(0.94, 0.27, 0.27, 1.0); cr.move_to(s * 0.15, s * 0.15); cr.line_to(s * 0.85, s * 0.85); cr.stroke()
    d.connect('draw', draw); d.st = st
    return d

def picture(path, maxw, maxh):
    try:
        pb = GdkPixbuf.Pixbuf.new_from_file(path)
    except Exception:
        return None
    k = min(1.0, maxw / pb.get_width(), maxh / pb.get_height())
    if k < 1.0:
        pb = pb.scale_simple(max(1, int(pb.get_width() * k)), max(1, int(pb.get_height() * k)), GdkPixbuf.InterpType.BILINEAR)
    return Gtk.Image.new_from_pixbuf(pb)

def label(text, cls, wrap=True, xalign=0.5, chars=52):
    l = Gtk.Label(label=text, xalign=xalign); l.get_style_context().add_class(cls)
    if wrap:
        l.set_line_wrap(True); l.set_max_width_chars(chars); l.set_justify(Gtk.Justification.CENTER)
    return l

# progress of the software update: (percent, version), or None when no update is installing
def update_progress():
    try:
        with open(PROGRESS_FILE) as f:
            p = f.read().split()
        return (max(0, min(100, int(p[0]))), p[1] if len(p) > 1 else '')
    except (OSError, ValueError, IndexError):
        return None

def update_running():
    if update_progress() is not None:
        return True
    return subprocess.run(['systemctl', 'is-active', '-q', 'openthinrdp-update.service']).returncode == 0

code = 1
def leave(c, out=None):
    global code
    code = c
    if out is not None:
        print(out, flush=True)
    Gtk.main_quit()

prov = Gtk.CssProvider(); prov.load_from_data(CSS)
Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
scr = Gdk.Screen.get_default()
mon = scr.get_display().get_primary_monitor() or scr.get_display().get_monitor(0)
geo = mon.get_geometry(); SW, SH = geo.width, geo.height

# --- small notice in the corner (no background) ------------------------------------------------------------
if MODE == 'toast':
    win = Gtk.Window(type=Gtk.WindowType.POPUP)
    win.set_wmclass('OtrToast', 'OtrToast')
    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14); box.get_style_context().add_class('toast')
    kind = 'warn' if A.while_file else 'update'
    box.pack_start(icon(kind, 28, COLORS[kind], 1.0), False, False, 0)
    col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
    # one line for the remote screen notice: a wrapped label in a popup is given room for lines it does not use
    tl = label(A.text, 'text', wrap=not A.while_file, xalign=0, chars=34); col.pack_start(tl, False, False, 0)
    bar = Gtk.ProgressBar(); bar.set_size_request(260, -1)
    if not A.while_file: col.pack_start(bar, False, False, 0)
    box.pack_start(col, True, True, 0); win.add(box)
    def poll():
        if A.while_file:
            if not os.path.exists(A.while_file): leave(0); return False
            return True
        p = update_progress()
        if p is None and not update_running():
            leave(0); return False
        if p:
            bar.set_fraction(p[0] / 100.0); tl.set_text(A.text.replace('%v', p[1]).replace('%p', str(p[0])))
        return True
    poll(); GLib.timeout_add(700, poll)
    win.show_all()
    w, h = win.get_size(); win.move(geo.x + SW - w - 24, geo.y + 24)
    Gtk.main(); sys.exit(code)

# --- full screen: background, the picture of the site, a card ------------------------------------------------
win = Gtk.Window(title=A.title or 'Remote desktop')
win.set_wmclass('OtrLogin' if MODE == 'login' else 'OtrScreen', 'OtrLogin' if MODE == 'login' else 'OtrScreen')
win.set_decorated(False); win.move(geo.x, geo.y); win.set_default_size(SW, SH); win.fullscreen()
top, bottom = rgb(A.top, '#1b2733'), rgb(A.bottom, '#000000')
ov = Gtk.Overlay(); win.add(ov)
bg = Gtk.DrawingArea()
def draw_bg(w, cr):
    import cairo
    h = w.get_allocated_height(); g = cairo.LinearGradient(0, 0, 0, h)
    g.add_color_stop_rgb(0, top.red, top.green, top.blue); g.add_color_stop_rgb(1, bottom.red, bottom.green, bottom.blue)
    cr.set_source(g); cr.paint()
bg.connect('draw', draw_bg); ov.add(bg)

mid = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=26, halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
sp = picture(A.splash, SW * 0.42, SH * 0.26) if A.splash else None
if sp: mid.pack_start(sp, False, False, 0)
card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12); card.get_style_context().add_class('card')
mid.pack_start(card, False, False, 0)
ov.add_overlay(mid)
win.connect('delete-event', lambda *_: True)        # only the buttons close it

if MODE == 'message':
    card.set_size_request(min(460, SW - 40), -1)
    if A.icon:
        ic = icon(A.icon, 46, COLORS.get(A.icon, COLORS['info']), 1.0); ic.set_margin_bottom(2); card.pack_start(ic, False, False, 0)
    if A.heading: card.pack_start(label(A.heading, 'heading'), False, False, 2)
    tx = label(A.text.replace('\\n', '\n'), 'text'); card.pack_start(tx, False, False, 0)
    bar = None
    if A.progress or A.update or A.timeout:
        bar = Gtk.ProgressBar(); bar.set_margin_top(6); card.pack_start(bar, False, False, 0)
    if A.small: card.pack_start(label(A.small.replace('\\n', '\n'), 'small'), False, False, 2)
    buttons = {}
    if A.button:
        row = Gtk.Box(spacing=10, halign=Gtk.Align.CENTER); row.set_margin_top(8)
        for b in A.button:
            text, _, c = b.rpartition(':')
            bt = Gtk.Button(label=text); bt.get_style_context().add_class('primary' if c == A.primary else 'secondary')
            # a progress screen: its buttons only by mouse or touch (before show_all, or GTK focuses the first one).
            # An Enter pressed twice after the password would otherwise press Cancel on the screen that follows it.
            if A.progress: bt.set_can_focus(False)
            bt.connect('clicked', lambda _b, c=int(c): leave(c)); row.pack_start(bt, False, False, 0); buttons[c] = bt
        card.pack_start(row, False, False, 0)
    if A.timeout:
        T = max(1, int(A.timeout)); t0 = time.time()
        def tick():
            left = T - (time.time() - t0)
            if left <= 0:
                leave(70); return False
            bar.set_fraction(left / T); return True
        tick(); GLib.timeout_add(100, tick)
    if A.progress:
        # the yad progress protocol on stdin: a number = percent, "# text" = text; 100 or end of input = done.
        # Between two steps the bar keeps moving slowly towards the next one, so it never looks stuck.
        st = {'target': 0.0, 'shown': 0.0}
        def creep():
            cap = min(st['target'] + 25.0, 95.0)
            if st['shown'] < cap:
                st['shown'] += max(0.05, (cap - st['shown']) * 0.012)
            bar.set_fraction(min(st['shown'], 100.0) / 100.0); return True
        GLib.timeout_add(100, creep)
        # Every line that has arrived, not one per wake-up: a percent and its text come together, and a buffered
        # second line would wait for the next write, so the text stayed one step behind (and stuck while waiting).
        pending = {'b': ''}
        def on_input(src, cond):
            try: data = os.read(sys.stdin.fileno(), 65536).decode('utf-8', 'replace')
            except BlockingIOError: return True
            if not data:
                leave(0); return False
            lines = (pending['b'] + data).split('\n'); pending['b'] = lines.pop()
            for line in (l.strip() for l in lines):
                if line.startswith('#'):
                    tx.set_text(line[1:].strip())
                    continue
                try: v = max(0.0, min(100.0, float(line)))
                except ValueError: continue
                st['target'] = v; st['shown'] = max(st['shown'], v)
                if v >= 100:
                    bar.set_fraction(1.0); GLib.timeout_add(250, lambda: leave(0) or False); return False
            return True
        GLib.io_add_watch(sys.stdin, GLib.PRIORITY_DEFAULT, GLib.IO_IN | GLib.IO_HUP, on_input)
    if A.update:
        base = A.text.replace('\\n', '\n')
        def poll():
            p = update_progress()
            if p is None and not update_running():
                leave(0); return False
            if p:
                bar.set_fraction(p[0] / 100.0); tx.set_text(base.replace('%v', p[1]).replace('%p', str(p[0])))
            return True
        poll(); GLib.timeout_add(700, poll)
    win.show_all()
    if A.progress: pass                     # no button takes the keyboard there (above)
    elif A.default in buttons: buttons[A.default].grab_focus()
    elif buttons: list(buttons.values())[0].grab_focus()
    Gtk.main(); sys.exit(code)

def left_label(text, cls, chars=70):
    l = Gtk.Label(label=text, xalign=0); l.get_style_context().add_class(cls)
    l.set_line_wrap(True); l.set_max_width_chars(chars); l.set_justify(Gtk.Justification.LEFT)
    return l

def button(text, cls, cb):
    b = Gtk.Button(label=text); b.get_style_context().add_class(cls); b.connect('clicked', cb); return b

# Exit codes of the admin screens: 0 = save / OK, 11 = close / cancel, 12 = terminal. Anything else (a Python error)
# makes kiosk.sh fall back to its yad dialogs: the settings are also how a device in trouble is put right.
if MODE in ('form', 'text') and sp:
    mid.remove(sp)       # the card takes the screen: no background picture above it

# --- settings of the device ------------------------------------------------------------------------------------
# On stdin, one line per section and per field, tab separated:
#   S  title
#   F  KEY  type  label  value  choices  hint        type: text, password, choice (choices "value=label|..."), ro
# Save prints KEY=value for every field but ro, in their order. --small = a status line under the heading.
if MODE == 'form':
    card.set_size_request(min(1060, SW - 40), min(720, SH - 40)); card.set_spacing(14)
    card.pack_start(left_label(A.heading, 'heading'), False, False, 0)
    if A.small: card.pack_start(left_label(A.small.replace('\\n', '\n'), 'small', 140), False, False, 0)
    stack = Gtk.Stack(); stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
    side = Gtk.StackSidebar(); side.set_stack(stack); side.set_size_request(210, -1)
    fields, grid, row, n = [], None, 0, 0
    for line in sys.stdin.read().split('\n'):
        p = line.split('\t')
        if p[0] == 'S' and len(p) > 1:
            grid = Gtk.Grid(column_spacing=22, row_spacing=4); grid.set_margin_start(22); grid.set_margin_end(14)
            grid.set_margin_top(4); grid.set_margin_bottom(10); row = 0; n += 1
            sc = Gtk.ScrolledWindow(); sc.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC); sc.add(grid)
            stack.add_titled(sc, 'page%d' % n, p[1])
        elif p[0] == 'F' and grid is not None:
            key, typ, lab, val, ch, hint = (p[1:] + [''] * 6)[:6]
            if typ == 'choice':
                w = Gtk.ComboBoxText()
                for c in ch.split('|'):
                    v, _, t = c.partition('='); w.append(v, t or v)
                if not w.set_active_id(val): w.set_active(0)
            else:
                w = Gtk.Entry(); w.set_text(val)
                if typ == 'password':
                    w.set_visibility(False); w.set_input_purpose(Gtk.InputPurpose.PASSWORD)
                if typ == 'ro':
                    w.set_editable(False); w.set_can_focus(False); w.get_style_context().add_class('readonly')
            w.set_hexpand(True); w.set_valign(Gtk.Align.CENTER)
            fl = Gtk.Label(label=lab, xalign=0); fl.get_style_context().add_class('field'); fl.set_size_request(230, -1)
            fl.set_line_wrap(True); fl.set_max_width_chars(28); fl.set_margin_top(10)
            w.set_margin_top(10)
            grid.attach(fl, 0, row, 1, 1); grid.attach(w, 1, row, 1, 1); row += 1
            if hint:
                grid.attach(left_label(hint, 'hint', 72), 1, row, 1, 1); row += 1
            if typ != 'ro': fields.append((key, typ, w))
    body = Gtk.Box(spacing=0); body.pack_start(side, False, False, 0); body.pack_start(stack, True, True, 0)
    card.pack_start(body, True, True, 0)
    def save(*_):
        out = []
        for key, typ, w in fields:
            v = (w.get_active_id() or '') if typ == 'choice' else w.get_text()
            out.append('%s=%s' % (key, v.replace('\n', ' ')))
        leave(0, '\n'.join(out))
    bar = Gtk.Box(spacing=10); bar.set_margin_top(4)
    if A.t_terminal: bar.pack_start(button(A.t_terminal, 'secondary', lambda *_: leave(12)), False, False, 0)
    # more buttons (--button LABEL:CODE), after Terminal: the code they end with (the Wi-Fi page: 13)
    for b in A.button:
        lbl, _, c = b.rpartition(':')
        if lbl and c.isdigit(): bar.pack_start(button(lbl, 'secondary', lambda *_, c=int(c): leave(c)), False, False, 0)
    bs = button(A.t_save or 'Save', 'primary', save); bc = button(A.t_close or 'Close', 'secondary', lambda *_: leave(11))
    bar.pack_end(bs, False, False, 0); bar.pack_end(bc, False, False, 0)
    card.pack_start(bar, False, False, 0)
    win.connect('key-press-event', lambda _w, e: e.keyval == Gdk.KEY_Escape and leave(11))
    code = 11
    win.show_all()
    if A.open_power and A.open_power.isdigit():           # tests: show that section (for a screenshot)
        stack.set_visible_child_name('page' + A.open_power)
    Gtk.main(); sys.exit(code)

# --- the settings PIN ------------------------------------------------------------------------------------------
# OK prints the PIN typed (exit 0); Cancel 11
if MODE == 'pin':
    card.set_size_request(min(400, SW - 40), -1)
    card.pack_start(icon('gear', 40, COLORS['info'], 1.0), False, False, 0)
    card.pack_start(label(A.heading, 'heading'), False, False, 2)
    if A.text: card.pack_start(label(A.text, 'text'), False, False, 0)
    ep = Gtk.Entry(visibility=False); ep.set_input_purpose(Gtk.InputPurpose.PIN); card.pack_start(ep, False, False, 4)
    row = Gtk.Box(spacing=10, halign=Gtk.Align.CENTER); row.set_margin_top(6)
    ok = lambda *_: leave(0, ep.get_text()) if ep.get_text() else ep.grab_focus()
    row.pack_start(button(A.t_close or 'Cancel', 'secondary', lambda *_: leave(11)), False, False, 0)
    row.pack_start(button(A.t_save or 'OK', 'primary', ok), False, False, 0)
    card.pack_start(row, False, False, 0)
    ep.connect('activate', ok)
    win.connect('key-press-event', lambda _w, e: e.keyval == Gdk.KEY_Escape and leave(11))
    code = 11
    win.show_all(); ep.grab_focus()
    Gtk.main(); sys.exit(code)

# --- Wi-Fi: the networks around, one chosen, its password, connect and see the result here ------------------------
# The texts on stdin, "key<TAB>text" per line (kiosk.sh, in the language of the device). wifi.sh (root, through
# sudo) scans and connects: the network is tried first and saved only when it joins; a wrong password leaves the
# Wi-Fi of before. Exit: 0 = a network joined here, 11 = closed without.
if MODE == 'wifi':
    import threading
    T = {}
    for line in sys.stdin.read().split('\n'):
        k, _, v = line.partition('\t')
        if k: T[k] = v.replace('\\n', '\n')
    t = lambda k, *a: (T.get(k, k) % a) if a else T.get(k, k)
    WIFI = ['sudo', '-n', '/opt/openthinrdp/wifi.sh']
    card.set_size_request(min(760, SW - 40), min(660, SH - 40)); card.set_spacing(12)
    if sp: mid.remove(sp)
    card.pack_start(left_label(t('heading'), 'heading'), False, False, 0)
    # where the device is now
    srow = Gtk.Box(spacing=10); sico = net_icon('none', 0, 20, (0.15, 0.39, 0.92)); slab = left_label('', 'text', 80)
    srow.pack_start(sico, False, False, 0); srow.pack_start(slab, True, True, 0); card.pack_start(srow, False, False, 0)
    def show_state():
        k, ssid, lv, ip = net_state()
        sico.st['kind'], sico.st['bars'] = k, lv; sico.queue_draw()
        slab.set_text(t('status_wifi', ssid, ip or '-') if k == 'wifi' else t('status_wired', ip or '-') if k == 'wired' else t('status_none'))
        return True
    show_state(); GLib.timeout_add_seconds(4, show_state)
    # the networks around
    hrow = Gtk.Box(spacing=10); hrow.pack_start(left_label(t('list'), 'field'), True, True, 0)
    brf = button(t('refresh'), 'secondary', lambda *_: scan()); hrow.pack_end(brf, False, False, 0)
    card.pack_start(hrow, False, False, 0)
    lb = Gtk.ListBox(); lb.set_selection_mode(Gtk.SelectionMode.SINGLE)
    sc = Gtk.ScrolledWindow(); sc.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC); sc.add(lb)
    sc.set_min_content_height(200); card.pack_start(sc, True, True, 0)
    # the one chosen, its password
    sel = left_label(t('choose'), 'text', 80); card.pack_start(sel, False, False, 0)
    prow = Gtk.Box(spacing=10)
    ep = Gtk.Entry(placeholder_text=t('password'), visibility=False); ep.set_input_purpose(Gtk.InputPurpose.PASSWORD)
    cshow = Gtk.CheckButton(label=t('show')); cshow.connect('toggled', lambda c: ep.set_visibility(c.get_active()))
    prow.pack_start(ep, True, True, 0); prow.pack_start(cshow, False, False, 0); card.pack_start(prow, False, False, 0)
    res = left_label('', 'text', 90); card.pack_start(res, False, False, 0)
    bar = Gtk.Box(spacing=10)
    bcn = button(t('connect'), 'primary', lambda *_: connect()); bcl = button(t('close'), 'secondary', lambda *_: leave(code))
    bar.pack_end(bcn, False, False, 0); bar.pack_end(bcl, False, False, 0); card.pack_start(bar, False, False, 0)
    state = {'busy': False, 'net': None}
    def say(text, cls):
        res.set_text(text)
        for c in ('result-ok', 'result-err', 'result-busy', 'text'): res.get_style_context().remove_class(c)
        res.get_style_context().add_class(cls)
    def busy(on):
        state['busy'] = on
        for w in (brf, bcn, bcl, lb, ep, cshow): w.set_sensitive(not on)
    def pick(_lb, row):
        if row is None: return
        n = row.net; state['net'] = n
        if n['sec'] == 'psk':
            sel.set_text(t('chosen', n['ssid'])); prow.set_sensitive(True); bcn.set_sensitive(not state['busy']); ep.grab_focus()
        else:
            sel.set_text(t('chosen', n['ssid']) + '  —  ' + t('sec_' + n['sec'])); prow.set_sensitive(False); bcn.set_sensitive(False)
    lb.connect('row-selected', pick)
    def fill(nets):
        for r in lb.get_children(): lb.remove(r)
        cur = net_state()[1]
        for n in nets:
            row = Gtk.ListBoxRow(); row.net = n; box = Gtk.Box(spacing=12); box.get_style_context().add_class('wifirow')
            box.pack_start(net_icon('wifi', bars(n['dbm']), 20, (0.15, 0.39, 0.92)), False, False, 0)
            col = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
            nm = Gtk.Label(label=n['ssid'], xalign=0); nm.get_style_context().add_class('wifiname'); col.pack_start(nm, False, False, 0)
            meta = t('sec_' + n['sec']) + ('  ·  ' + t('current') if n['ssid'] == cur else '')
            mt = Gtk.Label(label=meta, xalign=0); mt.get_style_context().add_class('wifimeta'); col.pack_start(mt, False, False, 0)
            box.pack_start(col, True, True, 0); row.add(box); lb.add(row)
            if n['ssid'] == cur: lb.select_row(row)
        lb.show_all()
        if not nets: say(t('nonefound'), 'result-err')
        elif res.get_text() == t('scanning'): say('', 'text')
        busy(False)
        if state['net'] is None or state['net']['sec'] != 'psk': bcn.set_sensitive(False)
    def scan():
        busy(True); say(t('scanning'), 'result-busy')
        def run():
            nets = []
            try:
                p = subprocess.run(WIFI + ['scan'], capture_output=True, text=True, timeout=40)
                if p.returncode == 2: GLib.idle_add(lambda: (say(t('nowifi'), 'result-err'), busy(False)) and False); return
                for l in p.stdout.splitlines():
                    f = l.split('\t', 2)
                    if len(f) == 3: nets.append({'dbm': int(f[0]), 'sec': f[1], 'ssid': f[2]})
            except Exception:
                pass
            GLib.idle_add(lambda: fill(nets) and False)
        threading.Thread(target=run, daemon=True).start()
    def connect():
        n = state['net']
        if not n or n['sec'] != 'psk': say(t('choose'), 'result-err'); return
        pw = ep.get_text()
        if not 8 <= len(pw) <= 63: say(t('invalid'), 'result-err'); ep.grab_focus(); return
        busy(True); say(t('step_stop', n['ssid']), 'result-busy')
        def run():
            out = 'result timeout'
            try:
                p = subprocess.Popen(WIFI + ['connect'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
                p.stdin.write(n['ssid'] + '\n' + pw + '\n'); p.stdin.close()
                for l in p.stdout:
                    l = l.strip()
                    if l.startswith('step '): GLib.idle_add(lambda s=l[5:]: say(t('step_' + s, n['ssid']), 'result-busy') and False)
                    elif l.startswith('result '): out = l
                p.wait(timeout=120)
            except Exception:
                pass
            GLib.idle_add(lambda: done(out) and False)
        threading.Thread(target=run, daemon=True).start()
    def done(out):
        global code
        f = out.split()[1:] or ['timeout']; r = f[0]
        if r == 'ok':
            say(t('ok', state['net']['ssid'], f[1] if len(f) > 1 else '-') + ('\n' + t('central') if 'central' in f else ''), 'result-ok'); code = 0
        elif r == 'noip':
            say(t('noip', state['net']['ssid']) + ('\n' + t('central') if 'central' in f else ''), 'result-err'); code = 0
        elif r == 'saveerror':
            say(t('saveerror', ' '.join(f[1:])), 'result-err')
        else:
            say(t(r, state['net']['ssid']) if '%s' in T.get(r, '') else t(r), 'result-err')
        busy(False); show_state()
        if r in ('wrongkey', 'invalid'): ep.select_region(0, -1); ep.grab_focus()
    ep.connect('activate', lambda *_: connect())
    win.connect('key-press-event', lambda _w, e: e.keyval == Gdk.KEY_Escape and not state['busy'] and leave(code))
    code = 11
    win.show_all(); prow.set_sensitive(False); bcn.set_sensitive(False)
    scan()
    Gtk.main(); sys.exit(code)

# --- a text read from stdin as it comes (diagnostics) ----------------------------------------------------------
if MODE == 'text':
    card.set_size_request(min(900, SW - 40), min(600, SH - 40)); card.set_spacing(12)
    card.pack_start(left_label(A.heading, 'heading'), False, False, 0)
    if A.text: card.pack_start(left_label(A.text, 'small', 120), False, False, 0)
    tv = Gtk.TextView(editable=False, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD_CHAR)
    tv.get_style_context().add_class('mono'); tv.set_left_margin(4)
    sc = Gtk.ScrolledWindow(); sc.add(tv); card.pack_start(sc, True, True, 0)
    buf = tv.get_buffer()
    def on_text(src, cond):
        data = os.read(sys.stdin.fileno(), 65536)
        if not data: return False
        buf.insert(buf.get_end_iter(), data.decode('utf-8', 'replace')); return True
    GLib.io_add_watch(sys.stdin, GLib.PRIORITY_DEFAULT, GLib.IO_IN | GLib.IO_HUP, on_text)
    row = Gtk.Box(spacing=10); bc = button(A.t_close or 'Close', 'primary', lambda *_: leave(0)); row.pack_end(bc, False, False, 0)
    # more buttons (--button LABEL:CODE), left of Close: the code they end with
    for b in A.button:
        lbl, _, c = b.rpartition(':')
        if lbl and c.isdigit(): row.pack_start(button(lbl, 'secondary', lambda *_, c=int(c): leave(c)), False, False, 0)
    card.pack_start(row, False, False, 0)
    win.connect('key-press-event', lambda _w, e: e.keyval == Gdk.KEY_Escape and leave(0))
    code = 0
    win.show_all(); bc.grab_focus()
    Gtk.main(); sys.exit(code)

# --- sign-in screen --------------------------------------------------------------------------------------------
card.set_size_request(min(400, SW - 40), -1)
# the logo in the card only when the background picture is not shown above it: the same mark twice looks odd
lg = picture(A.logo, 240, 90) if A.logo and not sp else None
if lg: lg.set_margin_bottom(4); card.pack_start(lg, False, False, 0)
card.pack_start(label(A.heading, 'heading'), False, False, 4)
eu = Gtk.Entry(placeholder_text=A.t_user or 'User'); eu.set_text(A.user)
ep = Gtk.Entry(placeholder_text=A.t_password or 'Password', visibility=False); ep.set_input_purpose(Gtk.InputPurpose.PASSWORD)
card.pack_start(eu, False, False, 0); card.pack_start(ep, False, False, 0)
bs = Gtk.Button(label=A.t_signin or 'Sign in'); bs.get_style_context().add_class('signin'); bs.set_margin_top(6)
card.pack_start(bs, False, False, 0)
if A.note: card.pack_start(label(A.note, 'note', chars=46), False, False, 2)

def sign_in(*_):
    if ep.get_text():
        leave(10, eu.get_text().strip() + "|" + ep.get_text() + "|")   # trailing | as the yad form: kiosk.sh strips it
    else:
        ep.grab_focus()
bs.connect('clicked', sign_in); ep.connect('activate', sign_in); eu.connect('activate', lambda *_: ep.grab_focus())

# day and month in the language of the kiosk (LANGUAGE), not of the system: a system installed in English with
# LANGUAGE=it would show "Monday 12 October"
DAYS = {'it': ('lunedì', 'martedì', 'mercoledì', 'giovedì', 'venerdì', 'sabato', 'domenica'),
        'nl': ('maandag', 'dinsdag', 'woensdag', 'donderdag', 'vrijdag', 'zaterdag', 'zondag')}
MONTHS = {'it': ('gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno', 'luglio', 'agosto', 'settembre',
                 'ottobre', 'novembre', 'dicembre'),
          'nl': ('januari', 'februari', 'maart', 'april', 'mei', 'juni', 'juli', 'augustus', 'september',
                 'oktober', 'november', 'december')}
def today():
    t = time.localtime()
    if A.lang in DAYS:
        return f"{DAYS[A.lang][t.tm_wday].capitalize()} {t.tm_mday} {MONTHS[A.lang][t.tm_mon - 1]}"
    s = time.strftime('%A %d %B', t); return s[:1].upper() + s[1:]   # capitalize() would lower "October"

def corner_button(kind, tip, cb):
    b = Gtk.Button(); b.add(icon(kind)); b.set_tooltip_text(tip); b.get_style_context().add_class('corner')
    b.set_can_focus(False)
    if cb: b.connect("clicked", cb)
    return b

# top left: clock and date; top right: information and settings
tl = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, halign=Gtk.Align.START, valign=Gtk.Align.START, margin=26)
clk = Gtk.Label(xalign=0); clk.get_style_context().add_class('clock')
dt = Gtk.Label(xalign=0); dt.get_style_context().add_class('date')
tl.pack_start(clk, False, False, 0); tl.pack_start(dt, False, False, 0); ov.add_overlay(tl)
def tick():
    clk.set_text(time.strftime('%H:%M')); dt.set_text(today()); return True
tick(); GLib.timeout_add_seconds(10, tick)
tr = Gtk.Box(spacing=10, halign=Gtk.Align.END, valign=Gtk.Align.START, margin=22)
# the network, left of them, kept current: cable, Wi-Fi with its name and bars, or none (red). Pressed: the Wi-Fi
# page (exit 8; kiosk.sh asks the PIN of the settings first). --t-net = "cable|Wi-Fi|no network|no address"
if A.t_net:
    tn = (A.t_net.split('|') + ['', '', '', ''])[:4]
    nb = Gtk.Button(); nb.get_style_context().add_class('netpill'); nb.set_can_focus(False)
    nbx = Gtk.Box(spacing=8); nic = net_icon('none', 0, 20); nlb = Gtk.Label(); nbx.pack_start(nic, False, False, 0); nbx.pack_start(nlb, False, False, 0)
    nb.add(nbx); nb.connect('clicked', lambda *_: leave(8))
    def net_tick():
        k, ssid, lv, ip = net_state()
        nic.st['kind'], nic.st['bars'] = k, lv; nic.queue_draw()
        txt = tn[0] if k == 'wired' else ('%s · %s' % (tn[1], ssid) if ssid else tn[1]) if k == 'wifi' else tn[2]
        if k != 'none' and not ip: txt += ' · ' + tn[3]
        nlb.set_text(txt); nb.set_tooltip_text(ip or txt)
        ctx = nb.get_style_context(); (ctx.add_class if k == 'none' or not ip else ctx.remove_class)('down')
        return True
    net_tick(); GLib.timeout_add_seconds(5, net_tick)
    tr.pack_start(nb, False, False, 0)
tr.pack_start(corner_button('info', A.t_diag or 'Diagnostics', lambda *_: leave(4)), False, False, 0)
tr.pack_start(corner_button('gear', A.t_settings or 'Settings', lambda *_: leave(3)), False, False, 0)
ov.add_overlay(tr)

# bottom left: web button and the name of the device; bottom right: power with its menu
bl = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, halign=Gtk.Align.START, valign=Gtk.Align.END, margin=24)
if A.web:
    wb = Gtk.Button(label=A.web); wb.get_style_context().add_class('webbtn'); wb.set_can_focus(False)
    wb.connect('clicked', lambda *_: leave(7)); wb.set_halign(Gtk.Align.START); bl.pack_start(wb, False, False, 0)
if A.info:
    di = Gtk.Label(label=A.info, xalign=0); di.get_style_context().add_class('device'); bl.pack_start(di, False, False, 0)
ov.add_overlay(bl)
pw = corner_button('power', A.t_power or 'Power', None)
pop = Gtk.Popover(); pop.set_relative_to(pw); pop.set_position(Gtk.PositionType.TOP)
pb = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, margin=6)
for text, c in ((A.t_restart or 'Restart', 6), (A.t_shutdown or 'Shut down', 5)):
    b = Gtk.Button(label=text, xalign=0); b.connect('clicked', lambda _b, c=c: leave(c)); pb.pack_start(b, False, False, 0)
pb.show_all(); pop.add(pb)
pw.connect('clicked', lambda *_: pop.popup())
br = Gtk.Box(halign=Gtk.Align.END, valign=Gtk.Align.END, margin=22); br.pack_start(pw, False, False, 0); ov.add_overlay(br)

win.show_all()
(ep if A.user else eu).grab_focus(); eu.select_region(0, 0)
if A.open_power: GLib.timeout_add(300, lambda: pop.popup() and False)
Gtk.main()
sys.exit(code)
