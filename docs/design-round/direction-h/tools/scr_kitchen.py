# Direction H screens: kitchen (light/dark) and scan-review (light/dark).
from hkit import tabbar, note

CSS = """
.chips{display:flex;gap:8px;margin-top:8px;flex-wrap:wrap}   /* dense chips: 8 */
.ask{padding:12px 0;border-top:1px solid var(--rule)}
.ask:first-of-type{border-top:0}
.ask .top{display:flex;gap:12px;align-items:center}
.ask .q{flex:1}
.addrow{display:flex;gap:20px;align-items:center;margin-top:24px;padding:14px 0;color:var(--ink2)}
.addrow a{display:flex;gap:8px;align-items:center;color:var(--accink);text-decoration:none;font-size:15px}
.dock p.cap{padding:0 14px 0 6px;align-self:center}
.staples p{padding:10px 0 2px;font-size:13px;line-height:18px;color:var(--ink2)}
.staples .label{color:var(--ink)}
.searchf{display:flex;align-items:center;gap:8px;height:44px;border:1px solid var(--rule);border-radius:12px;padding:0 12px;color:var(--ink3);font-size:15px}
"""

KITCHEN_NOTE = [
  "The dense screen: 20 px side margins, 44 pt rows, 12 within a row, sections at 24. The eye should take in a shelf's worth without scrolling. No icons per ingredient &mdash; text is faster to scan than fifty tiny vegetables.",
  "Order is by what needs a decision. Use soon first, each tag a terracotta-soft chip with a word in it (the warning is an action). Then &ldquo;needs a look&rdquo;: dashed rows the app is unsure about, with Yes / Gone inline so the truth model improves without a separate chore. Then the locations.",
  "Row states are shape-first, borrowed from F and extended for the pantry-truth contract: filled square = confirmed; hollow accent stroke = short or missing; dashed = unconfirmed; grey ring = assumed staple (always captioned &ldquo;assumed&rdquo;). Quantities and ages sit right in mono.",
  "Assumed staples are a sentence, not a list, because they are a policy rather than inventory. &ldquo;Change&rdquo; opens the checklist.",
]

KITCHEN_STATES = [
  ("empty", "Never scanned: title, then &ldquo;Scan a shelf to start. One shelf, straight on, works best.&rdquo; with Scan groceries and Add by name of equal rank &mdash; manual entry is first-class when the kitchen is unknown. No sample data."),
  ("stale", "Last scan over 7 days ago: an updated line becomes a row, &ldquo;Last scan 9 days ago. Tonight's picks may be off.&rdquo; with Scan now. Nothing is auto-expired; the app asks via &ldquo;needs a look&rdquo;."),
  ("reconcile", "A shelf scan observes, never adds: rows read &ldquo;Still 2?&rdquo; with Yes / Bought more. Only a receipt or manual entry adds stock."),
  ("loading", "None. Kitchen is local. After a scan, new rows enter at the top of their section with the snap rise and &ldquo;today&rdquo; in the age column."),
  ("error", "None for reading. A failed backup is one line at the bottom, &ldquo;Not backed up since Tuesday&rdquo;, never a modal."),
  ("search", "Inline field replaces the title; sections collapse to matching rows; &ldquo;Add 'tahini'&rdquo; appears as the last result when nothing matches."),
  ("edit", "Tap a row: inline stepper for quantity and a date for use-by, plus Remove. Swipe left: Remove. Swipe right: Used up (deducts and teaches the app the real rate)."),
  ("leftovers", "A cooked meal saved as a portion shows as a row named after the dish with its date; on Tonight it carries its reheat time; frozen portions say how long they need to thaw."),
]

KITCHEN_MOTION = [
  ("answer", "Yes / Gone chip press: the row loses its dashed state (150 ms crossfade) or slides out on the settle spring. Light haptic."),
  ("used up", "Row slides right following the finger; release past 40% or a flick completes; the section count updates with the fade token."),
  ("reduced", "Slides become fades; counts still update."),
]

def kitchen_body():
    r = '<div class="row"><i class="sq have"></i><span class="n">{n}</span><span class="q">{q}</span><span class="q c3 cap">{a}</span></div>'
    fridge = "".join(r.format(n=n, q=q, a=a) for n, q, a in [
        ("Chicken thighs", "4", "today"), ("Eggs", "6", "today"), ("Pak choi", "2 heads", "today"),
        ("Spring onions", "1 bunch", "today"), ("Ginger", "1 piece", "today"), ("Red chilli", "3", "today"),
        ("Lemons", "2", "4 d"), ("Cheddar", "block", "9 d"), ("Butter", "open", "12 d"), ("Soy sauce", "open", "3 wk")])
    freezer = "".join(r.format(n=n, q=q, a=a) for n, q, a in [
        ("Peas", "&frac12; bag", ""), ("Chicken breasts", "2", ""),
        ("Butter bean curry<small>Leftovers, 28 Sept</small>", "1 portion", ""), ("Bread", "&frac12; loaf", "")])
    pantry = "".join(r.format(n=n, q=q, a=a) for n, q, a in [
        ("Udon noodles", "2 packs", ""), ("Chickpeas, tinned", "3", ""), ("Butter beans, tinned", "2", ""), ("Coconut milk", "1", "")])
    return f'''  <div class="screen"><div class="scroll dn">
    <header class="head in" style="--i:0"><h1>Kitchen</h1><span class="cap c2 mono">58 items &middot; 3 need a look</span></header>

    <section class="sect in" style="--i:0">
      <h3>Use soon</h3>
      <div class="row"><i class="sq have"></i><span class="n">Spinach <span class="mono c2">1 bag</span></span><span class="tag">2 days</span></div>
      <div class="row"><i class="sq have"></i><span class="n">Greek yogurt <span class="mono c2">500 g</span></span><span class="tag">tomorrow</span></div>
      <div class="row"><i class="sq have"></i><span class="n">Lime <span class="mono c2">&frac12;</span></span><span class="tag">today</span></div>
    </section>

    <section class="sect in" style="--i:1">
      <h3>Needs a look</h3>
      <div class="row"><i class="sq unc"></i><span class="n">Milk, semi-skimmed <span class="mono c2">1 L</span><br><span class="cap c2">Last confirmed 3 wk ago</span><span class="chips"><button class="chip">Still open</button><button class="chip quiet">Gone</button></span></span></div>
      <div class="row"><i class="sq unc"></i><span class="n">Double cream <span class="mono c2">150 ml</span><br><span class="cap c2">Scanned once, never confirmed</span><span class="chips"><button class="chip">Confirm</button><button class="chip quiet">Gone</button></span></span></div>
    </section>

    <section class="sect in" style="--i:1">
      <h3>Fridge <span class="mono">14</span></h3>
      {fridge}
    </section>

    <section class="sect in" style="--i:2">
      <h3>Freezer <span class="mono">4</span></h3>
      {freezer}
    </section>

    <section class="sect in" style="--i:2">
      <h3>Pantry <span class="mono">10</span></h3>
      <div class="staples"><p><span class="label">Assumed</span> Olive oil, salt, pepper, rice, pasta, sesame oil, honey. Recipes count these as here. <a href="#">Change</a></p></div>
      {pantry}
    </section>

    <div class="addrow in" style="--i:2">
      <a href="#"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 9V6a2 2 0 0 1 2-2h3M15 4h3a2 2 0 0 1 2 2v3M20 15v3a2 2 0 0 1-2 2h-3M9 20H6a2 2 0 0 1-2-2v-3"/><circle cx="12" cy="12" r="3"/></svg>Scan groceries</a>
      <a href="#">Add by name</a>
    </div>
  </div></div>
'''

def build_kitchen(write, page, phone):
    n = note("Kitchen", KITCHEN_NOTE, KITCHEN_STATES, KITCHEN_MOTION)
    for theme in ("light", "dark"):
        html = page(f"Kitchen ({theme})", theme, phone(kitchen_body() + tabbar("kitchen"), theme), n, CSS)
        write(f"kitchen{'-dark' if theme == 'dark' else ''}.html", html)

SCAN_NOTE = [
  "The screen asks only the questions the camera could not answer, and asks them first. Three &ldquo;needs you&rdquo; rows, each with a thumbnail crop, one line about what it saw, and the two likely answers as chips (Miller's law: three uncertain items alone, then a list to skim).",
  "The title count is mono because it is a number the user checks against the shelf. There is no confidence percentage anywhere &mdash; recognition confidence is not quantity confidence.",
  "Selected chips use the accent the way F used yolk: one meaning (your selection), always with a word. Unanswered rows are allowed; the button still works and unanswered items go to Kitchen's &ldquo;needs a look&rdquo; queue rather than blocking.",
  "The primary button names what happens and the count. The caption under it says why it matters. The dock is the one glass surface on a content screen (system glass), and the one shadow.",
]

SCAN_STATES = [
  ("analysing", "Photo at top, 4:5. Title reads &ldquo;Looking&rdquo;. One 2 px indeterminate line under it. Rows appear as recognised, each with the snap rise; no scanning laser, no shimmer."),
  ("all sure", "The &ldquo;needs you&rdquo; section is absent. Title: &ldquo;Found 9 things&rdquo;, subtitle: &ldquo;All look right.&rdquo; Button unchanged."),
  ("nothing", "&ldquo;Nothing I recognise. Try one shelf, straight on, with the door light on.&rdquo; Buttons: Retake, Add by name."),
  ("dark/blur", "Detected before upload: &ldquo;Too dark to read&rdquo; or &ldquo;Too blurry&rdquo; with Retake. Shown over the photo, not as an alert."),
  ("error", "Recognition request failed: photo stays, &ldquo;Couldn't read this photo. Try again or add by name.&rdquo; Retry keeps the photo; no re-capture required."),
  ("receipt", "Same screen; a receipt adds stock. Rows carry the receipt line in caption under the normalised name (&ldquo;ORG SPNCH 200G&rdquo;). Quantities come from the receipt."),
  ("plate", "Camera saw a cooked dish, not a shelf: a one-line switch at the top, &ldquo;This looks like a meal. Log it instead?&rdquo; with Yes / No. Never auto-switches."),
  ("duplicates", "Item already in Kitchen: the scan observes, it never adds. The row reads &ldquo;Still 2?&rdquo; with Yes / Bought more &mdash; shown here on Lemons."),
]

SCAN_MOTION = [
  ("chip", "Background and stroke crossfade 150 ms; press 0.97. No layout shift when selected."),
  ("remove", "Swipe follows the finger; release past 40% or a flick dismisses on the settle spring; the row below slides up on snap."),
  ("confirm", "Button press, medium haptic, push to Tonight. No celebration."),
]

def scan_body():
    asks = [
        ("Leafy, pale stems, top shelf.", ["Pak choi", "Chinese cabbage"], "Pak choi"),
        ("Small red chillies in the door.", ["Red chilli", "Bird's-eye chilli"], None),
        ("Hard cheese, wedge, wrapped.", ["Parmesan", "Pecorino"], None),
    ]
    ask_rows = ""
    for i, (q, chips, on) in enumerate(asks):
        chips_html = "".join(f'<button class="chip{" on" if c == on else ""}">{c}</button>' for c in chips) + '<button class="chip quiet">Neither</button>'
        ask_rows += f'''      <div class="ask in" style="--i:{min(i, 2)}">
        <div class="top"><div class="photo thumb"></div><div class="q sec">{q}</div></div>
        <div class="chips">{chips_html}</div>
      </div>\n'''
    sure = "".join(f'<div class="row"><i class="sq have"></i><span class="n">{n}</span><span class="q">{q}</span></div>'
                   for n, q in [("Chicken thighs", "4"), ("Eggs", "6"), ("Greek yogurt", "500 g"), ("Spinach", "1 bag"),
                                 ("Spring onions", "1 bunch"), ("Ginger", "1 piece"), ("Udon noodles", "2 packs"), ("Soy sauce", "open")])
    lemons = '''      <div class="row"><i class="sq have"></i><span class="n">Lemons <span class="mono c2">2</span><br><span class="cap c2">In your kitchen already — a scan never adds</span><span class="chips"><button class="chip">Still 2</button><button class="chip quiet">Bought more</button></span></span></div>\n'''
    return f'''  <div class="screen"><div class="scroll dn" style="padding-bottom:170px">
    <header class="head in" style="--i:0"><h1>Scan</h1><span class="cap c2 mono">14 seen &middot; 11 sure</span></header>

    <section class="sect in" style="--i:0" style2="">
      <h3>Needs you <span class="mono">3</span></h3>
{ask_rows}    </section>

    <section class="sect in" style="--i:2">
      <h3>Looks right <span class="mono">11</span></h3>
{sure}
{lemons}      <div class="row"><svg width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M10 4v12M4 10h12"/></svg><span class="n">Missed something? Add by name</span></div>
    </section>
  </div></div>

  <div class="dock">
    <button class="btn primary" style="flex:1">Add 14 to kitchen</button>
    <p class="cap c2" style="text-align:center">Tonight's pick updates when you do.</p>
  </div>
'''

def build_scan(write, page, phone):
    n = note("Scan review", SCAN_NOTE, SCAN_STATES, SCAN_MOTION)
    for theme in ("light", "dark"):
        html = page(f"Scan review ({theme})", theme, phone(scan_body(), theme), n, CSS)
        write(f"scan-review{'-dark' if theme == 'dark' else ''}.html", html)

def build(write, page, phone):
    build_kitchen(write, page, phone)
    build_scan(write, page, phone)
