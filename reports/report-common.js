/* report-common.js: shared by the operations and resilience reports (inlined at build time) */
const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();
const fmt = ms => ms >= 1000 ? (ms / 1000).toFixed(1) + ' s' : Math.round(ms) + ' ms';
const slot = i => `--series-${i + 1}`;
const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const t = v => v ? esc(String(v).slice(5, 19)) : '';   // MM-DD HH:MM:SS

const parse = j => { try { return j ? JSON.parse(j) : null; } catch { return null; } };
function rowBox(title, row, compareTo, emptyText = 'Row missing') {
  if (!row) return `<div class="rowbox"><h4>${title}</h4><div class="missing">${emptyText}</div></div>`;
  const cells = Object.entries(row).map(([k, v]) => {
    const diff = compareTo && JSON.stringify(compareTo[k]) !== JSON.stringify(v);
    return `<tr><td>${esc(k)}</td><td class="${diff ? 'changed' : ''}">${esc(v)}</td></tr>`;
  }).join('');
  return `<div class="rowbox"><h4>${title}</h4><table>${cells}</table></div>`;
}
// Plain-English classification of each repair: what kind of problem it was, and what was done
function classify(r) {
  const txt = r.errText || '';
  const val = (txt.match(/duplicate key value is \((.*)\)/) || [])[1];
  const uq = (txt.match(/UNIQUE KEY constraint '([^']+)'/) || txt.match(/unique index '([^']+)'/) || [])[1];
  if (r.errCode === '20598')
    return { type: 'Missing row', cls: 'missing-row',
      say: `The subscriber did not have this row, so a replicated UPDATE could not be applied (error 20598). ReplMon restored the row from the publisher and the agent re-applied the UPDATE.` };
  if ((r.errCode === '2627' || r.errCode === '2601') && uq)
    return r.mode === 'delete'
      ? { type: 'Duplicate key: stray row', cls: 'dup',
          say: `A new row could not be applied because row ${r.key} on the subscriber already held ${uq} value ${val ?? ''} (error ${r.errCode}). Row ${r.key} does not exist on the publisher, so it was a stray: ReplMon removed it and the agent applied the new row.` }
      : { type: 'Duplicate key: stale row', cls: 'dup',
          say: `Row ${r.key} on the subscriber held an out-of-date ${uq} value ${val ?? ''} that blocked a new value (error ${r.errCode}). ReplMon resynced it from the publisher and the agent re-applied the change.` };
  if (r.errCode === '2627' || r.errCode === '2601')
    return { type: 'Duplicate key: primary key', cls: 'dup',
      say: `A replicated INSERT found key ${r.key} already on the subscriber (error ${r.errCode}). ReplMon removed the stale copy so the agent could insert the publisher's version.` };
  return r.mode === 'delete'
    ? { type: 'Silent drift: extra row', cls: 'drift',
        say: `Row ${r.key} existed only on the subscriber and no replication error had reported it. The drift check found it and removed it.` }
    : { type: 'Silent drift: changed row', cls: 'drift',
        say: `Row ${r.key} differed from the publisher with no replication error. The drift check found it and resynced it from the publisher.` };
}
function renderRepairs(repairs, showSummary = true) {
  const kinds = repairs.map(classify);
const counts = kinds.reduce((m, k) => (m[k.type] = (m[k.type] || 0) + 1, m), {});
  return repairs.length
  ? (showSummary ? `<div class="summary">${Object.entries(counts).map(([k, n]) => `<span class="kind">${esc(k)} · ${n}</span>`).join(' ')}</div>` : '') +
    repairs.map((r, idx) => {
  const c = kinds[idx];
  const before = parse(r.before), pub = parse(r.pub), after = parse(r.after);
  const removed = r.mode === 'delete';
  const verdict = removed
    ? (pub ? 'stale copy removed; the agent re-applies the publisher\'s row' : '<span class="ok">&#10003; stray row removed; it never existed on the publisher</span>')
    : (after && pub && JSON.stringify(after) === JSON.stringify(pub)
        ? '<span class="ok">&#10003; subscriber now matches the publisher</span>'
        : '<span class="open">check: after differs from publisher</span>');
  return `<div class="repair">
    <h3><span class="kind ${c.cls}">${esc(c.type)}</span> ${esc(r.table)} row ${esc(r.key)} on ${esc(r.sub)}</h3>
    <div class="say">${esc(c.say)}</div>
    <div class="meta">Repair #${r.id}${r.incident ? ` for incident #${r.incident}` : ''} at ${t(r.at)} UTC · ${verdict}</div>
    ${r.errText ? `<div class="err">${r.errCode ? `<b>Error ${esc(r.errCode)}:</b> ` : ''}${esc(r.errText)}</div>` : ''}
    ${r.command ? `<div class="cmd">${esc(r.command)}</div>` : ''}
    <div class="rows">
      ${rowBox('Subscriber before', before, pub, 'Row missing')}
      ${rowBox(removed ? 'Publisher' : 'Publisher (restored from)', pub, null, 'Not on the publisher')}
      ${rowBox('Subscriber after', after, pub, removed ? 'Row removed' : 'Row missing')}
    </div></div>`;
}).join('') : '<div class="empty">No rows were repaired.</div>';
}


function renderIncidentRows(incidents, emptyText) {
  return incidents.length ? incidents.map(i => `
  <tr><td>${i.id}</td><td><span class="kind">${esc(i.kind)}</span></td><td>${esc(i.sub)}</td>
  <td>${t(i.detected)}</td><td>${esc(i.diagnosis)}</td><td>${esc(i.action ?? '')}</td>
  <td>${i.resolved ? `${t(i.resolved)}<br><span class="empty">open ${Number(i.openSec).toFixed(1)} s</span>`
                   : '<span class="open">still open</span>'}</td></tr>`).join('')
  : `<tr><td colspan="7" class="empty">${esc(emptyText)}</td></tr>`;
}

// Executive-summary hero, in the RCA report style: severity pill, headline, one sentence
function banner(level, title, text) {
  const pill = { good: 'NO ACTION NEEDED', warn: 'AUTO-RESOLVED', bad: 'ACTION NEEDED' }[level] || '';
  return `<div class="verdict ${level}"><span class="kind ${level}">${pill}</span><div class="vt">${esc(title)}</div><div class="vx">${esc(text)}</div></div>`;
}
// Header metadata block
function renderMeta(pairs) {
  return pairs.map(([k, v]) => `<div><b>${esc(k)}</b>${v}</div>`).join('');
}
// Details are open unless the report was built with -Collapsed
function applyExpand() {
  if (DATA.expand === false) return;
  document.querySelectorAll('details').forEach(d => d.open = true);
}
const pct = v => v == null ? '—' : `${(Math.floor(v * 1000) / 10).toFixed(1)}%`;
