# Direction H screens: taste-profile, explore, table (light/dark each).
from hkit import tabbar, note, fit

SOCIAL_CSS = """
.rt{display:flex;flex-direction:column;align-items:flex-end;gap:2px;flex:none}
.ts{padding:12px 0;border-top:1px solid var(--rule)}
.ts:first-of-type{border-top:0}
.ts .s{display:flex;justify-content:space-between;align-items:baseline;gap:12px}
.ts .s p{font-size:17px;line-height:24px;flex:1}
.ts .ev{font-family:var(--mono);font-variant-numeric:tabular-nums;font-size:13px;line-height:16px;color:var(--ink2);white-space:nowrap}
.ts .ctl{display:flex;gap:8px;margin-top:8px;align-items:center}
.sb{height:36px;padding:0 14px;border-radius:10px;box-shadow:inset 0 0 0 1px var(--rule2);background:transparent;font:inherit;font-size:15px;color:var(--ink);cursor:pointer;transition:transform 120ms var(--out)}
.sb:active{transform:scale(.97)}
.sb.on{background:var(--accsoft);color:var(--accink);box-shadow:inset 0 0 0 1.5px var(--acc)}
.sb.q{color:var(--ink2)}
.ts .state{font-size:13px;color:var(--ink2)}
.ts.off .s p{color:var(--ink2);text-decoration:line-through}
.mem{padding:12px 0;border-top:1px solid var(--rule)}
.mem:first-of-type{border-top:0}
.mem .t{display:flex;justify-content:space-between;align-items:baseline}
.mem .t b{font-size:15px;font-weight:600}
.mem .t a{font-size:13px;color:var(--ink2)}
.mem q{display:block;font-size:15px;line-height:20px;margin:4px 0}
.chips{display:flex;gap:8px;flex-wrap:wrap}
.chip .x{display:inline-flex}
.foot{display:flex;flex-direction:column;gap:10px;margin-top:28px;padding-top:16px;border-top:1px solid var(--rule)}
.foot a{color:var(--ink2);font-size:15px;text-decoration:none}
.foot a.danger{color:var(--err)}
.searchf{display:flex;align-items:center;gap:8px;height:44px;border:1px solid var(--rule);border-radius:12px;padding:0 12px;color:var(--ink3);font-size:15px;margin-top:4px}
.card{border:1px solid var(--rule);border-radius:14px;padding:14px 16px;margin-top:12px}
.card .who{display:flex;justify-content:space-between;align-items:baseline}
.card .who b{font-size:15px;font-weight:600}
.card .dish{font-family:var(--serif);font-size:20px;line-height:25px;font-weight:600;letter-spacing:-.01em;margin:6px 0 10px}
.card .body{display:flex;gap:12px}
.card .body .photo{width:96px;height:96px;flex:none}
.card .body q{display:block;font-size:15px;line-height:20px}
.card .rate{font-family:var(--mono);font-variant-numeric:tabular-nums;font-size:13px;color:var(--ink2);margin-top:4px}
.card .you{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-top:12px;padding-top:12px;border-top:1px solid var(--rule)}
.card .you .l{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.card .you .btn{width:auto;height:44px;padding:0 16px;flex:none;border-radius:12px}
.card.mine{background:var(--surface)}
.pips{display:inline-flex;gap:4px}
.pips i{width:10px;height:10px;border-radius:2px;box-shadow:inset 0 0 0 1.5px var(--rule2)}
.pips i.d{background:var(--ink);box-shadow:none}
"""

TP_NOTE = [
  "The whole learning system in one readable page: sentences the app would say out loud, each with the count it is based on and a Right / Wrong control. No sliders, no percentages, no personality labels. Confidence lives in language and in counts.",
  "Three layers keep their separation: explicit restrictions are the hard filters (edited in setup, never weakened here), stated preferences are the setup lines at the bottom, inferred taste is every sentence above. Evidence uses distinct opportunities with denominators and recency &mdash; &ldquo;4 of the 5 times&rdquo;, never &ldquo;5 observations&rdquo;.",
  "The three row states: default Right / Wrong; confirmed, where Right holds in accent-soft and the row says what the app will now do (&ldquo;Never suggested.&rdquo;); rejected, where the row dims, the sentence strikes, and &ldquo;Won't use this&rdquo; sits beside Undo. Nothing is deleted on Wrong &mdash; it is excluded and kept so the app does not re-learn it next week. &ldquo;Don't ask again&rdquo; is a different control from &ldquo;This is wrong&rdquo;.",
  "Hybrid note: the evidence counts and the confirmed chip are where the accent appears here (selection/attention); the sentences themselves stay in walnut ink &mdash; the learning page must feel like a ledger, not a horoscope.",
]

TP_STATES = [
  ("new user", "Under 3 cooks, one sentence instead of the list: &ldquo;Cook three things and I'll start writing this. Until then I'm using what you told me at setup.&rdquo;"),
  ("rejected", "Shown in the frame: the row dims, strikes, and reads &ldquo;Won't use this.&rdquo; with Undo. Undo restores it exactly."),
  ("forget one", "&ldquo;Forget this&rdquo; under each remembered note removes that line with a visible receipt; the sentence can be reopened &mdash; changing your mind never requires a reset."),
  ("forget all", "&ldquo;Forget everything&rdquo; at the bottom, in error red, asks once with the count of what will be deleted. Explicit restrictions survive any reset."),
  ("ask again", "A weak inference expires on its own; the app never asks twice about the same pattern."),
  ("export", "&ldquo;Export everything I know about you&rdquo; writes a readable file to Files. Learning runs on the phone; nothing about taste leaves the device except by that export."),
]

TP_MOTION = [
  ("judge", "Right/Wrong press: the row state crossfades 150 ms under a stable height; the confirmed chip fills on snap."),
  ("undo", "Undo reverses in one 150 ms fade; no reflow."),
  ("reduced", "All becomes opacity-only."),
]

def tp_body():
    return '''  <div class="screen"><div class="scroll dn">
    <header class="head in" style="--i:0"><h1>Your taste</h1><span class="cap c2 mono">23 cooks</span></header>

    <section class="sect in" style="--i:0">
      <h3>What I've learned</h3>
      <div class="ts">
        <div class="s"><p>You cook on weeknights, mostly under 30 minutes.</p><span class="ev">18 of 23</span></div>
        <div class="ctl"><button class="sb">Right</button><button class="sb">Wrong</button></div>
      </div>
      <div class="ts">
        <div class="s"><p>You reach for chicken thighs, chickpeas and noodles.</p><span class="ev">9 &middot; 6 &middot; 7</span></div>
        <div class="ctl"><button class="sb">Right</button><button class="sb">Wrong</button></div>
      </div>
      <div class="ts">
        <div class="s"><p>You skip coriander.</p><span class="ev">5 of 5</span></div>
        <div class="ctl"><button class="sb on">Right</button><span class="state">Confirmed 3 Oct. Never suggested.</span></div>
      </div>
      <div class="ts">
        <div class="s"><p>You like it hot. Three dishes marked &ldquo;hot&rdquo; got a 5 from you.</p><span class="ev">3 of 3</span></div>
        <div class="ctl"><button class="sb">Right</button><button class="sb">Wrong</button></div>
      </div>
      <div class="ts off">
        <div class="s"><p>You eat late, after 9 pm.</p><span class="ev">4 of 23</span></div>
        <div class="ctl"><span class="state">Won't use this.</span><button class="sb q">Undo</button></div>
      </div>
      <div class="ts">
        <div class="s"><p>You come back to Butter bean curry about every 10 days.</p><span class="ev">3 cooks</span></div>
        <div class="ctl"><button class="sb">Right</button><button class="sb">Wrong</button></div>
      </div>
      <div class="ts">
        <div class="s"><p>You've never cooked fish here.</p><span class="ev">0 of 23</span></div>
        <div class="ctl"><button class="sb">Suggest some</button><button class="sb">Not interested</button></div>
      </div>
    </section>

    <section class="sect in" style="--i:1">
      <h3>Never suggest</h3>
      <div class="chips">
        <span class="chip">Coriander<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M3 3l8 8M11 3 3 11"/></svg></span>
        <span class="chip">Blue cheese<svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M3 3l8 8M11 3 3 11"/></svg></span>
        <span class="chip">Shellfish <span class="cap c2">allergy &middot; edited in setup</span></span>
        <span class="chip"><svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M8 3v10M3 8h10"/></svg>Add</span>
      </div>
    </section>

    <section class="sect in" style="--i:1">
      <h3>LeChef remembers <span class="mono">4</span></h3>
      <div class="mem"><div class="t"><b>Butter bean curry</b><a href="#">Forget</a></div><q>Too salty. Low-sodium stock next time.</q><span class="cap c2 mono">3 Oct</span></div>
      <div class="mem"><div class="t"><b>Ginger chicken udon noodles</b><a href="#">Forget</a></div><q>Lemon instead of lime worked.</q><span class="cap c2 mono">28 Sept</span></div>
      <div class="mem"><div class="t"><b>Chicken jalfrezi</b><a href="#">Forget</a></div><q>Needs another 10 min on the onions.</q><span class="cap c2 mono">21 Sept</span></div>
    </section>

    <section class="sect in" style="--i:2">
      <h3>What you told me at setup <a href="#">Edit</a></h3>
      <p class="sec c2" style="padding-top:8px">No shellfish &middot; cooking for 2 &middot; metric</p>
    </section>

    <div class="foot in" style="--i:2">
      <a href="#">Export everything I know about you</a>
      <a href="#" class="danger">Forget everything</a>
    </div>
  </div></div>
'''

def build_tp(write, page, phone):
    n = note("Your taste", TP_NOTE, TP_STATES, TP_MOTION)
    for theme in ("light", "dark"):
        html = page(f"Taste profile ({theme})", theme, phone(tp_body(), theme) + tabbar("cookbook"), n, SOCIAL_CSS)
        write(f"taste-profile{'-dark' if theme == 'dark' else ''}.html", html)

EXPLORE_NOTE = [
  "Explore answers &ldquo;what could I cook that others made&rdquo;, ranked by what you can make now: your own fit line, in mono, on every row. No like counts, no follower counts &mdash; &ldquo;cooked by 37 people&rdquo; appears only above ten distinct cooks and only from opted-in data.",
  "Search and filters behave like everywhere else in the app. The fit meter's accent gap appears wherever a row is not 10 of 10, so the ranking reads before the words do.",
  "User recipes and catalog recipes share the list without a visual caste. A LeChef draft keeps its own section, labelled &ldquo;Made for your fridge&rdquo;, and carries no cook notes until promoted by a tested cook.",
  "Publishing is a previewed, separate action with a rights declaration; until the moderation check passes, a published recipe is visible only to its author.",
]

EXPLORE_STATES = [
  ("empty", "&ldquo;Nothing published yet. Be the first &mdash; write one in your cookbook and preview before it goes up.&rdquo; Buttons: Open cookbook, Search the catalog."),
  ("pending", "Your published row shows a caption &ldquo;In review &mdash; only you can see it&rdquo; with a dashed square; it can be withdrawn at any time."),
  ("low counts", "Any recipe under 10 cooks shows no count at all; the row reads &ldquo;Be the first to cook this&rdquo; and nothing is invented."),
  ("offline", "Cached rows render with &ldquo;As of 18:40&rdquo;; fit meters still compute on device."),
  ("search", "Zero hits: &ldquo;Nothing matched 'tahini'. Fewer filters? Clear&rdquo; &mdash; never a blank page."),
]

EXPLORE_MOTION = [
  ("rank", "Refiltering re-ranks with the fade token (150 ms) under a stable frame; rows do not fly."),
  ("enter", "First three rows rise on snap; the rest appear."),
  ("reduced", "Ranking changes become instant fades."),
]

def explore_body():
    row = ('<div class="row"><span class="n">{name}<br><span class="cap c2">{sub}</span></span>'
           '<span class="rt"><span class="q c2">{time}</span><span class="q">{fit}{sw}</span></span></div>')
    can = "".join(row.format(name=n, sub=s, time=t, fit=f, sw="") for n, s, t, f in [
        ("Butter bean curry", "Maya &middot; cooked by 37 people", "35 min", "10 of 10"),
        ("Smoky aubergine, white beans", "Published by Tom &middot; cooked by 41 people", "30 min", "10 of 10"),
        ("Miso mushroom udon", "Catalog &middot; cooked by 118 people", "20 min", "10 of 10")])
    swap = "".join(row.format(name=n, sub=s, time=t, fit=f, sw=" &middot; 1 swap") for n, s, t, f in [
        ("Crispy kale &amp; egg rice", "Published by Priya &middot; cooked by 24 people", "15 min", "9 of 10"),
        ("Chicken jalfrezi", "Catalog &middot; cooked by 86 people", "45 min", "8 of 10")])
    return f'''  <div class="screen"><div class="scroll dn">
    <header class="head in" style="--i:0"><h1>Explore</h1><a href="#" class="lnk cap c2">Publish yours</a></header>

    <div class="searchf in" style="--i:0"><svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="7" cy="7" r="4.5"/><path d="m10.5 10.5 3 3"/></svg>Search recipes and cooks</div>

    <section class="sect in" style="--i:1">
      <div class="chips">
        <button class="chip on">Can cook now</button>
        <button class="chip">Under 30 min</button>
        <button class="chip">Vegetarian</button>
        <button class="chip quiet">Any cuisine</button>
      </div>
    </section>

    <section class="sect in" style="--i:1">
      <h3>Can cook now</h3>
      {can}
    </section>

    <section class="sect in" style="--i:2">
      <h3>One swap away</h3>
      {swap}
    </section>

    <section class="sect in" style="--i:2">
      <h3>Made for your fridge</h3>
      <div class="row"><span class="n">Udon greens soup<br><span class="cap c2">Private draft &middot; no cook notes until tested</span></span><span class="rt"><span class="q c2">18 min</span><span class="q">10 of 10</span></span></div>
    </section>
  </div></div>
'''

def build_explore(write, page, phone):
    n = note("Explore", EXPLORE_NOTE, EXPLORE_STATES, EXPLORE_MOTION)
    for theme in ("light", "dark"):
        html = page(f"Explore ({theme})", theme, phone(explore_body(), theme) + tabbar("explore"), n, SOCIAL_CSS)
        write(f"explore{'-dark' if theme == 'dark' else ''}.html", html)

TABLE_NOTE = [
  "A table is 2 to 8 people who eat together or near each other. The unit is a cook, created by finishing one: dish, who, when, the one-line note, rating, substitutions, optional photo. Nobody writes a post.",
  "Every card ends with the viewer's own fit meter and one button. That line is why this is not a dead feed: each card is a decision you can act on with what is in your fridge. &ldquo;Cook tonight&rdquo; sets the dish on Tonight with Maya's note attached to the relevant step.",
  "No likes, no comments, no follower counts, no ranking; cards are in time order. Your own cook has no button &mdash; it is here so the table sees what you see.",
  "The challenge block is the community candidate rendered quietly: entries reward cooks made and food saved, never opens. Share preview: sharing a cook shows exactly what leaves the phone &mdash; recipe revision, servings, swaps, rating, optional one-line note; never pantry, health data, taste data or exact times.",
]

TABLE_STATES = [
  ("no table", "Title &ldquo;Table&rdquo;, then: &ldquo;Tables are small on purpose: 2 to 8 people who cook. Start one with someone you eat with.&rdquo; Buttons: Start a table, Join with a code. The notes section still renders from your own cooks."),
  ("alone", "One member (you): your cooks as cards, plus a single row, &ldquo;Invite someone. Tables work from 2.&rdquo;"),
  ("quiet", "No cooks this week: the week line reads &ldquo;Nobody's cooked this week. Your last was Sunday.&rdquo;"),
  ("loading", "Cached cards render instantly; new ones arrive at the top on the move token. One 2 px line under the week row while fetching."),
  ("offline", "Cached cards with &ldquo;As of 18:40&rdquo;. Fit meters still compute locally. Notes section hidden."),
  ("error", "Fetch failed with nothing cached: &ldquo;Couldn't reach your table. Your cooks are safe on this phone.&rdquo; Retry."),
  ("invite", "Share sheet with a code and a link the owner approves; invites are revocable, members can leave, block and report."),
  ("share preview", "Before any share, a preview of exactly what leaves the phone: recipe revision, servings, swaps, rating, one-line note. Never pantry, health, taste data, or exact times beyond the day. No photo sharing in the first release."),
]

TABLE_MOTION = [
  ("enter", "Header, week line and first three cards rise 40 ms apart; later cards appear without stagger."),
  ("new cook", "Arrives at the top from scale 0.96 on the move token; the list below shifts with a transition."),
  ("cook tonight", "Medium haptic, switch to Tonight with the hero already swapped (150 ms crossfade on arrival)."),
]

def table_body():
    card = '''    <article class="card in" style="--i:1">
      <div class="who"><b>{who}</b><span class="cap c2 mono">{when}</span></div>
      <div class="dish">{dish}</div>
      <div class="body">
        {photo}
        <div><q>{quote}</q><div class="rate">{rate}</div></div>
      </div>
      {you}
    </article>
'''
    maya_you = f'''<div class="you"><div class="l">{fit(10, 10, 'none')}<span class="cap">You have everything</span></div><button class="btn primary">Cook tonight</button></div>'''
    dev_you = f'''<div class="you"><div class="l">{fit(8, 10)}<span class="cap">Missing beansprouts &middot; 1 swap</span></div><button class="btn ghost">Cook with swap</button></div>'''
    maya = card.format(who="Maya", when="Mon 21:40", dish="Butter bean curry",
                       photo='<div class="photo"><span>1:1</span></div>',
                       quote="Add lemon at the end, trust me.", rate="5 of 5 &middot; swapped spinach for kale", you=maya_you)
    dev = card.format(who="Dev", when="Sun 12:10", dish="Egg-fried noodles with beansprouts",
                      photo="", quote="Doubled the garlic. No regrets.", rate="4 of 5 &middot; 18 min", you=dev_you)
    mine = card.format(who="You", when="Sat 18:55", dish="Ginger chicken udon noodles",
                       photo='<div class="photo"><span>1:1</span></div>',
                       quote="Lemon instead of lime worked.", rate="4 of 5 &middot; 27 min",
                       you='<div class="cap c2" style="margin-top:10px">Your cook &mdash; Maya and Dev see this card.</div>')
    return f'''  <div class="screen"><div class="scroll dn">
    <header class="head in" style="--i:0"><h1>Table</h1><a href="#" class="lnk cap c2">Invite</a></header>
    <p class="cap c2 in" style="--i:0">Flat 4B &middot; 3 people &middot; in time order, no ranking</p>

{maya}{dev}{mine}
    <section class="sect in" style="--i:2">
      <h3>Notes on recipes you've cooked</h3>
      <div class="row"><span class="n">Ginger chicken udon noodles<br><span class="cap c2">&ldquo;Add the ginger late or it burns.&rdquo;</span></span><span class="q">212 cooks</span></div>
      <div class="row"><span class="n">Butter bean curry<br><span class="cap c2">38% add lemon. You and Maya both do.</span></span><span class="q">94 cooks</span></div>
      <div class="row"><span class="n">Chicken jalfrezi<br><span class="cap c2">Be the first to leave a note.</span></span><span class="q c3">under 10</span></div>
    </section>

    <section class="sect in" style="--i:2">
      <h3>Challenge <span class="cap c2">this week</span></h3>
      <div class="row"><span class="n">Three ingredients, what can you make?<br><span class="cap c2">Rice, eggs, frozen peas &middot; works alone &middot; share your result</span></span><button class="btn ghost" style="width:auto;height:36px;padding:0 14px;border-radius:10px;font-size:15px">Join</button></div>
    </section>
  </div></div>
'''

def build_table(write, page, phone):
    n = note("Table", TABLE_NOTE, TABLE_STATES, TABLE_MOTION)
    for theme in ("light", "dark"):
        html = page(f"Table ({theme})", theme, phone(table_body(), theme) + tabbar("table"), n, SOCIAL_CSS)
        write(f"table{'-dark' if theme == 'dark' else ''}.html", html)

def build(write, page, phone):
    build_tp(write, page, phone)
    build_explore(write, page, phone)
    build_table(write, page, phone)
