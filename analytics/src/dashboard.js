const escape = value => String(value).replace(/[&<>"']/g, character => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[character]);

export function dashboard({ today, active, daily, versions }) {
  const recent = Array.from({ length: 30 }, (_, index) => {
    const day = new Date(Date.parse(`${today}T00:00:00Z`) - (29 - index) * 86_400_000).toISOString().slice(0, 10);
    return { day, installations: daily.find(row => row.day === day)?.installations ?? 0 };
  });
  const max = Math.max(1, ...recent.map(row => row.installations));
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Nanight usage</title>
<style>
:root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #11151b; color: #eef2f6; }
* { box-sizing: border-box; } body { max-width: 920px; margin: 0 auto; padding: 48px 24px; }
header { margin-bottom: 36px; } h1 { font-size: 30px; letter-spacing: -.8px; margin: 10px 0; } h2 { font-size: 18px; margin: 0 0 24px; }
p, small, th { color: #9eacbb; } p { line-height: 1.6; } .brand { color: #9fdbc8; font-size: 12px; letter-spacing: 2px; }
.cards { display: grid; grid-template-columns: repeat(3,1fr); gap: 16px; }
article, section { background: #1b222c; border: 1px solid #2b3643; border-radius: 14px; padding: 24px; }
article strong { display: block; font-size: 42px; margin-top: 10px; font-weight: 600; } section { margin-top: 24px; }
.chart { display: flex; gap: 5px; height: 150px; align-items: flex-end; margin-top: 30px; }
.bar { flex: 1; background: #93cdbb; border-radius: 3px 3px 0 0; min-height: 2px; }
.axis { display: flex; justify-content: space-between; margin-top: 12px; font-size: 12px; color: #9eacbb; }
table { width: 100%; border-collapse: collapse; font-size: 14px; } th, td { padding: 12px 0; border-bottom: 1px solid #2b3643; text-align: left; } th { font-weight: 400; } td:last-child, th:last-child { text-align: right; }
summary { cursor: pointer; } .history { max-height: 320px; overflow: auto; margin-top: 16px; } footer { font-size: 12px; margin-top: 24px; color: #9eacbb; line-height: 1.6; }
@media(max-width:560px) { body { padding: 28px 16px; } .cards { gap: 8px; } article { padding: 16px 10px; } article strong { font-size: 30px; } small { font-size: 11px; } section { padding: 18px; } .chart { gap: 3px; } }
</style></head><body><header><div class="brand">NANIGHT</div><h1>Usage at a glance</h1>
<p>Active installations sharing basic usage statistics. All dates use UTC.</p></header>
<div class="cards">${[['Today', active.daily], ['Last 7 days', active.weekly], ['Last 30 days', active.monthly]]
    .map(([label, value]) => `<article><small>${label}</small><strong>${escape(value)}</strong></article>`).join('')}</div>
<section><h2>Daily active installations</h2><div class="chart" role="img" aria-label="Daily active installations over the last 30 days. Exact counts are in Daily history below.">
${recent.map(row => `<div class="bar" style="height:${row.installations / max * 100}%" title="${row.day}: ${row.installations}"></div>`).join('')}
</div><div class="axis"><span>${recent[0].day}</span><span>${today}</span></div></section>
<section><h2>Versions used in the last 30 days</h2><table><thead><tr><th>Nanight</th><th>macOS</th><th>Installations</th></tr></thead><tbody>
${versions.length ? versions.map(row => `<tr><td>${escape(row.app_version)}</td><td>${escape(row.macos_version)}</td><td>${escape(row.installations)}</td></tr>`).join('') : '<tr><td colspan="3">No usage received yet.</td></tr>'}
</tbody></table><p><small>Uses each installation’s most recent daily ping.</small></p></section>
<section><details><summary>Daily history</summary><div class="history"><table><thead><tr><th>Date (UTC)</th><th>Installations</th></tr></thead><tbody>
${daily.map(row => `<tr><td>${escape(row.day)}</td><td>${escape(row.installations)}</td></tr>`).join('') || '<tr><td colspan="2">No usage received yet.</td></tr>'}
</tbody></table></div></details></section><footer>One check-in per UTC day per installation, with quiet retries after failures. Offline-only use and opt-outs are not counted. Today is still in progress.<br>
Installation records expire after 90 days; historical daily totals contain no installation IDs. Counts represent installations, not people.</footer></body></html>`;
}
