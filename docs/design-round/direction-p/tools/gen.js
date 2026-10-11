/* Direction P generator: builds every mock into docs/design-round/direction-p/. */
'use strict';
const fs = require('fs');
const path = require('path');
const { page, chrome } = require('./shell');
const { tonight } = require('./screens-tonight');
const { kitchen, scanReview } = require('./screens-kitchen');
const { recipe } = require('./screens-recipe');
const { cookLechef, cookComplete } = require('./screens-cook');
const { tasteProfile, explore } = require('./screens-b1');
const { table, candidatesQuests, candidatesTour } = require('./screens-b2');
const { shellSKitchen, shellSProgress, shellSProfile } = require('./screens-shells');

const OUT = path.join(__dirname, '..', 'docs', 'design-round', 'direction-p');
fs.mkdirSync(OUT, { recursive: true });

function emit(name, b, opts = {}) {
  const mode = opts.mode || 'light';
  const html = page({ mode, xxl: opts.xxl, title: name, body: b, note: b.note + (opts.extraNote || '') });
  fs.writeFileSync(path.join(OUT, name + '.html'), html);
  console.log('wrote', name + '.html', `${(html.length / 1024).toFixed(1)}k`);
}

const pairs = [
  ['tonight', tonight], ['kitchen', kitchen], ['scan-review', scanReview],
  ['recipe', recipe], ['taste-profile', tasteProfile], ['explore', explore], ['table', table],
];
for (const [name, build] of pairs) {
  emit(name, build(), { mode: 'light' });
  emit(name + '-dark', build(), { mode: 'dark' });
}

/* cook-lechef: cook palette; frame 1 = mid-cook, frame 2 = completion (same file, brief item 5) */
{
  const a = cookLechef();
  const b = cookComplete();
  emit('cook-lechef', {
    multi: true,
    html: chrome(a.html) + chrome(b.html),
    css: a.css + b.css,
    note: a.note + '<hr style="border:0;border-top:1px solid #D8CFC0;margin:14px 0">' + b.note.replace(/^<h1>.*<\/h1>/, ''),
  }, { mode: 'cook' });
}

/* tonight at accessibility XXL, light only (brief item 9) */
{
  const t = tonight();
  emit('tonight-xxl', t, {
    mode: 'light', xxl: true,
    extraNote: '<h2>XXL — 393 pt treated as 482 pt</h2><p>Dynamic Type at the accessibility size (about 1.35×): every primary label reflows, nothing truncates. The hero keeps its one-job hierarchy by dropping the plate to a 150 px band and letting the why line wrap — hierarchy survives because it was built from type and weight, not from fixed heights. Rows stay 44 pt minimum; the fit meter and mono counts scale with the scale.</p>',
  });
}

/* Shell S structure candidates in this visual system */
emit('shell-s-kitchen', shellSKitchen(), { mode: 'light' });
emit('shell-s-kitchen-dark', shellSKitchen(), { mode: 'dark' });
emit('shell-s-progress', shellSProgress(), { mode: 'light' });
emit('shell-s-progress-dark', shellSProgress(), { mode: 'dark' });
emit('shell-s-profile', shellSProfile(), { mode: 'light' });
emit('shell-s-profile-dark', shellSProfile(), { mode: 'dark' });

/* candidates */
emit('candidates-quests', candidatesQuests(), { mode: 'light' });
emit('candidates-quests-dark', candidatesQuests(), { mode: 'dark' });
emit('candidates-tour', candidatesTour(), { mode: 'light' });
emit('candidates-tour-dark', candidatesTour(), { mode: 'dark' });

const files = fs.readdirSync(OUT).filter((f) => f.endsWith('.html')).sort();
console.log('\n' + files.length + ' html files:');
for (const f of files) console.log(' ', f);
