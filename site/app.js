// Token Notch 落地页脚本：首屏的灵动岛是用 HTML 按应用里的尺寸和文案复刻的，
// 数据全部是这里用固定种子生成的演示数据（项目名、用量都是虚构的）。
(() => {
'use strict';
const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];

// ---------------------------------------------------------------- 文案
const ZH = {
  download: '下载', downloadMac: '下载 macOS 版',
  title: '数清每一个 token。',
  lede: '住在 MacBook 刘海里的实时仪表，统计你的编码 agent。',
  'mb.file': '文件', 'mb.edit': '编辑', 'mb.view': '显示', 'mb.window': '窗口',
  's.idle': '待机', 's.idle.d': '和刘海融为一体',
  's.active': 'Agent 运行中', 's.active.d': 'Agent · 实时 tok/s · 今日合计',
  's.expanded': '悬停', 's.expanded.d': '概览 · 单个 agent · 明细',
  note: '可以直接操作：鼠标移到刘海上，切换标签和时间范围。页面上的数字都是演示数据。',
  'cov.label': '统计范围', 'cov.title': '统计什么',
  'm.tokens': 'Token', 'm.cache': '缓存', 'm.cost': '费用', 'm.edits': '编辑行数', 'm.sub': '子代理', 'm.img': '生图',
  'fn.cost': '按价格表估算 · <code>~/.tokens/pricing.json</code>',
  'fn.edits': '每处改动记 <code>max(+, −)</code> 行',
  'fn.range.t': '时间范围', 'fn.range': '今日 · 7 天 · 30 天 · 全部',
  'flow.label': '数据来源', 'flow.title': '数字从哪来',
  'flow.1': 'Agent 日志', 'flow.2': '解析', 'flow.2.d': 'FSEvents <br>只读新追加的部分',
  'flow.3.d': 'SQLite <br><code>~/.tokens</code>', 'flow.4': '刘海',
  'flow.local': '全程不出本机。不用账号，不联网。',
  'ins.label': '安装', 'ins.title': '装上它',
  'ins.1': '解压', 'ins.2': '拖进 <code>/Applications</code>', 'ins.3': '首次启动：右键 →「打开」，或者运行',
  copy: '复制', 'ins.nonotch': '没有刘海？它会在菜单栏下方画一个。',
  'foot.releases': '版本发布', 'foot.issues': '问题反馈',
};
const EN = {};
const TITLE = { en: 'Token Notch — count every token, in the MacBook notch', zh: 'Token Notch：数清每一个 token' };

// 面板里的文案，和应用的 L10n.swift 对应
const APP = {
  zh: {
    overview: '概览', detail: '明细', ranges: { today: '今日', week: '7 天', month: '30 天', all: '全部' },
    rangeTitle: r => ({ today: '今日', week: '近 7 天', month: '近 30 天' }[r]),
    allTitle: (d, n) => `全部（自 ${d} 起 ${n} 天）`,
    rangeMetric: { today: '今日', week: '近 7 天', month: '近 30 天', all: '全部' },
    today: '今日', todayTokens: '今日 token', totalTokens: '合计 token', cacheHit: '缓存命中', output: '输出',
    editLines: '编辑行数', liveTotal: '实时合计', live: '实时', dailyAvg: '日均', subagents: '子代理占比',
    imageCalls: '生图调用', imgDetail: (c, n) => '次' + (n !== c ? ` · ${n} 张` : ''),
    imageLabel: '生图', imageSummary: (c, n) => `${c} 次调用 · ${n} 张`,
    cacheRead: '缓存读', cacheWrite: '缓存写', freshInput: '新输入', formula: '缓存读 ÷ 全部输入', hit: '命中 ',
    daily: '每日 · 按 agent 叠加', peak: '峰值', byModel: '按模型 · ',
    cols: ['模型', 'Agent', '平均 tok/s', 'Token', '占比'], total: '合计', agentCount: n => `${n} 个 agent`,
    otherModels: n => `其他 ${n} 个模型`, otherProjects: n => `其他 ${n} 个项目`, projects: n => `项目耗费 · ${n} 个项目`,
    weekdays: ['日', '一', '二', '三', '四', '五', '六'], todayShort: '今', todayLabel: '今天',
    date: d => `${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`,
    clock: d => `周${'日一二三四五六'[d.getDay()]} ${d.getHours()}:${String(d.getMinutes()).padStart(2, '0')}`,
  },
  en: {
    overview: 'Overview', detail: 'Details', ranges: { today: 'Today', week: '7D', month: '30D', all: 'All' },
    rangeTitle: r => ({ today: 'Today', week: 'Last 7 days', month: 'Last 30 days' }[r]),
    allTitle: (d, n) => `All time (since ${d}, ${n} days)`,
    rangeMetric: { today: 'Today', week: 'Last 7D', month: 'Last 30D', all: 'All time' },
    today: 'Today', todayTokens: 'Tokens today', totalTokens: 'Total tokens', cacheHit: 'Cache hit', output: 'Output',
    editLines: 'Lines edited', liveTotal: 'Live total', live: 'Live', dailyAvg: 'Daily avg', subagents: 'Subagents',
    imageCalls: 'Image calls', imgDetail: (c, n) => (n !== c ? `· ${n} img` : ''),
    imageLabel: 'Image generation', imageSummary: (c, n) => `${c} calls · ${n} images`,
    cacheRead: 'Cache read', cacheWrite: 'Cache write', freshInput: 'Fresh input', formula: 'cache read ÷ all input', hit: 'hit ',
    daily: 'Daily · stacked by agent', peak: 'Peak', byModel: 'By model · ',
    cols: ['Model', 'Agent', 'Avg tok/s', 'Token', 'Share'], total: 'Total', agentCount: n => `${n} agents`,
    otherModels: n => `${n} other models`, otherProjects: n => `${n} other project${n === 1 ? '' : 's'}`, projects: n => `Cost by project · ${n}`,
    weekdays: ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'], todayShort: 'Today', todayLabel: 'Today',
    date: d => d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' }),
    clock: d => `${['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'][d.getDay()]} ${d.getHours()}:${String(d.getMinutes()).padStart(2, '0')}`,
  },
};

let lang = 'en';
try { lang = localStorage.getItem('lang') || ((navigator.language || '').toLowerCase().startsWith('zh') ? 'zh' : 'en'); } catch { /* 隐私模式 */ }
const T = () => APP[lang];

// ---------------------------------------------------------------- 演示数据
const AGENTS = [
  { id: 'claude', name: 'Claude Code', short: 'Claude', color: '#D97757', perDay: 60, ctx: 90e3, since: 30, hit: .986, out: .0085, sub: .31, lines: 48,
    models: [['Opus 5.5', 5, .92, 113], ['Sonnet 5.5', 3, .46, 143], ['Haiku 5.5', 1, .14, 196]] },
  { id: 'codex', name: 'Codex', short: 'Codex', color: '#E5E5EA', perDay: 28, ctx: 70e3, since: 30, hit: .934, out: .007, sub: 0, lines: 36,
    models: [['GPT-6.2 Sol', 3, .58, 71], ['GPT-6.2 Astra', 2, .27, 104]] },
  { id: 'antigravity', name: 'Antigravity', short: 'Antigravity', color: '#A78BFA', perDay: 12, ctx: 80e3, since: 19, hit: .902, out: .009, sub: .12, lines: 64,
    models: [['Gemini 4 Carbon High', 3, .5, 53], ['Gemini 3.8 Flash High', 2, .09, 168]] },
  { id: 'grok', name: 'Grok', short: 'Grok', color: '#8E8E93', perDay: 3, ctx: 40e3, since: 11, hit: .83, out: .01, sub: 0, lines: 0,
    models: [['Grok 4.7', 1, .4, 88]] },
  { id: 'deepseek', name: 'DeepSeek Harness', short: 'DeepSeek', color: '#5B79FF', perDay: 30, ctx: 60e3, since: 30, hit: .992, out: .006, sub: .44, lines: 52,
    models: [['DeepSeek V4.1 Flash', 4, .02, 107], ['DeepSeek V4 Pro', 1, .08, 64]] },
];
const AGENT = Object.fromEntries(AGENTS.map(a => [a.id, a]));
const PROJECTS = ['atlas-web', 'token-notch', 'ml-pipeline', 'api-gateway', 'ios-client', 'docs-site', 'infra', 'design-tokens', 'billing-svc', 'cli-tools', 'landing'];
const LIVE = { claude: 128, codex: 46 };
const DAYS = 30;

const days = (() => {
  let s = 0x5eed70ce;
  const rnd = () => (s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 4294967296;
  const between = (a, b) => a + (b - a) * rnd();
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const out = [];
  for (let d = 0; d < DAYS; d++) {
    const date = new Date(today); date.setDate(today.getDate() - d);
    const weekend = date.getDay() === 0 || date.getDay() === 6;
    const busy = (weekend ? .45 : 1) * between(.55, 1.35) * (1 + (DAYS - d) / DAYS) * (d === 0 ? .62 : 1);
    const day = { date, agents: {}, models: {}, projects: {} };
    AGENTS.forEach((a, ai) => {
      if (d >= a.since) return;
      const total = Math.round(a.perDay * busy * a.ctx * 1.3 * between(.8, 1.2));
      day.agents[a.id] = total;
      const w = a.models.map(m => m[1] * between(.6, 1.4)), ws = w.reduce((x, y) => x + y, 0);
      a.models.forEach((m, i) => { day.models[a.id + '|' + m[0]] = total * w[i] / ws; });
      const pw = PROJECTS.map((_, p) => (1 / (p + 1)) * (1 + .8 * Math.sin(p * 1.7 + ai * 2.1)) * between(.5, 1.5));
      const ps = pw.reduce((x, y) => x + y, 0);
      PROJECTS.forEach((p, i) => { ((day.projects[p] ||= {})[a.id] = total * pw[i] / ps); });
    });
    out.push(day);
  }
  return out;
})();

const statsCache = {};
function stats(range) {
  if (statsCache[range]) return statsCache[range];
  const n = { today: 1, week: 7, month: 30, all: DAYS }[range];
  const slice = days.slice(0, n);
  const agents = AGENTS.map(a => {
    const total = slice.reduce((s, d) => s + (d.agents[a.id] || 0), 0);
    const output = total * a.out, input = total - output, cacheRead = input * a.hit;
    const cacheWrite = a.id === 'claude' ? (input - cacheRead) * .45 : 0;
    const models = a.models.map(m => {
      const t = slice.reduce((s, d) => s + (d.models[a.id + '|' + m[0]] || 0), 0);
      return { name: m[0], agent: a, total: t, cost: t / 1e6 * m[2], speed: m[3] };
    }).filter(m => m.total > 0).sort((x, y) => y.total - x.total);
    const calls = a.id === 'claude' ? Math.round(n * .55 + 1) : a.id === 'codex' ? Math.round(n * .38) : 0;
    return { a, total, output, cacheRead, cacheWrite, fresh: input - cacheRead - cacheWrite, hit: a.hit,
      lines: Math.round(total / 1e6 * a.lines), models, cost: models.reduce((s, m) => s + m.cost, 0),
      imageCalls: calls, images: Math.round(calls * 1.2) };
  }).filter(x => x.total > 0).sort((x, y) => y.total - x.total);
  const sum = k => agents.reduce((s, x) => s + x[k], 0);
  const total = sum('total');
  const projects = PROJECTS.map(name => {
    const per = {}; let t = 0, cost = 0;
    agents.forEach(x => {
      const v = slice.reduce((s, d) => s + ((d.projects[name] || {})[x.a.id] || 0), 0);
      per[x.a.id] = v; t += v; cost += v * x.cost / x.total;
    });
    return { name, per, total: t, cost };
  }).filter(p => p.total > 0).sort((x, y) => y.total - x.total);
  const cacheRead = sum('cacheRead'), cacheWrite = sum('cacheWrite'), fresh = sum('fresh');
  const first = days[DAYS - 1].date;
  return (statsCache[range] = {
    range, n, slice, agents, total, output: sum('output'), cacheRead, cacheWrite, fresh,
    hit: cacheRead / (cacheRead + cacheWrite + fresh), lines: sum('lines'), cost: sum('cost'),
    models: agents.flatMap(x => x.models).sort((x, y) => y.total - x.total), projects,
    imageCalls: sum('imageCalls'), images: sum('images'), first,
  });
}

// ---------------------------------------------------------------- 格式化（同 TokenFormat）
const fmt = {
  compact(n) {
    const [x, u] = n >= 1e9 ? [n / 1e9, 'B'] : n >= 1e6 ? [n / 1e6, 'M'] : n >= 1e3 ? [n / 1e3, 'K'] : [n, ''];
    return u ? (x >= 100 ? x.toFixed(0) : x >= 10 ? x.toFixed(1) : x.toFixed(2)) + u : String(Math.round(n));
  },
  lines: n => (n < 1e4 ? Math.round(n).toLocaleString('en-US') : fmt.compact(n)),
  pct: r => (r > 0 && r < .001 ? '<0.1%' : (r * 100).toFixed(1) + '%'),
  cost: v => (v < 1 ? '$' + v.toFixed(2) : '$' + Math.round(v).toLocaleString('en-US')),
};
const rangeTitle = s => (s.range === 'all' ? T().allTitle(T().date(s.first), s.n) : T().rangeTitle(s.range));

// ---------------------------------------------------------------- 面板
const view = { state: 'idle', tab: 'overview', range: 'week', rotation: 0 };
const live = { ...LIVE };
const liveSum = () => Object.values(live).reduce((x, y) => x + y, 0);
const island = $('#island'), panel = $('#panel'), wings = $('#wings');

function metric(label, value, color, key) {
  return `<div class="p-metric"><span>${label}</span><b${color ? ` style="color:${color}"` : ''}${key ? ` data-live="${key}"` : ''}>${value}</b></div>`;
}

function bars(s, agentId, height) {
  const list = [...s.slice].reverse();
  const vals = list.map(d => (agentId ? d.agents[agentId] || 0 : Object.values(d.agents).reduce((x, y) => x + y, 0)));
  const max = Math.max(1, ...vals), dense = list.length > 14;
  const cols = list.map((d, i) => {
    const delay = `animation-delay:${(i * (dense ? 12 : 40))}ms`;
    if (agentId) {
      const h = vals[i] ? Math.max(2, height * vals[i] / max) : 1;
      const c = i === list.length - 1 ? AGENT[agentId].color : '';
      return `<div><i style="height:${h}px;${c ? `background:${c};` : ''}${delay}"></i></div>`;
    }
    return '<div>' + [...AGENTS].reverse().map(a => {
      const v = d.agents[a.id] || 0;
      return v ? `<i style="height:${Math.max(1, height * v / max)}px;background:${a.color};${delay}"></i>` : '';
    }).join('') + '</div>';
  }).join('');
  const t = T();
  const labels = dense
    ? `<div class="p-labels ends"><span>${t.date(list[0].date)}</span><span>${t.date(list[list.length >> 1].date)}</span><span>${t.todayLabel}</span></div>`
    : `<div class="p-labels" style="gap:8px">${list.map((d, i) => `<span>${i === list.length - 1 ? t.todayShort : t.weekdays[d.date.getDay()]}</span>`).join('')}</div>`;
  return `<div class="p-bars${agentId ? ' solo' : ''}${dense ? ' dense' : ''}" style="height:${height}px;gap:${dense ? 2 : 8}px">${cols}</div>${labels}`;
}

// 单日范围：一个模型一根柱子
function modelBars(x, a, height) {
  const ms = x.models.slice(0, 5), max = Math.max(1, ...ms.map(m => m.total));
  return `<div class="p-mbars" style="height:${height}px">${ms.map((m, i) =>
    `<div><span>${fmt.compact(m.total)}</span><i style="height:${Math.max(2, (height - 18) * m.total / max)}px;background:${i ? '#3a3a3c' : a.color}"></i></div>`).join('')}</div>
    <div class="p-labels p-mlabels" style="gap:8px">${ms.map((m, i) => `<span${i ? '' : ' class="first"'}>${m.name}</span>`).join('')}</div>`;
}

function pageOverview(s) {
  const t = T(), liveTotal = liveSum();
  const peak = s.slice.reduce((best, d) => {
    const v = Object.values(d.agents).reduce((x, y) => x + y, 0);
    return v > best.v ? { v, d } : best;
  }, { v: 0, d: s.slice[0] });
  const top = s.models.slice(0, 7), rest = s.models.slice(7);
  const restTotal = rest.reduce((x, m) => x + m.total, 0);
  const row = m => `<tr><td><i style="background:${m.agent.color}"></i>${m.name}</td><td class="t2">${m.agent.short}</td><td class="t2">${m.speed}</td><td>${fmt.compact(m.total)}</td><td class="t2">${fmt.pct(m.total / s.total)}</td></tr>`;
  return `<div class="p-page">
    <div class="p-title">${t.totalTokens} · ${rangeTitle(s)}</div>
    <div class="p-hero"><div class="p-big">${fmt.compact(s.total)}</div><div class="p-metrics">
      ${s.range !== 'today' ? metric(t.today, fmt.compact(stats('today').total)) : ''}
      ${metric(t.cacheHit, fmt.pct(s.hit))}${metric(t.output, fmt.compact(s.output))}${metric(t.editLines, fmt.lines(s.lines))}
      ${metric(t.liveTotal, liveTotal + ' tok/s', '#FF9F0A', 'total')}</div></div>
    <div class="p-sec"><div class="p-seg">${s.agents.map(x => `<i style="flex:${x.total} 0 0;background:${x.a.color}"></i>`).join('')}</div>
      <div class="p-legend">${s.agents.map(x => `<span><i style="background:${x.a.color}"></i>${x.a.short}<span class="t2">${fmt.pct(x.total / s.total)}</span></span>`).join('')}</div></div>
    ${s.n > 1 ? `<div class="p-sec"><div class="p-cap"><span>${t.daily}</span><span>${t.peak} ${t.date(peak.d.date)} · ${fmt.compact(peak.v)}</span></div>${bars(s, null, 56)}</div>` : ''}
    <div class="p-sec"><table class="p-table"><thead><tr>${t.cols.map(c => `<th>${c}</th>`).join('')}</tr></thead>
      <tbody>${top.map(row).join('')}${rest.length ? `<tr><td class="t2"><i style="background:#48484a"></i>${t.otherModels(rest.length)}</td><td class="t3">—</td><td class="t3">—</td><td>${fmt.compact(restTotal)}</td><td class="t2">${fmt.pct(restTotal / s.total)}</td></tr>` : ''}</tbody>
      <tfoot><tr><td>${t.total}</td><td>${t.agentCount(s.agents.length)}</td><td>≈ ${fmt.cost(s.cost)}</td><td>${fmt.compact(s.total)}</td><td>100%</td></tr></tfoot></table></div>
  </div>`;
}

function pageAgent(s, id) {
  const t = T(), a = AGENT[id];
  const x = s.agents.find(v => v.a.id === id) || { total: 0, output: 0, hit: a.hit, lines: 0, models: [], imageCalls: 0, images: 0 };
  const today = stats('today').agents.find(v => v.a.id === id);
  const speed = live[id] ? live[id] + ' tok/s' : '—';
  const cell = (label, value, small) => `<div class="p-cell"><span>${label}</span><b>${value}</b>${small ? `<small>${small}</small>` : ''}</div>`;
  const hasImages = (stats('all').agents.find(v => v.a.id === id) || {}).imageCalls > 0;
  return `<div class="p-page">
    <div class="p-hero"><div><div class="p-title">${t.todayTokens}</div><div class="p-big">${fmt.compact(today ? today.total : 0)}</div></div>
      <div class="p-metrics" style="gap:28px">${s.range !== 'today' ? metric(t.rangeMetric[s.range], fmt.compact(x.total)) + metric(t.dailyAvg, fmt.compact(x.total / s.n)) : ''}
      ${metric(t.live, speed, a.color, live[id] ? id : '')}</div></div>
    <div class="p-cells">${cell(t.cacheHit, fmt.pct(x.hit))}${cell(t.output, fmt.compact(x.output))}${cell(t.editLines, fmt.lines(x.lines))}${cell(t.subagents, fmt.pct(a.sub))}
      ${hasImages ? cell(t.imageCalls, x.imageCalls, t.imgDetail(x.imageCalls, x.images)) : ''}</div>
    <div class="p-cols"><div><div class="p-cap"><span>${rangeTitle(s)}</span></div><div style="margin-top:26px">${s.n > 1 ? bars(s, id, 100) : modelBars(x, a, 100)}</div></div>
      <div class="p-stack"><div class="p-cap" style="margin:0"><span>${t.byModel}${rangeTitle(s)}</span></div>
      ${x.models.map((m, i) => `<div><div class="p-row"><span>${m.name}</span><span class="t2">${fmt.compact(m.total)} · ${fmt.pct(m.total / x.total)}</span></div>
        <div class="p-track"><i style="width:${m.total / x.total * 100}%;background:${i ? '#8e8e93' : a.color}"></i></div></div>`).join('')}</div></div>
  </div>`;
}

function pageDetail(s) {
  const t = T();
  const parts = [[t.cacheRead, s.cacheRead, '#FF9F0A'], [t.cacheWrite, s.cacheWrite, '#E5E5E5'], [t.freshInput, s.fresh, '#8E8E93'], [t.output, s.output, '#636366']];
  const limit = Math.min(8, Math.max(4, s.agents.length + 3));
  const top = s.projects.slice(0, limit), rest = s.projects.slice(limit), max = top[0].total;
  const imgModels = [['gpt-image-2.5-sunburst', Math.round(s.imageCalls * .7)], ['gpt-image-2', s.imageCalls - Math.round(s.imageCalls * .7)]].filter(m => m[1] > 0);
  return `<div class="p-page">
    <div class="p-detail"><div class="p-left">
      <div class="p-cap" style="margin:0"><span>${t.cacheHit}</span></div>
      <div class="p-hit"><b>${fmt.pct(s.hit)}</b><span>${t.formula}</span></div>
      <div class="p-seg">${parts.map(p => `<i style="flex:${p[1]} 0 0;background:${p[2]}"></i>`).join('')}</div>
      <div class="p-parts">${parts.map(p => `<div><i style="background:${p[2]}"></i><span>${p[0]}</span><span>${fmt.compact(p[1])}</span><span>${fmt.pct(p[1] / s.total)}</span></div>`).join('')}</div>
      <div class="p-hr"></div>
      ${s.agents.map(x => `<div><div class="p-row"><span>${x.a.name}</span><span class="t2">${t.hit}${fmt.pct(x.hit)}</span></div><div class="p-track"><i style="width:${x.hit * 100}%;background:${x.a.color}"></i></div></div>`).join('')}
    </div><div class="p-right">
      <div class="p-cap">${t.projects(s.projects.length)}<div class="p-plegend">${s.agents.map(x => `<span><i style="background:${x.a.color}"></i>${x.a.short}</span>`).join('')}</div></div>
      ${top.map(p => `<div class="p-proj"><div class="p-row"><span>${p.name}</span><b>${fmt.compact(p.total)}</b><span>≈ ${fmt.cost(p.cost)}</span></div>
        <div class="p-pbar"><div style="width:${Math.max(1, p.total / max * 100)}%">${AGENTS.map(a => (p.per[a.id] ? `<i style="flex:${p.per[a.id]} 0 0;background:${a.color}"></i>` : '')).join('')}</div></div></div>`).join('')}
      ${rest.length ? `<div class="p-proj"><div class="p-row"><span class="t2" style="color:#a1a1a6">${t.otherProjects(rest.length)}</span><b>${fmt.compact(rest.reduce((x, p) => x + p.total, 0))}</b><span>≈ ${fmt.cost(rest.reduce((x, p) => x + p.cost, 0))}</span></div></div>` : ''}
      <div class="p-proj p-ptotal"><div class="p-row"><span>${t.total}</span><b style="font-weight:600">${fmt.compact(s.total)}</b><span>≈ ${fmt.cost(s.cost)}</span></div></div>
    </div></div>
    ${s.imageCalls ? `<div class="p-strip"><span>${t.imageLabel}</span><span>${t.imageSummary(s.imageCalls, s.images)}</span><span>${imgModels.map(m => `<span>${m[0]}</span>${m[1]}`).join('')}</span></div>` : ''}
  </div>`;
}

function renderPanel() {
  const t = T(), s = stats(view.range);
  const tabs = [['overview', t.overview], ...AGENTS.map(a => [a.id, a.short, live[a.id] ? a.color : '']), ['detail', t.detail]];
  const body = view.tab === 'overview' ? pageOverview(s) : view.tab === 'detail' ? pageDetail(s) : pageAgent(s, view.tab);
  panel.innerHTML = `<div class="p-head"><div class="p-tabs">${tabs.map(([id, label, dot]) =>
    `<button type="button" class="p-tab${view.tab === id ? ' on' : ''}" data-tab="${id}">${dot ? `<i style="background:${dot}"></i>` : ''}${label}</button>`).join('')}</div>
    <div class="p-range">${Object.entries(t.ranges).map(([id, label]) => `<button type="button" class="${view.range === id ? 'on' : ''}" data-range="${id}">${label}</button>`).join('')}</div></div>${body}`;
  fit();
}

function renderWings() {
  const ids = Object.keys(LIVE), id = ids[view.rotation % ids.length], a = AGENT[id];
  const today = stats('today').agents.find(v => v.a.id === id);
  wings.innerHTML = `<div class="wing l"><i class="pulse" style="--c:${a.color}"></i>${a.short}</div>
    <div class="wing r"><span class="spd" style="color:${a.color}" data-live="${id}">${live[id]} tok/s</span><b>${fmt.compact(today.total)}</b>
    <span class="pager">${ids.map((_, i) => `<i class="${i === view.rotation % ids.length ? 'on' : ''}"></i>`).join('')}</span></div>`;
}

function rotateWings() {
  $$('.wing', wings).forEach(w => w.classList.add('fade'));
  setTimeout(() => { view.rotation++; renderWings(); }, 420);
}

// 弹簧曲线，和应用里 .spring(response:dampingFraction:) 同一个模型；不支持 linear() 的浏览器用样式表里的贝塞尔
const canLinear = window.CSS && CSS.supports('transition-timing-function', 'linear(0, 1)');
function spring(response, damping, dur) {
  const w = 2 * Math.PI / response, wd = w * Math.sqrt(1 - damping * damping), pts = [];
  for (let i = 0; i <= 40; i++) {
    const x = dur * i / 40;
    pts.push((1 - Math.exp(-damping * w * x) * (Math.cos(wd * x) + damping * w / wd * Math.sin(wd * x))).toFixed(4));
  }
  pts[40] = 1;
  return `linear(${pts.join(',')})`;
}
const EASE = { open: [spring(.46, .84, .9), .9], close: [spring(.3, .96, .6), .6], wings: [spring(.4, .88, .7), .7] };

function fit() {
  island.style.height = view.state === 'expanded' ? panel.offsetHeight + 'px' : '';
}

function setState(next) {
  if (next === view.state) return;
  const kind = next === 'expanded' ? 'open' : view.state === 'expanded' ? 'close' : 'wings';
  if (canLinear) {
    const [fn, dur] = EASE[kind];
    island.style.transition = `width ${dur}s ${fn}, height ${dur}s ${fn}, border-radius ${dur}s ${fn}`;
    $$('.flare', island).forEach(f => { f.style.transition = `width ${dur}s ${fn}, height ${dur}s ${fn}`; });
  }
  view.state = next;
  island.dataset.state = next;
  if (next === 'expanded') renderPanel(); else fit();
  $$('.states button').forEach(b => b.classList.toggle('on', b.dataset.state === next));
}

// ---------------------------------------------------------------- 交互与自动播放
let auto = true, timer = 0, step = 0, resume = 0, heroVisible = true;
const SCRIPT = [
  [() => { view.tab = 'overview'; view.range = 'week'; setState('idle'); }, 900],
  [() => setState('active'), 1600],
  [rotateWings, 1700],
  [() => setState('expanded'), 2600],
  [() => { view.tab = 'claude'; renderPanel(); }, 2200],
  [() => { view.tab = 'detail'; view.range = 'month'; renderPanel(); }, 2600],
  [() => { view.tab = 'overview'; view.range = 'all'; renderPanel(); }, 2200],
  [() => setState('active'), 1500],
];
function play() {
  clearTimeout(timer);
  if (!auto || !heroVisible) return;
  const [fn, wait] = SCRIPT[step % SCRIPT.length];
  fn(); step++;
  timer = setTimeout(play, wait);
}
function pause(ms = 9000) {
  auto = false; clearTimeout(timer); clearTimeout(resume);
  resume = setTimeout(() => { auto = true; step = 1; play(); }, ms);
}

const hoverable = matchMedia('(hover: hover)').matches;
if (hoverable) {
  island.addEventListener('pointerenter', () => { pause(); setState('expanded'); });
  island.addEventListener('pointerleave', () => { pause(4000); setState('active'); });
} else {
  island.addEventListener('click', e => {
    if (e.target.closest('button')) return;
    pause(); setState(view.state === 'expanded' ? 'active' : 'expanded');
  });
}
panel.addEventListener('click', e => {
  const b = e.target.closest('button'); if (!b) return;
  pause();
  if (b.dataset.tab) view.tab = b.dataset.tab;
  if (b.dataset.range) view.range = b.dataset.range;
  renderPanel();
});
$$('.states button').forEach(b => b.addEventListener('click', () => { pause(); setState(b.dataset.state); }));

// 实时数字：每秒轻微抖动
setInterval(() => {
  if (document.hidden) return;
  for (const id in LIVE) live[id] = Math.round(LIVE[id] * (.9 + Math.random() * .22));
  for (const id in LIVE) $$(`[data-live="${id}"]`).forEach(el => { el.textContent = live[id] + ' tok/s'; });
  const total = liveSum();
  $$('[data-live="total"]').forEach(el => { el.textContent = total + ' tok/s'; });
}, 1000);
setInterval(() => { if (view.state === 'active' && !auto) rotateWings(); }, 4000);

// 屏幕按容器宽度缩放
const screen = $('#screen'), wrap = $('#screenWrap');
function scale() {
  const k = wrap.clientWidth / screen.offsetWidth;
  screen.style.transform = `scale(${k})`;
  wrap.style.height = screen.offsetHeight * k + 'px';
}
new ResizeObserver(scale).observe(wrap);

// 桌面底部两角的 agent 窗口（内容是虚构的），和演示视频里的一致；它们只是背景，所以小、淡、滚得慢。
// 类名：u 提示、d 次要、e 编辑、g 通过、p 普通
const TERMS = [
  { id: 'claude', title: 'atlas-web — claude', keep: 4, lines: [
    ['u', '› add retry to the uploader'], ['d', '  Read   src/upload/client.ts'], ['e', '  Edit   src/upload/client.ts  +18 −4'],
    ['d', '  Bash   npm test -- upload'], ['g', '  ✓ 42 passed (3.1s)'],
    ['u', '› now cover the timeout path'], ['e', '  Edit   src/upload/retry.test.ts  +27'], ['g', '  ✓ 45 passed (3.4s)']] },
  { id: 'codex', title: 'api-gateway — codex', keep: 4, lines: [
    ['u', '› rate-limit the /export endpoint'], ['d', '• Ran rg "export" src/routes'], ['p', '• Edited src/routes/export.ts (+24 −3)'],
    ['d', '• Ran pnpm test export'], ['g', '  18 passed'],
    ['u', '› document the 429 response'], ['p', '• Edited openapi.yaml (+12)']] },
];
const desk = $('#desk');
TERMS.forEach((w, i) => {
  const el = document.createElement('div');
  el.className = 'term t-' + w.id;
  el.style.setProperty('--c', AGENT[w.id].color);
  el.innerHTML = `<div class="term-bar"><i></i><i></i><i></i><span>${w.title}</span><b></b></div><div class="term-body"></div>`;
  desk.append(el);
  const body = $('.term-body', el);
  let at = i * 2;
  const push = () => {
    const [cls, text] = w.lines[at++ % w.lines.length];
    const line = document.createElement('div'); line.className = cls; line.textContent = text;
    body.append(line);
    while (body.children.length > w.keep) body.firstChild.remove();
  };
  for (let k = 0; k < w.keep; k++) push();
  // 几个窗口错开滚动
  setTimeout(() => setInterval(() => { if (!document.hidden && heroVisible) push(); }, 1700), i * 850);
});

// ---------------------------------------------------------------- 语言
$$('[data-i18n]').forEach(el => { EN[el.dataset.i18n] = el.innerHTML; });
function applyLang() {
  const dict = lang === 'zh' ? ZH : EN;
  document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
  document.title = TITLE[lang];
  $$('[data-i18n]').forEach(el => { el.innerHTML = dict[el.dataset.i18n] ?? EN[el.dataset.i18n]; });
  $('#lang').textContent = lang === 'zh' ? 'EN' : '中文';
  $('#clock').textContent = T().clock(new Date());
  renderWings();
  renderPanel();
}
$('#lang').addEventListener('click', () => {
  lang = lang === 'zh' ? 'en' : 'zh';
  try { localStorage.setItem('lang', lang); } catch { /* 忽略 */ }
  applyLang();
});

// ---------------------------------------------------------------- 其余
$$('.matrix td.y').forEach((td, i) => td.style.setProperty('--i', i));
const io = new IntersectionObserver(entries => entries.forEach(e => {
  if (e.target.id === 'mac') { heroVisible = e.isIntersecting; if (heroVisible && auto) play(); return; }
  if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
}), { threshold: .12 });
$$('.block').forEach(el => { el.classList.add('reveal'); io.observe(el); });
io.observe($('#mac'));

$('#copy').addEventListener('click', async e => {
  try { await navigator.clipboard.writeText($('#cmd').textContent); } catch { return; }
  const b = e.currentTarget, old = b.textContent;
  b.textContent = '✓'; setTimeout(() => { b.textContent = old; }, 1400);
});

// 版本号取最新 release；取不到就保留写死的那个
fetch('https://api.github.com/repos/winbeau/token-notch/releases/latest')
  .then(r => (r.ok ? r.json() : null)).then(j => { if (j && j.tag_name) $('#version').textContent = j.tag_name; }).catch(() => {});

applyLang();
scale();
document.fonts?.ready.then(() => { scale(); fit(); });
})();
