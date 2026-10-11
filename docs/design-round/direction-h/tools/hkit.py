# Direction H shared framework: tokens, phone chrome, note builder.
# Every output file is fully self-contained (inline CSS/SVG, no assets, no JS).
import os

OUT = os.path.join(os.path.dirname(__file__), "..", "docs", "design-round", "direction-h")

# ---------------------------------------------------------------- tokens
# Palettes verified by tools/contrast.mjs (all pairs pass).
VARS = {
  "light": """
    --bg:#F5F0E8; --surface:#FEFCF8; --ink:#2A2118; --ink2:#6B5D4C; --ink3:#8F8270;
    --rule:#E3DBC9; --rule2:#8F7F62; --acc:#C2613A; --accsoft:#F1DED1; --accink:#7E3A1D;
    --err:#BC2F1B; --photo:#EDE5D6; --btnfill:#2A2118; --onbtn:#FFFFFF;
    --barbg:rgba(254,252,248,.78); --barline:rgba(42,33,24,.10); --barshadow:rgba(42,33,24,.22);
    --dock:rgba(254,252,248,.84); --hatch:rgba(42,33,24,.035); --stroke8:rgba(42,33,24,.08)""",
  "dark": """
    --bg:#141210; --surface:#24211C; --ink:#F2EDE3; --ink2:#BDB09E; --ink3:#8B7F6C;
    --rule:#2B2620; --rule2:#716655; --acc:#D98059; --accsoft:#342218; --accink:#EFA47D;
    --err:#FF6B57; --photo:#1E1B16; --btnfill:#F2EDE3; --onbtn:#1E1C17;
    --barbg:rgba(30,27,22,.78); --barline:rgba(242,237,227,.12); --barshadow:rgba(0,0,0,.45);
    --dock:rgba(30,27,22,.86); --hatch:rgba(242,237,227,.04); --stroke8:rgba(242,237,227,.10)""",
  "cook": """
    --bg:#1E1C17; --surface:#28251E; --ink:#F2EDE3; --ink2:#B5A995; --ink3:#7E7461;
    --rule:#312C24; --rule2:#7E7461; --acc:#E08B62; --accsoft:#35241A; --accink:#F0A97F;
    --err:#FF6B57; --photo:#262219; --btnfill:#F2EDE3; --onbtn:#1E1C17;
    --barbg:rgba(40,37,30,.85); --barline:rgba(242,237,227,.12); --barshadow:rgba(0,0,0,.5);
    --dock:rgba(40,37,30,.86); --hatch:rgba(242,237,227,.04); --stroke8:rgba(242,237,227,.10)""",
}

SANS = '-apple-system,BlinkMacSystemFont,"SF Pro Text","SF Pro Display","Helvetica Neue",Helvetica,Arial,sans-serif'
MONO = 'ui-monospace,"SF Mono",SFMono-Regular,Menlo,Consolas,monospace'
SERIF = 'ui-serif,"New York","Iowan Old Style",Georgia,"Times New Roman",serif'

BASE_CSS = """
:root{--sans:%SANS%;--mono:%MONO%;--serif:%SERIF%;--out:cubic-bezier(.23,1,.32,1);--sheet:cubic-bezier(.32,.72,0,1)}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:var(--sans);background:#D6D3CC;color:#26241F;-webkit-font-smoothing:antialiased;display:flex;justify-content:center;align-items:flex-start;gap:36px;padding:40px 24px 80px;min-height:100vh;font-size:17px;line-height:24px}
.phone{position:relative;width:393px;height:852px;flex:none;border-radius:54px;overflow:hidden;box-shadow:0 0 0 1px rgba(0,0,0,.16),0 30px 60px -20px rgba(0,0,0,.32);font-size:17px;line-height:24px}
.t-light{background:var(--bg);color:var(--ink)}
.t-dark{background:var(--bg);color:var(--ink)}
.t-cook{background:var(--bg);color:var(--ink)}
.island{position:absolute;top:11px;left:50%%;transform:translateX(-50%%);width:125px;height:37px;background:#000;border-radius:20px;z-index:12}
.t-cook .island{box-shadow:0 0 0 .5px #1c1c1c}
.status{position:absolute;top:0;left:0;right:0;height:54px;display:flex;justify-content:space-between;align-items:center;padding:4px 36px 0 44px;font-size:17px;font-weight:600;color:var(--ink);z-index:11}
.status .sig{display:flex;gap:7px;align-items:center}
.homebar{position:absolute;bottom:8px;left:50%%;transform:translateX(-50%%);width:139px;height:5px;border-radius:3px;background:var(--ink);z-index:12}
.screen{position:absolute;inset:0;padding-top:54px}
.scroll{height:100%%;overflow:auto;scrollbar-width:none}
.scroll::-webkit-scrollbar{display:none}
.scroll.dg{padding:0 24px 150px}   /* deciding: 24 side */
.scroll.dn{padding:0 20px 150px}   /* dense: 20 side */
.mono{font-family:var(--mono);font-variant-numeric:tabular-nums;letter-spacing:-.01em}
.serif{font-family:var(--serif);letter-spacing:-.02em}
.c2{color:var(--ink2)}.c3{color:var(--ink3)}
button{border:0}
.label{font-size:13px;line-height:16px;font-weight:600}
.cap{font-size:13px;line-height:16px}
.sec{font-size:15px;line-height:20px}
.head{display:flex;justify-content:space-between;align-items:baseline;padding:10px 0 22px}
.head a{text-decoration:none}
.head h1{font-size:28px;line-height:32px;font-weight:700;letter-spacing:-.015em}
.sect{margin-top:24px}   /* dense sections: 24 */
.sect h3{font-size:13px;line-height:16px;font-weight:600;margin-bottom:6px;display:flex;justify-content:space-between;align-items:baseline}
.sect h3 a,.sect h3 .lnk{font-weight:400;color:var(--ink2);text-decoration:none}
.row{display:flex;align-items:center;justify-content:space-between;min-height:44px;padding:10px 0;border-top:1px solid var(--rule);gap:12px;transition:transform 120ms var(--out)}
.row:active{transform:scale(.985)}
.row:first-of-type{border-top:0}
.row .n{flex:1}
.row .q{font-family:var(--mono);font-variant-numeric:tabular-nums;font-size:15px;line-height:20px;text-align:right;white-space:nowrap}
.btn{display:flex;align-items:center;justify-content:center;gap:8px;width:100%%;height:52px;border-radius:12px;font:inherit;font-weight:600;font-size:17px;border:0;cursor:pointer;transition:transform 120ms var(--out);color:var(--ink);background:transparent}
.btn:active{transform:scale(.97)}
.btn.primary{background:var(--btnfill);color:var(--onbtn)}
.btn.ghost{box-shadow:inset 0 0 0 1px var(--rule2)}
.btn:focus-visible{outline:2px solid var(--acc);outline-offset:2px}
.chip{display:inline-flex;align-items:center;gap:6px;height:36px;padding:0 12px;border-radius:12px;font:inherit;font-size:15px;box-shadow:inset 0 0 0 1px var(--rule2);cursor:pointer;transition:transform 120ms var(--out);color:var(--ink)}
.chip:active{transform:scale(.97)}
.chip.on{background:var(--accsoft);color:var(--accink);box-shadow:inset 0 0 0 1.5px var(--acc)}
.chip.quiet{color:var(--ink2)}
.tag{font-family:var(--mono);font-variant-numeric:tabular-nums;font-size:13px;line-height:16px;padding:3px 7px;border-radius:6px;background:var(--accsoft);color:var(--accink);white-space:nowrap}
.sq{width:14px;height:14px;border-radius:3.5px;flex:none}
.sq.have{background:var(--ink)}
.sq.miss{background:transparent;box-shadow:inset 0 0 0 1.5px var(--acc)}
.sq.unc{background:transparent;border:1.5px dashed var(--ink3)}
.sq.ass{background:var(--ink3);box-shadow:inset 0 0 0 3px var(--bg)}
.fit{display:inline-flex;gap:3px;align-items:center}
.fit i{width:9px;height:9px;border-radius:2px;background:var(--ink)}
.fit i.o{background:transparent;box-shadow:inset 0 0 0 1.5px var(--acc)}
.photo{position:relative;background:var(--photo);border-radius:14px;box-shadow:inset 0 0 0 .5px var(--stroke8);overflow:hidden}
.photo::before{content:"";position:absolute;inset:0;background:repeating-linear-gradient(135deg,transparent 0 10px,var(--hatch) 10px 11px)}
.photo span{position:absolute;left:12px;bottom:10px;font-family:var(--mono);font-size:11px;color:var(--ink3)}
.photo.thumb{width:48px;height:48px;flex:none;border-radius:10px}
.tabbar{position:absolute;left:0;right:0;bottom:0;display:flex;gap:8px;align-items:center;padding:8px 16px 30px;background:var(--barbg);backdrop-filter:blur(28px) saturate(1.6);-webkit-backdrop-filter:blur(28px) saturate(1.6);box-shadow:inset 0 .5px 0 var(--barline);z-index:10}
.tabs{flex:1;height:56px;display:flex;align-items:center;justify-content:space-around;padding:0 4px}
.tab{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:2px;font-size:10px;line-height:12px;font-weight:500;color:var(--ink3);flex:1;min-width:0}
.tab.on{color:var(--ink)}
.tab svg{width:23px;height:23px}
.scanbtn{width:56px;height:56px;border-radius:50%;flex:none;display:grid;place-items:center;background:var(--btnfill);color:var(--bg);box-shadow:0 10px 28px -10px var(--barshadow);transition:transform 120ms var(--out)}
.scanbtn:active{transform:scale(.95)}
.dock{position:absolute;left:0;right:0;bottom:0;display:flex;flex-direction:column;gap:8px;padding:12px 20px 34px;background:var(--dock);backdrop-filter:blur(28px) saturate(1.6);-webkit-backdrop-filter:blur(28px) saturate(1.6);box-shadow:inset 0 .5px 0 var(--barline);z-index:10}
.dock .btnrow{display:flex;gap:10px}
.in{animation:rise 220ms var(--out) both;animation-delay:calc(var(--i,0)*40ms)}
@keyframes rise{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}
@media (prefers-reduced-motion:reduce){.in{animation:fadein 150ms ease both;animation-delay:0s}@keyframes fadein{from{opacity:0}to{opacity:1}} *{animation-duration:.01ms!important;transition-duration:.01ms!important}}
@media (max-width:800px){body{flex-direction:column;align-items:center}}
.note{width:320px;flex:none;font-size:13px;line-height:19px;color:#2A2A26;padding-top:8px}
.note h1{font-size:15px;line-height:20px;font-weight:600;margin-bottom:4px}
.note p{margin-bottom:12px}
.note h2{font-size:12px;line-height:16px;font-weight:600;margin:18px 0 8px;color:#5E5A50}
.note dl{display:grid;grid-template-columns:76px 1fr;gap:8px 12px}
.note dt{font-family:var(--mono);font-size:11px;line-height:19px;color:#5E5A50}
.note a{color:inherit}
"""

BASE_CSS = (BASE_CSS.replace("%SANS%", SANS).replace("%MONO%", MONO).replace("%SERIF%", SERIF))

# ---------------------------------------------------------------- chrome bits
def status():
    return '''<div class="status"><span>9:41</span><span class="sig">
    <svg width="18" height="12" viewBox="0 0 18 12" fill="currentColor"><rect x="0" y="8" width="3" height="4" rx=".8"/><rect x="5" y="5.5" width="3" height="6.5" rx=".8"/><rect x="10" y="3" width="3" height="9" rx=".8"/><rect x="15" y="0" width="3" height="12" rx=".8"/></svg>
    <svg width="16" height="12" viewBox="0 0 16 12"><path d="M8 11.2 1.3 4.5a9.5 9.5 0 0 1 13.4 0z" fill="currentColor"/></svg>
    <svg width="27" height="12" viewBox="0 0 27 12" fill="none"><rect x=".5" y=".5" width="23" height="11" rx="3" stroke="currentColor" stroke-opacity=".4"/><rect x="2" y="2" width="20" height="8" rx="1.6" fill="currentColor"/><rect x="25" y="4" width="1.6" height="4" rx=".8" fill="currentColor" fill-opacity=".4"/></svg>
  </span></div>'''

ICONS = {
  "tonight": '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4.5"/>',
  "kitchen": '<rect x="6" y="2.5" width="12" height="19" rx="2"/><path d="M6 10h12M9 6v1.5M9 13.5v3"/>',
  "table": '<path d="M3 9.5h18M6 9.5V19M18 9.5V19"/><circle cx="12" cy="5" r="2.5"/>',
  "cookbook": '<path d="M5 4.5h10.5a2.5 2.5 0 0 1 2.5 2.5v12.5H7.5A2.5 2.5 0 0 1 5 17z"/><path d="M5 17a2.5 2.5 0 0 1 2.5-2.5H18"/>',
  "explore": '<circle cx="12" cy="12" r="9"/><path d="M15.5 8.5 13.7 13.7 8.5 15.5l1.8-5.2z"/>',
  "progress": '<path d="M4 20V10M10 20V4M16 20v-7M22 20H2"/>',
}
SCAN_GLYPH = '<path d="M4 9V6a2 2 0 0 1 2-2h3M15 4h3a2 2 0 0 1 2 2v3M20 15v3a2 2 0 0 1-2 2h-3M9 20H6a2 2 0 0 1-2-2v-3"/><circle cx="12" cy="12" r="3"/>'

def tab_icon(name):
    fill = ' fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"'
    return f'<svg viewBox="0 0 24 24"{fill}>{ICONS[name]}</svg>'

def tabbar(active, shell="f"):
    if shell == "f":
        tabs = ["tonight", "kitchen", "table", "cookbook", "explore"]
        names = {"tonight": "Tonight", "kitchen": "Kitchen", "table": "Table", "cookbook": "Cookbook", "explore": "Explore"}
        inner = "".join(
            f'<a class="tab{" on" if t == active else ""}">{tab_icon(t)}{names[t]}</a>' for t in tabs)
        return (f'<nav class="tabbar"><div class="tabs">{inner}</div>'
                f'<a class="scanbtn" role="button" aria-label="Scan"><svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round">{SCAN_GLYPH}</svg></a></nav>')
    # shell S: Kitchen and Progress main tabs, central scan orb, Profile inside Progress
    on_k = ' on' if active == 'kitchen' else ''
    on_p = ' on' if active == 'progress' else ''
    orb = (f'<a class="scanbtn" role="button" aria-label="Scan" style="transform:translateY(-8px)">'
           f'<svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round">{SCAN_GLYPH}</svg></a>')
    return (f'<nav class="tabbar"><div class="tabs" style="max-width:290px;margin:0 auto">'
            f'<a class="tab{on_k}" style="flex:1">{tab_icon("kitchen")}Kitchen</a>'
            f'{orb}'
            f'<a class="tab{on_p}" style="flex:1">{tab_icon("progress")}Progress</a>'
            f'</div></nav>')

def note(title, paras, states, motion):
    ps = "".join(f"<p>{p}</p>" for p in paras)
    st = "".join(f"<dt>{d}</dt><dd>{v}</dd>" for d, v in states)
    mo = "".join(f"<dt>{d}</dt><dd>{v}</dd>" for d, v in motion)
    return (f'<aside class="note"><h1>{title}</h1>{ps}<h2>States</h2><dl>{st}</dl>'
            f'<h2>Motion</h2><dl>{mo}</dl></aside>')

def page(title, theme, body, note_html, extra_css=""):
    css = BASE_CSS + "\n/* screen */\n" + extra_css
    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FridgeLuck H: {title}</title>
<style>.t-{theme}{{ {VARS[theme]} }}
{css}</style>
</head>
<body>

{body}

{note_html}

</body>
</html>
'''

def phone(inner, theme):
    return f'<div class="phone t-{theme}">\n  <div class="island"></div>\n  {status()}\n{inner}\n  <div class="homebar"></div>\n</div>'

def screen_wrap(scroll_cls, content):
    return f'  <div class="screen"><div class="scroll {scroll_cls}">\n{content}\n  </div></div>'

def fit(n, total, gap_cls="o"):
    """Fit meter: n filled squares, total-n hollow in accent (the gap is the one chromatic pixel)."""
    return f'<span class="fit" role="img" aria-label="{n} of {total} ingredients on hand">' + \
           "<i></i>" * n + f'<i class="{gap_cls}"></i>' * (total - n) + "</span>"

def write(name, html):
    path = os.path.join(OUT, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(html)
    print(f"wrote {name} ({len(html)} bytes)")
