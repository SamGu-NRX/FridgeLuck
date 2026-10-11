# Direction H screens: Shell S (F's shell), Quests and Tour (candidates).
from hkit import tabbar, note, fit
from scr_recipe import RECIPE_CSS
from scr_social import SOCIAL_CSS

SHELL_CSS = """
.chips{display:flex;gap:8px;margin-top:8px;flex-wrap:wrap}
.head a.lnk{text-decoration:none}
.shell-links .row{padding:12px 0}
.shell-links a{color:var(--accink);text-decoration:none;font-size:15px}
"""

SHELL_NOTE = [
  "F's shell verbatim, adapted: two main tabs &mdash; Kitchen and Progress &mdash; with the central scan orb between them, because the scan is the app's verb. Profile lives inside Progress; LeChef, Cookbook and Explore hang off Kitchen as header links, not tabs &mdash; two tabs plus an orb read as calm, five as clutter. Tonight remains the launch screen, one tap deeper than a tab but always first.",
  "The orb is the single elevation: P's terracotta fill with the deep shadow, 56 pt, docked centre with its word. Everything else is hairlines. Progress is a tab here (F's structure) rather than a Kitchen sub-screen: cooked, streak, saved-from-waste counters in mono.",
  "Hybrid spacing: the shell keeps 44 pt tab targets (Fitts) with P's 12 px label gap; the bar uses hairline top rule only, no material.",
]

SHELL_STATES = [
  ("first run", "Progress empty state: &ldquo;Nothing here yet. Cook one thing.&rdquo; The orb stays &mdash; it is the only permanently-visible control."),
  ("scanning", "Orb pressed: expands to the camera sheet from its own position (origin-aware), dims the shell behind."),
  ("badge", "Needs-a-look count lives in the Kitchen tab caption (&ldquo;3&rdquo;), mono, never a red dot on the orb."),
]

def shell_body():
    return '''  <div class="screen"><div class="scroll dn">
    <header class="head in" style="--i:0"><h1>Kitchen</h1><a href="#" class="lnk cap c2">Explore &rarr;</a></header>

    <section class="sect in" style="--i:0">
      <h3>Use soon</h3>
      <div class="row"><i class="sq have"></i><span class="n">Spinach <span class="mono c2">1 bag</span></span><span class="tag">2 days</span></div>
      <div class="row"><i class="sq have"></i><span class="n">Greek yogurt <span class="mono c2">500 g</span></span><span class="tag">tomorrow</span></div>
    </section>

    <section class="sect in" style="--i:1">
      <h3>Needs a look <span class="mono">3</span></h3>
      <div class="row"><i class="sq unc"></i><span class="n">Milk, semi-skimmed <span class="mono c2">1 L</span><span class="chips"><button class="chip">Still open</button><button class="chip quiet">Gone</button></span></span></div>
    </section>

    <section class="sect in" style="--i:2">
      <h3>Fridge <span class="mono">14</span></h3>
      <div class="row"><i class="sq have"></i><span class="n">Chicken thighs</span><span class="q">4</span><span class="q c3 cap">today</span></div>
      <div class="row"><i class="sq have"></i><span class="n">Eggs</span><span class="q">6</span><span class="q c3 cap">today</span></div>
      <div class="row"><i class="sq have"></i><span class="n">Pak choi</span><span class="q">2 heads</span><span class="q c3 cap">today</span></div>
      <div class="row"><i class="sq have"></i><span class="n">Lemons</span><span class="q">2</span><span class="q c3 cap">4 d</span></div>
    </section>
  </div></div>
'''

def build_shell(write, page, phone):
    n = note("Shell S &mdash; two tabs + orb", SHELL_NOTE, SHELL_STATES, [("orb", "Press: scale 0.96 over 120 ms; the camera sheet grows from the orb's own frame &mdash; origin-aware, per F."), ("tab", "Switch: content crossfades 150 ms; the bar never moves."), ("reduced", "Sheet becomes a fade; nothing else moves.")])
    for theme in ("light", "dark"):
        html = page(f"Shell S ({theme})", theme, phone(shell_body(), theme) + tabbar("kitchen", shell="s"), n, SHELL_CSS)
        write(f"shell-s-kitchen{'-dark' if theme == 'dark' else ''}.html", html)

PROGRESS_NOTE = [
  "Progress, the second tab: three mono counters &mdash; cooked, streak, saved-from-waste &mdash; and the week's cooks in time order. F's structure (a tab, a dense list) with P's warmth kept out of the data: numbers stay ink, never accent-filled rings.",
  "Saved-from-waste is counted in grams of food used before it spoiled &mdash; the app's ecological promise in one line. Every number here is computable from the cook log; nothing is a score.",
  "Profile lives here, not on the bar: one row at the end, with the data controls (Forget) one tap away.",
]

PROGRESS_STATES = [
  ("first run", "&ldquo;Nothing here yet. Cook one thing.&rdquo; The counters render as 0 in ink-3, not dashes."),
  ("week boundary", "Monday 00:00 local: the week list archives to Cookbook; streak survives if Sunday had a cook."),
  ("offline", "Counters render from the local log (they are local); the cloud sync line shows &ldquo;As of 18:40&rdquo;."),
]

def progress_body():
    rows = "".join(f'<div class="row"><span class="n">{d}<br><span class="cap c2">{dish}</span></span><span class="q">{n_}</span><span class="q c3 cap">{when}</span></div>' for d, dish, n_, when in [
        ("Thu", "Butter bean curry", "5", "18:40"), ("Tue", "Egg-fried noodles", "4", "19:05"),
        ("Mon", "Miso mushroom udon", "5", "20:12")])
    return f'''  <div class="screen"><div class="scroll dn">
    <header class="head in" style="--i:0"><h1>Progress</h1><span class="cap c2 mono">week 41</span></header>

    <section class="sect in" style="--i:0">
      <div class="saved">
        <div><span class="big">12<small>cooked</small></span></div>
        <div><span class="big">3<small>week streak</small></span></div>
        <div><span class="big">1.2<small>kg saved</small></span></div>
      </div>
    </section>

    <section class="sect in" style="--i:1">
      <h3>This week</h3>
      {rows}
    </section>

    <section class="sect in" style="--i:2">
      <h3>You</h3>
      <div class="row"><span class="n">Profile &amp; data<br><span class="cap c2">Taste profile, Forget, sign out</span></span><span class="q c2">&rsaquo;</span></div>
    </section>
  </div></div>
'''

def build_shell_progress(write, page, phone):
    n = note("Shell S &mdash; Progress", PROGRESS_NOTE, PROGRESS_STATES, [("count", "Counters settle in place on entry; no count-up spin &mdash; the numbers are facts, not excitement.")])
    for theme in ("light", "dark"):
        html = page(f"Shell S Progress ({theme})", theme, phone(progress_body(), theme) + tabbar("progress", shell="s"), n, SHELL_CSS + QUEST_CSS)
        write(f"shell-s-progress{'-dark' if theme == 'dark' else ''}.html", html)

PROFILE_NOTE = [
  "Profile inside Progress, per the shell decision: one screen of rows, no cards. Data controls are first-class rows, not buried settings &mdash; the pantry-truth contract needs an explicit Forget.",
  "The taste profile row shows its size (&ldquo;23 cooks of evidence&rdquo;) so Forget is an informed choice, not a mystery button.",
  "No avatars, no display-name field, no gamification frames: the household is the account, the phone is the vault.",
]

PROFILE_STATES = [
  ("forget", "Confirm sheet: &ldquo;Forget 23 cooks of taste evidence? Recipes stay; the profile empties.&rdquo; Destructive verb, plain copy, one undo window of 5 s."),
  ("export", "Export row: writes cooks and pantry history to a file, on-device, share sheet after."),
  ("household", "Second cook joined: rows for shared Table and who cooked what; taste evidence stays per-person."),
]

def profile_body():
    return '''  <div class="screen"><div class="scroll dn">
    <header class="head in" style="--i:0"><h1>You</h1><span class="cap c2 mono">this phone</span></header>

    <section class="sect in" style="--i:0">
      <h3>Household</h3>
      <div class="row"><span class="n">Flat 4B &middot; 3 people</span></div>
    </section>

    <section class="sect in" style="--i:1">
      <h3>Evidence</h3>
      <div class="row"><span class="n">Taste profile<br><span class="cap c2">23 cooks of evidence &middot; 4 sentences learned</span></span><span class="q c2">&rsaquo;</span></div>
      <div class="row"><span class="n">Cookbook records<br><span class="cap c2">84 cooks &middot; ratings, swaps, notes</span></span><span class="q c2">&rsaquo;</span></div>
    </section>

    <section class="sect in" style="--i:2">
      <h3>Data</h3>
      <div class="row"><span class="n">Export everything<br><span class="cap c2">On-device file, share when you want</span></span><span class="q c2">&rsaquo;</span></div>
      <div class="row"><span class="n">Forget taste evidence<br><span class="cap c2">Recipes stay; the profile empties</span></span><span class="q c3">Forget</span></div>
    </section>
  </div></div>
'''

def build_shell_profile(write, page, phone):
    n = note("Shell S &mdash; Profile", PROFILE_NOTE, PROFILE_STATES, [("forget", "The Forget row never sits beside a primary action; it is the last row, quiet by position, confirmed by sheet.")])
    for theme in ("light", "dark"):
        html = page(f"Shell S Profile ({theme})", theme, phone(profile_body(), theme) + tabbar("progress", shell="s"), n, SHELL_CSS)
        write(f"shell-s-profile{'-dark' if theme == 'dark' else ''}.html", html)

QUEST_CSS = """
.qhead{display:flex;justify-content:space-between;align-items:baseline}
.qhead b{font-family:var(--serif);font-size:24px;line-height:30px;font-weight:700;letter-spacing:-.01em}
.rules{margin-top:10px}
.rules p{font-size:15px;line-height:20px;color:var(--ink2);padding:6px 0 0}
.big{font-family:var(--mono);font-variant-numeric:tabular-nums;font-size:44px;line-height:44px;font-weight:500;letter-spacing:-.02em;white-space:nowrap}
.big small{font-size:13px;letter-spacing:0;color:var(--ink2);display:block;margin-top:4px}
.saved{display:flex;gap:20px;margin-top:14px}
.saved>div{flex:1}
"""

QUEST_NOTE = [
  "Quests, the community candidate, rendered in the hybrid's quiet register: no badges, no rarity colours, no progress rings with gradients. A quest is a sentence, a mono counter of cooks made, and &ldquo;works alone&rdquo; stated up front.",
  "Rewards are use: finishing a quest adds a filter chip you've earned (&ldquo;under 30 min&rdquo;) and a line in Cookbook. Never points, never a currency.",
  "The accent appears exactly three times on this screen: the joined state, the counter digits, and the primary button. If everything is highlighted, nothing is.",
]

QUEST_STATES = [
  ("empty", "&ldquo;No quests this week. Cook something and it may become one.&rdquo;"),
  ("joined", "Shown: joined state in accent-soft with the counter; Leave is quiet text, never destructive red &mdash; leaving is not an error."),
  ("done", "The counter holds at its final value; the row reads &ldquo;You made 4 &mdash; this one's done&rdquo; with the reward chip attached."),
  ("offline", "Last week's quests render cached with &ldquo;As of Sunday&rdquo;; joining queues and reconciles on reconnect with a visible receipt."),
]

def quests_body():
    return '''  <div class="screen"><div class="scroll dn">
    <header class="head in" style="--i:0"><h1>Quests</h1><span class="cap c2 mono">3 this week</span></header>

    <section class="sect in" style="--i:0">
      <div class="qhead"><b>Three ingredients, what can you make?</b></div>
      <p class="sec" style="margin-top:4px">Rice, eggs, frozen peas. Cook something with all three, save it to Cookbook.</p>
      <div class="rules">
        <div class="row" style="padding:10px 0 0"><span class="n sec">Works alone &middot; any method &middot; ends Sunday</span><span class="q mono">14 cooking</span></div>
      </div>
      <div class="foot" style="margin-top:14px;border-top:0;padding-top:0;flex-direction:row;align-items:center;gap:12px">
        <span class="chip on">Joined</span>
        <button class="btn ghost" style="width:auto;height:44px;padding:0 16px;border-radius:12px">Share your result</button>
      </div>
    </section>

    <section class="sect in" style="--i:1">
      <h3>Your week</h3>
      <div class="saved">
        <div><span class="big">4<small>cooks made</small></span></div>
        <div><span class="big">2<small>swaps used</small></span></div>
        <div><span class="big">620 g<small>food saved</small></span></div>
      </div>
    </section>

    <section class="sect in" style="--i:2">
      <h3>Also this week</h3>
      <div class="row"><span class="n">Use the saddest thing in your fridge<br><span class="cap c2">Works alone &middot; ends Sunday</span></span><span class="q mono">31 cooking</span></div>
      <div class="row"><span class="n">Meatless Monday, together<br><span class="cap c2">Needs your table &middot; ends Monday</span></span><span class="q mono">8 cooking</span></div>
    </section>
  </div></div>
'''

def build_quests(write, page, phone):
    n = note("Quests (candidate)", QUEST_NOTE, QUEST_STATES, [("join", "Joined fills on snap with a light haptic; the counter counts up once over 500 ms, mono, then holds."), ("share", "Opens the share preview &mdash; the same disclosure as Table."), ("reduced", "Count settles instantly.")])
    for theme in ("light", "dark"):
        html = page(f"Quests ({theme})", theme, phone(quests_body(), theme), n, QUEST_CSS)
        write(f"candidates-quests{'-dark' if theme == 'dark' else ''}.html", html)

TOUR_NOTE = [
  "The one place motion leads: three frames, each a single promise, each rising on snap with the fit count animating once. No autoplay carousel; the dots are mono numerals.",
  "Asks are honest and separate: notifications (&ldquo;Only timers and one weekly nudge&rdquo;), camera (&ldquo;Photos stay on the phone until you press Add&rdquo;), nothing else. No &ldquo;Allow full access&rdquo; wall.",
  "Type scale: serif 32 promise, 17/24 body, one primary button 50 pt. The skip is text, top-right, always available.",
]

TOUR_STATES = [
  ("permission", "Shown: the camera ask rendered as the app would phrase it, with the system sheet mocked beneath &mdash; the app's promise sits above the OS dialog, never instead of it."),
  ("skipped", "Skip lands on a working, empty Tonight: &ldquo;Nothing yet. Add what you have.&rdquo; with manual entry first-class."),
  ("reduced", "The count animates only if motion is allowed; under reduced motion it appears settled."),
  ("a11y", "Every frame: 17 pt body minimum, Dynamic Type honoured to XXL, VoiceOver reads promise then button; the illustration is decorative."),
]

def tour_body():
    return '''  <div class="screen"><div class="scroll dn" style="justify-content:space-between;min-height:100%;display:flex;flex-direction:column;padding-bottom:0">
    <div class="nav" style="display:flex;justify-content:flex-end;padding-top:6px"><a href="#" class="cap c2" style="color:var(--ink2);text-decoration:none;padding:12px">Skip</a></div>
    <div>
      <h2 class="title in" style="--i:0">Cook what you already have.</h2>
      <p class="sec in" style="--i:1" style2="">Scan a shelf and FridgeLuck counts it. Tonight picks from what's really there &mdash; and says when it's guessing.</p>
      <div class="photo in" style="--i:1;height:240px;margin-top:16px"><span>photo: fridge shelf, daylight</span></div>
      <div class="fitblock in" style="--i:2;margin-top:16px">
        <div>''' + fit(0, 10) + '''<p class="sec" style="margin-top:6px">Your fit &mdash; starts at zero, grows as it learns</p></div>
      </div>
      <div class="foot in" style="--i:3;border-top:0;flex-direction:column;gap:8px;margin-top:16px">
        <span class="cap c2">Camera photos stay on the phone until you press Add.</span>
        <span class="cap c2">Cooking history stays on this phone unless you share it.</span>
      </div>
    </div>
    <div class="in" style="--i:4;padding-bottom:36px">
      <button class="btn primary" style="height:50px">Scan your first shelf</button>
      <p class="cap c2" style="text-align:center;padding-top:10px">1 of 3 &middot; no account needed</p>
    </div>
  </div></div>
'''

def build_tour(write, page, phone):
    n = note("Tour (candidate)", TOUR_NOTE, TOUR_STATES, [("count", "The fit numeral animates once over 600 ms, mono tabular, ease-out &mdash; the only count-up in the app."), ("enter", "Frame blocks rise 40 ms apart on snap."), ("reduced", "Count appears settled; rises become fades.")])
    for theme in ("light", "dark"):
        html = page(f"Tour ({theme})", theme, phone(tour_body(), theme), n, RECIPE_CSS + SOCIAL_CSS)
        write(f"candidates-tour{'-dark' if theme == 'dark' else ''}.html", html)

def build(write, page, phone):
    build_shell(write, page, phone)
    build_shell_progress(write, page, phone)
    build_shell_profile(write, page, phone)
    build_quests(write, page, phone)
    build_tour(write, page, phone)
