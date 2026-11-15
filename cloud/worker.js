// патужно · спільний хмарний сервер (Cloudflare Worker) для багатьох користувачів.
// Кожен користувач входить у Wonderfree у програмі на своєму Mac; програма передає серверу лише ключ сесії
// і отримує власний секретний ключ доступу. Сервер щохвилини читає станції, пише історію, тягне графіки Yasno,
// стежить за відключеннями й батареєю, шле сповіщення в Telegram (один бот на всіх) і показує панель на телефоні.
import PANEL from "./panel.html";
import LOGO from "./logo.png";

const BASE = "https://iot-api.acceleronix.io";
const HDR = { appVersion: "3.6.5", appSystemType: "android", appId: "277", "X-Q-Language": "en" };
const KEEP_DAYS = 35, TZ = "Europe/Kyiv", MAX_USERS = 10;
let BOT_NAME = "";   // ім'я бота без @ — зі змінної BOT_NAME сервера (deploy.sh)
const DEF_CFG = { group: "", region_id: 25, dso_id: 902, capacity_wh: 2048, inverter_efficiency: 0.9, reserve_percent: 0,
  charge_efficiency: 0.92, max_ac_charge_w: 1800, night: [23, 8], weekend_days: [5, 6], fallback_watts: { work: 150, night: 60, weekend: 120 }, model: "" };

// ---------- сховище ----------
const SCHEMA = [
  "CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT)",
  "CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, key TEXT UNIQUE, dk TEXT, data TEXT, created INTEGER)",
  "CREATE TABLE IF NOT EXISTS samples2 (uid TEXT, ts INTEGER, soc REAL, out REAL, inw REAL, temp REAL, PRIMARY KEY (uid, ts))",
  // погодинні підсумки для статистики: щогодинний перерахунок читає ~340 рядків, а не всі виміри за 14 днів
  "CREATE TABLE IF NOT EXISTS hourly (uid TEXT, h INTEGER, n INTEGER, sum_out REAL, max_out REAL, ch_n INTEGER, ch_sum REAL, PRIMARY KEY (uid, h))",
];
const HOURLY_UPSERT = `INSERT INTO hourly (uid, h, n, sum_out, max_out, ch_n, ch_sum) VALUES (?, ?, 1, ?, ?, ?, ?)
  ON CONFLICT(uid, h) DO UPDATE SET n = n + 1, sum_out = sum_out + excluded.sum_out, max_out = MAX(max_out, excluded.max_out),
  ch_n = ch_n + excluded.ch_n, ch_sum = ch_sum + excluded.ch_sum`;
async function kvGet(env, k) { const r = await env.DB.prepare("SELECT v FROM kv WHERE k=?").bind(k).first(); return r ? JSON.parse(r.v) : null; }
async function kvSet(env, k, v) { await env.DB.prepare("INSERT OR REPLACE INTO kv (k, v) VALUES (?, ?)").bind(k, JSON.stringify(v)).run(); }
const rid = (n = 24) => { const a = new Uint8Array(n); crypto.getRandomValues(a); return btoa(String.fromCharCode(...a)).replace(/[+/=]/g, c => ({ "+": "-", "/": "_", "=": "" }[c])); };

let schemaOk = false;
async function ensureSchema(env) {
  if (schemaOk) return;
  for (const s of SCHEMA) await env.DB.prepare(s).run();
  // переїзд з однокористувацької версії: дані з kv → перший користувач із тим самим ключем (програма й телефон не помітять)
  const n = await env.DB.prepare("SELECT COUNT(*) c FROM users").first();
  if (n.c === 0 && env.API_KEY) {
    const tokens = await kvGet(env, "tokens");
    if (tokens) {
      const data = { tokens, device: await kvGet(env, "device"), config: await kvGet(env, "config"), live: await kvGet(env, "live"),
        grid: await kvGet(env, "grid"), events: await kvGet(env, "events"), health: await kvGet(env, "health"), alerts: await kvGet(env, "alerts"),
        tg_chat: await kvGet(env, "tg_chat"), tg_code: await kvGet(env, "tg_code") };
      const id = "u_" + rid(8);
      await env.DB.prepare("INSERT INTO users (id, key, dk, data, created) VALUES (?, ?, ?, ?, ?)").bind(id, env.API_KEY, data.device ? data.device.dk : null, JSON.stringify(data), Math.floor(Date.now() / 1000)).run();
      const t = await env.DB.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='samples'").first();
      if (t) await env.DB.prepare("INSERT OR IGNORE INTO samples2 (uid, ts, soc, out, inw, temp) SELECT ?, ts, soc, out, inw, temp FROM samples").bind(id).run();
    }
  }
  // один раз: заповнити погодинні підсумки з уже зібраних вимірів
  if (!(await kvGet(env, "hourly_v1"))) {
    await env.DB.prepare(`INSERT OR IGNORE INTO hourly (uid, h, n, sum_out, max_out, ch_n, ch_sum)
      SELECT uid, (ts / 3600) * 3600, COUNT(*), SUM(out), MAX(out), SUM(CASE WHEN inw - out > 100 THEN 1 ELSE 0 END), SUM(CASE WHEN inw - out > 100 THEN inw - out ELSE 0 END)
      FROM samples2 GROUP BY uid, ts / 3600`).run();
    await kvSet(env, "hourly_v1", 1);
  }
  schemaOk = true;
}

// користувач = рядок у users; усе його змінне зберігаємо одним JSON (одна дешева операція запису на хвилину)
function rowToUser(r) { if (!r) return null; const d = JSON.parse(r.data || "{}"); return { id: r.id, key: r.key, dk: r.dk, ...d }; }
async function userByKey(env, key) { return key ? rowToUser(await env.DB.prepare("SELECT * FROM users WHERE key=?").bind(key).first()) : null; }
async function userById(env, id) { return rowToUser(await env.DB.prepare("SELECT * FROM users WHERE id=?").bind(id).first()); }
async function saveUser(env, u) {
  const { id, key, dk, _refreshed, _resp_len, _prevOut, ...data } = u;
  await env.DB.prepare("UPDATE users SET data=?, dk=? WHERE id=?").bind(JSON.stringify(data), (u.device && u.device.dk) || dk || null, id).run();
}
// запис лише вказаних полів поверх свіжої копії з бази: запит панелі чи програми не повинен
// перезаписати застарілими даними те, що тим часом зберіг хвилинний цикл (сповіщення, події, графік)
async function saveFields(env, u, fields) {
  const f = await userById(env, u.id); if (!f) return;
  for (const k of fields) { if (u[k] === undefined) delete f[k]; else f[k] = u[k]; }
  await saveUser(env, f);
}
const cfgOf = u => ({ ...DEF_CFG, ...(u.config || {}) });

// ---------- час (Київ) ----------
// Intl дорогий (~0,2 мс на виклик), а ліміт процесора безкоштовного плану — 10 мс на запуск.
// Київ: +3 з останньої неділі березня 01:00 UTC до останньої неділі жовтня 01:00 UTC, інакше +2 — рахуємо арифметикою.
// Раз на процес звіряємо з Intl; якщо правила колись зміняться — переходимо на Intl з кешем по годинах.
const TZ_FMT = new Intl.DateTimeFormat("en-US", { timeZone: TZ, timeZoneName: "shortOffset" });
const TZ_CACHE = new Map();
function intlOffset(ms) {
  const p = TZ_FMT.formatToParts(new Date(ms));
  const m = ((p.find(x => x.type === "timeZoneName") || {}).value || "").match(/GMT([+-]\d+)(?::(\d+))?/);
  return m ? Number(m[1]) * 60 + Math.sign(Number(m[1])) * Number(m[2] || 0) : 120;
}
const lastSunday1am = (y, mon) => { const d = new Date(Date.UTC(y, mon + 1, 0, 1)); return d.getTime() - d.getUTCDay() * 86400000; };
function kyivRuleOffset(ms) {
  const y = new Date(ms).getUTCFullYear();
  return ms >= lastSunday1am(y, 2) && ms < lastSunday1am(y, 9) ? 180 : 120;
}
let tzRuleOk = null;
function tzOffsetMin(ms) {
  if (tzRuleOk === null) { const n = Date.now(); tzRuleOk = [n, n + 120 * 86400000, n + 240 * 86400000].every(t => kyivRuleOffset(t) === intlOffset(t)); }
  if (tzRuleOk) return kyivRuleOffset(ms);
  const hk = Math.floor(ms / 3600000);
  let v = TZ_CACHE.get(hk);
  if (v === undefined) { v = intlOffset(hk * 3600000 + 1800000); if (TZ_CACHE.size > 5000) TZ_CACHE.clear(); TZ_CACHE.set(hk, v); }
  return v;
}
const local = ms => new Date(ms + tzOffsetMin(ms) * 60000);
const isoMin = ms => local(ms).toISOString().slice(0, 16);
const hhmm = ms => local(ms).toISOString().slice(11, 16);
const dayKey = ms => local(ms).toISOString().slice(0, 10);
function modeAt(ms, c) {
  const d = local(ms), h = d.getUTCHours(), [a, b] = c.night;
  if (a > b ? (h >= a || h < b) : (h >= a && h < b)) return "night";
  return c.weekend_days.includes((d.getUTCDay() + 6) % 7) ? "weekend" : "work";
}

// ---------- хмара Wonderfree (від імені конкретного користувача) ----------
const sec = x => (x > 1e12 ? Math.floor(x / 1000) : x) || 0;
async function token(env, u) {
  const t = u.tokens;
  if (!t || !t.refresh) throw new Error("need_login");
  const now = Date.now() / 1000;
  if (t.access && t.access_exp && t.access_exp - now > 300) return t.access;
  const r = await fetch(`${BASE}/v2/enduser/enduserapi/refreshToken?refreshToken=${encodeURIComponent(t.refresh)}`, { method: "PUT", headers: HDR });
  const j = await r.json().catch(() => ({}));
  if (j.code !== 200) {
    // ключ оновлення одноразовий: можливо, паралельний запит щойно його використав — беремо свіжу пару з бази
    const f = u.id && await userById(env, u.id);
    if (f && f.tokens && f.tokens.refresh !== t.refresh) { u.tokens = f.tokens; delete u.auth_lost; return token(env, u); }
    u.auth_lost = now; throw new Error("need_login");
  }
  const d = j.data;
  u.tokens = { access: d.accessToken.token, access_exp: sec(d.accessToken.expirationTime) || now + 3600, refresh: d.refreshToken.token, refresh_exp: sec(d.refreshToken.expirationTime) };
  delete u.auth_lost; u._refreshed = true;
  if (u.id && u.id !== "tmp") await env.DB.prepare("UPDATE users SET data = json_remove(json_set(data, '$.tokens', json(?)), '$.auth_lost') WHERE id=?").bind(JSON.stringify(u.tokens), u.id).run();   // негайно, лише ключі
  return u.tokens.access;
}
async function cloud(env, u, path, { method = "GET", params, json } = {}) {
  const tok = await token(env, u);
  const h = { ...HDR, Authorization: tok };
  if (json) h["Content-Type"] = "application/json";
  const r = await fetch(`${BASE}${path}${params ? "?" + new URLSearchParams(params) : ""}`, { method, headers: h, body: json ? JSON.stringify(json) : undefined });
  const txt = await r.text().catch(() => "");
  if (path.includes("getDeviceBusinessAttributes")) u._resp_len = txt.length;
  let j = {}; try { j = JSON.parse(txt); } catch (e) {}
  if (j.code === 12401 || j.code === 5032) u.tokens.access_exp = 0;
  return j;
}
async function device(env, u) {
  if (u.device) return u.device;
  const j = await cloud(env, u, "/v2/binding/enduserapi/userDeviceList", { params: { page: 1, pageSize: 50, isAssociation: false } });
  const list = (j.data && j.data.list) || [];
  const x = list.find(v => /P2001|P5000|P1201|P800|OUKITEL/i.test(v.productName || v.deviceName || "")) || list[0];
  if (!x) throw new Error("no_device");
  u.device = { pk: x.productKey, dk: x.deviceKey, name: x.deviceName, model: x.productName };
  return u.device;
}
async function send(env, u, items) {
  const d = await device(env, u);
  const j = await cloud(env, u, "/v2/binding/enduserapi/batchControlDevice", { method: "POST",
    json: { data: JSON.stringify([items]), deviceList: [{ productKey: d.pk, deviceKey: d.dk }], type: 2, dataFormat: 1 } });
  return !!(j.data && j.data.successList && j.data.successList.length);
}

const num = v => { const n = Number(v); return Number.isFinite(n) ? n : null; };
const bool = v => v === true || v === "true" || v === 1 || v === "1";
function mapState(list) {
  const s = {}, raw = {}; let newest = 0;
  for (const it of list || []) { raw[it.resourceCode] = it.resourceValce; newest = Math.max(newest, Number(it.createTime) || 0); }
  const simple = { battery_percentage: "soc", remain_time: "remain_min", remain_charging_time: "remain_charge_min", total_input_power: "in_w",
    total_output_power: "out_w", ac_input: "ac_in_w", dc_input: "dc_in_w", temp: "temp", ac_charging_limit: "ac_limit",
    Frequency_Switchover: "freq", ACvoltage_Switchover: "ac_set_v", AC_Version: "ac_ver", BMS_Version: "bms_ver" };
  for (const [c, k] of Object.entries(simple)) if (raw[c] != null && num(raw[c]) != null) s[k] = num(raw[c]);
  for (const [c, k] of [["ac_switch", "ac_on"], ["usb_switch", "usb_on"], ["dc_switch", "dc_on"]]) if (raw[c] != null) s[k] = bool(raw[c]);
  const st = c => { try { return JSON.parse(raw[c] || "{}"); } catch (e) { return {}; } };
  const ac = st("ac_data"), usb = st("usb_data"), tc = st("typec_data"), dc = st("dc_data");
  if (ac.ac1_output != null) s.ac_out_w = num(ac.ac1_output);
  if (ac.ac1_output_voltage != null) s.ac_v = num(ac.ac1_output_voltage);
  if (usb.USB_QC1_output != null || usb.USB_QC2_output != null) s.usb_a = [num(usb.USB_QC1_output) || 0, num(usb.USB_QC2_output) || 0];
  if (Object.keys(tc).length) s.usb_c = ["Typec1_output", "Typec2_output", "Typec3_output", "Typec4_output"].map(k => num(tc[k]) || 0);
  if (dc.car1_output != null) s.dc_out_w = num(dc.car1_output);
  if (dc.car1_output_voltage != null) s.dc_v = num(dc.car1_output_voltage);
  if (dc.car1_output_current != null) s.dc_a = num(dc.car1_output_current);
  return { s, newest: newest > 1e12 ? newest / 1000 : newest };
}
async function readOnce(env, u) {
  const d = await device(env, u);
  const j = await cloud(env, u, "/v2/binding/enduserapi/getDeviceBusinessAttributes", { params: { pk: d.pk, dk: d.dk, gatewayDk: "", codeList: "", type: "" } });
  if (j.code !== 200) throw new Error("read_failed:" + (j.msg || j.code));
  return mapState(j.data && j.data.customizeTslInfo);
}

// ---------- графік Yasno (один запит на регіон, спільний для всіх) ----------
function parseDay(day) {
  if (!day || !day.date) return null;
  const off = [];
  for (const s of day.slots || []) {
    const typ = s.type || "Definite";
    if (["notplanned", "none", "on"].includes(String(typ).toLowerCase())) continue;
    const m = v => { const x = Number(v) || 0; return x <= 24 ? x * 60 : x; };
    const a = m(s.start), b = m(s.end);
    if (b > a) off.push([a, b, typ]);
  }
  return { date: String(day.date).slice(0, 10), base: Date.parse(day.date), status: day.status || null, off };
}
// графік усіх груп — великий JSON: тримаємо розібраний у пам'яті процесу, а не читаємо й розбираємо з бази на кожен запит
const RD_MEM = new Map();
async function regionData(env, c, force = false) {
  const k = `sched:${c.region_id}:${c.dso_id}`, mem = RD_MEM.get(k), nowS = Date.now() / 1000;
  if (!force && mem && nowS - mem.fetched < 900 && nowS - mem.seen < 120) return mem.v;
  const old = await kvGet(env, k);
  if (old) RD_MEM.set(k, { v: old, fetched: old.fetched, seen: nowS });
  if (!force && old && nowS - old.fetched < 900) return old;
  try {
    const r = await fetch(`https://app.yasno.ua/api/blackout-service/public/shutdowns/regions/${c.region_id}/dsos/${c.dso_id}/planned-outages`,
      { headers: { "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)" } });
    const data = await r.json();
    const v = { fetched: Date.now() / 1000, data };
    await kvSet(env, k, v);
    RD_MEM.set(k, { v, fetched: v.fetched, seen: Date.now() / 1000 });
    return v;
  } catch (e) { return old || { fetched: 0, data: {} }; }
}
function scheduleFor(rd, c) {
  const data = (rd && rd.data) || {};
  const groups = Object.keys(data).sort((a, b) => { const pa = a.split(".").map(Number), pb = b.split(".").map(Number); return pa[0] - pb[0] || pa[1] - pb[1]; });
  const gd = c.group && data[c.group];
  return gd ? { ok: true, group: c.group, groups, updated: gd.updatedOn || null, today: parseDay(gd.today), tomorrow: parseDay(gd.tomorrow), fetched: rd.fetched }
            : { ok: false, group: c.group, groups, error: c.group ? (groups.length ? `групи ${c.group} немає у графіку` : "графік недоступний") : "групу не вказано" };
}
// «стінний» київський час дня date (YYYY-MM-DD) + хвилини → мітка часу (коректно в дні переходу на літній/зимовий час)
function wallMs(date, minutes) {
  const [y, mo, d] = date.split("-").map(Number), naive = Date.UTC(y, mo - 1, d, 0, minutes);
  const guess = naive - tzOffsetMin(naive - 120 * 60000) * 60000;
  return naive - tzOffsetMin(guess) * 60000;
}
function outageIntervals(sc) {
  const res = [];
  if (!sc || !sc.ok) return res;
  for (const k of ["today", "tomorrow"]) { const d = sc[k]; if (!d || !d.date) continue; for (const [a, b] of d.off) res.push([wallMs(d.date, a), wallMs(d.date, b)]); }
  res.sort((x, y) => x[0] - y[0]);
  const m = [];
  for (const iv of res) { const l = m[m.length - 1]; if (l && iv[0] <= l[1]) l[1] = Math.max(l[1], iv[1]); else m.push(iv); }
  return m;
}

// ---------- Telegram (один бот на всіх) ----------
async function tg(env, method, body) {
  if (!env.TG_TOKEN) return null;
  const r = await fetch(`https://api.telegram.org/bot${env.TG_TOKEN}/${method}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
  return r.json().catch(() => null);
}
async function notify(env, u, text) { if (u.tg_chat) await tg(env, "sendMessage", { chat_id: u.tg_chat, text, parse_mode: "HTML", disable_web_page_preview: true }); }
const tgLink = u => `https://t.me/${BOT_NAME}?start=${u.tg_code}`;
const initEnv = env => { if (env.BOT_NAME) BOT_NAME = env.BOT_NAME; };
const phoneLink = (base, u) => `${base}/?k=${encodeURIComponent(u.key)}`;

async function statusText(env, u) {
  const d = await computeState(env, u), st = d.station || {};
  if (!d.ready) return "Станція поки не на зв'язку з хмарою.";
  const lines = [`🔋 <b>${Math.round(st.soc)}%</b> · ${d.grid ? (d.charging ? `заряджається +${Math.max(0, d.net_w)} Вт` : d.idle ? "світло є, станція в очікуванні" : "світло є, режим ДБЖ") : `від батареї, −${st.out_w} Вт`}`];
  if (!d.grid) {
    if (d.runout_at) lines.push(`⏳ вистачить до ${d.runout_at.slice(11)}${d.runout_at.slice(0, 10) !== dayKey(Date.now()) ? " (завтра)" : ""}`);
    if (d.power_on_at) lines.push(`💡 світло за графіком о ${d.power_on_at.slice(11)}`);
  } else if (d.next_off) lines.push(`📅 наступне відключення ${d.next_off[0].slice(11)}–${d.next_off[1].slice(11)}`);
  else lines.push("📅 відключень за графіком не видно");
  if (st.temp != null) lines.push(`🌡 ${st.temp} °C`);
  const tip = (d.health && d.health.tips || []).find(t => t.level === "alert" || t.level === "warn");
  if (tip) lines.push(`⚠️ ${tip.title}`);
  if (!d.fresh) lines.push(`<i>дані ${Math.round((Date.now() / 1000 - (d.updated || 0)) / 60)} хв тому</i>`);
  return lines.join("\n");
}
async function handleTelegram(env, req, url) {
  const upd = await req.json().catch(() => ({}));
  const m = upd.message; if (!m || !m.text) return new Response("ok");
  const text = m.text.trim(), base = `${url.protocol}//${url.host}`;
  const reply = t => tg(env, "sendMessage", { chat_id: m.chat.id, text: t, parse_mode: "HTML", disable_web_page_preview: true });
  if (text.startsWith("/start")) {
    const code = text.split(/\s+/)[1];
    const r = code ? await env.DB.prepare("SELECT * FROM users WHERE json_extract(data, '$.tg_code') = ?").bind(code).first() : null;
    if (!r) { await reply("Щоб підключити сповіщення, відкрийте бота з програми «патужно» на Mac: правий клік по іконці → «Telegram-сповіщення»."); return new Response("ok"); }
    const u = rowToUser(r);
    u.tg_chat = m.chat.id; await saveFields(env, u, ["tg_chat"]);
    await reply(`⚡️ <b>патужно</b> підключено!\n\nЯ напишу, коли зникне чи з'явиться світло, коли заряд низький, станція гріється або випала з мережі, і за пів години до відключення за графіком.\n\n/status — стан зараз\n/app — панель на телефоні\n\n${await statusText(env, u)}`);
    return new Response("ok");
  }
  const rows = await env.DB.prepare("SELECT * FROM users WHERE json_extract(data, '$.tg_chat') = ?").bind(m.chat.id).all();
  const users = (rows.results || []).map(rowToUser);
  if (!users.length) { await reply("Відкрийте бота з програми «патужно» на Mac, щоб прив'язати свою станцію."); return new Response("ok"); }
  for (const u of users) {
    if (text.startsWith("/status") || text === "стан") await reply(await statusText(env, u));
    else if (text.startsWith("/app")) await reply(`Панель «патужно»: ${phoneLink(base, u)}\n\nВідкрийте в Safari → «Поділитися» → «На початковий екран». Не пересилайте це посилання — воно дає керування станцією.`);
    else if (text.startsWith("/stop")) { delete u.tg_chat; await saveFields(env, u, ["tg_chat"]); await reply("Сповіщення вимкнено. Увімкнути знову — з програми на Mac."); }
    else await reply("/status — стан станції\n/app — панель на телефоні\n/stop — вимкнути сповіщення");
  }
  return new Response("ok");
}

// ---------- збір (щохвилини, для всіх користувачів) ----------
// запис результатів хвилинного циклу: перечитуємо рядок і змінюємо лише поля, якими володіє цикл
// (поки цикл працював ~30 с, користувач міг прив'язати Telegram, змінити групу чи увійти знову)
const TICK_FIELDS = ["live", "grid", "events", "health", "alerts", "hf_ts", "last_error", "stats", "device", "hold"];
async function saveTick(env, u) {
  const f = await userById(env, u.id); if (!f) return;
  for (const k of TICK_FIELDS) { if (u[k] === undefined) delete f[k]; else f[k] = u[k]; }
  if (u.auth_lost && f.tokens && u.tokens && f.tokens.refresh === u.tokens.refresh) f.auth_lost = u.auth_lost;
  await saveUser(env, f);
}

async function tickUser(env, u, samples, idx) {
  const now = Date.now() / 1000, c = cfgOf(u);
  const rows = [], prevTs = (u.live && u.live.updated) || 0, held = u.hold || null;   // притриманий з минулого циклу стрибок
  u._prevOut = u.live && u.live.state ? Math.max(u.live.state.out_w || 0, u.live.state.in_w || 0) : null;   // попередній «нормальний» вимір
  try {
    // часті звіти: розносимо користувачів по різних хвилинах, щоб не впертись у ліміт запитів за запуск
    if (!u.hf_ts || (now - u.hf_ts > 170 && (Math.floor(now / 60) + idx) % 3 === 0) || now - u.hf_ts > 400) { if (await send(env, u, { high_frequency_reporting: "3" })) u.hf_ts = now; }
    for (let i = 0; i < samples; i++) {
      const t0 = Date.now();
      const { s, newest } = await readOnce(env, u);
      const nowR = Date.now() / 1000, online = !newest || nowR - newest < 600;
      const ts = Math.floor(newest && newest < nowR ? Math.max(newest, nowR - 60) : nowR);   // час самих даних, а не запиту
      // одиничні викиди вимірювача (кидок струму при старті приладу або збій прошивки: 4–6 кВт на один вимір між
      // звичайними 200 Вт) псують графіки, пік доби й дають хибні тривоги. Понад 2600 Вт станція віддати не може — відкидаємо
      // одразу; різкий стрибок (у 4+ разів і на 1200+ Вт) притримуємо на один вимір і пишемо, лише якщо наступний його підтвердить
      const outW = s.out_w ?? 0, inW = s.in_w ?? 0, lvl = Math.max(outW, inW);
      const impossible = lvl > 2600;
      const row = [u.id, ts, s.soc, outW, inW, s.temp ?? 0];
      if (u.hold) {   // притриманий стрибок: підтверджено, якщо навантаження лишилось високим
        if (!impossible && lvl > Math.max(u.hold[3], u.hold[4]) * 0.5 && lvl > 1200) { rows.push(u.hold); u._prevOut = Math.max(u.hold[3], u.hold[4]); }
        delete u.hold;
      }
      const jump = !impossible && lvl > 1500 && u._prevOut != null && lvl > u._prevOut * 4 && lvl - u._prevOut > 1200;
      if (impossible || jump) {
        if (jump && online && s.soc != null) u.hold = row;
        if (u.live && u.live.state) { s.out_w = u.live.state.out_w; s.in_w = u.live.state.in_w; s.ac_out_w = u.live.state.ac_out_w; }   // на панелі — попереднє значення
      } else {
        u._prevOut = lvl;
        if (online && s.soc != null) rows.push(row);
      }
      u.live = { state: s, updated: ts, online, station_ts: newest, rl: u._resp_len };
      if (i < samples - 1) await new Promise(r => setTimeout(r, Math.max(0, 25000 - (Date.now() - t0))));
    }
    delete u.last_error;
  } catch (e) { u.last_error = { ts: now, msg: String(e.message || e) }; }
  if (rows.length) {
    // повтори тієї ж відповіді станції відкидаємо ще до запису — тоді виміри й погодинні підсумки пишуться одним пакетом
    const seen = new Set(), fresh = rows.filter(r => (r === held || r[1] > prevTs) && !seen.has(r[1]) && seen.add(r[1]));
    if (fresh.length) await env.DB.batch(fresh.flatMap(([uid, ts, soc, out, inw, temp]) => { const ch = inw - out > 100;
      return [env.DB.prepare("INSERT OR IGNORE INTO samples2 (uid, ts, soc, out, inw, temp) VALUES (?, ?, ?, ?, ?, ?)").bind(uid, ts, soc, out, inw, temp),
              env.DB.prepare(HOURLY_UPSERT).bind(uid, Math.floor(ts / 3600) * 3600, out, out, ch ? 1 : 0, ch ? inw - out : 0)]; }));
  }

  const rd = await regionData(env, c);
  await track(env, u, rows, scheduleFor(rd, c));
  if (!u.stats || now - (u.stats.ts || 0) > 3600) await refreshStats(env, u, c);
  await saveTick(env, u);
}

// важкі агрегати (по режимах за 14 днів, швидкість зарядки, пік) — раз на годину, а не на кожен запит панелі
async function refreshStats(env, u, c) {
  const nowS = Date.now() / 1000, from = Math.floor(nowS - 14 * 86400);
  // за 14 днів може бути перехід на літній/зимовий час — для кожної години беремо її власний зсув
  const offNow = tzOffsetMin(nowS * 1000), offOld = tzOffsetMin(from * 1000);
  let sw = 0;
  if (offNow !== offOld) { let lo = from, hi = Math.floor(nowS); while (hi - lo > 60) { const mid = Math.floor((lo + hi) / 2); if (tzOffsetMin(mid * 1000) === offOld) lo = mid; else hi = mid; } sw = hi; }
  const lt = `(h + (CASE WHEN h >= ${sw} THEN ${offNow} ELSE ${offOld} END) * 60)`;
  const wk = (c.weekend_days || [5, 6]).map(d => `'${(d + 1) % 7}'`).join(",") || "'-'";
  const mr = await env.DB.prepare(`SELECT CASE
      WHEN CAST(strftime('%H', ${lt}, 'unixepoch') AS INT) >= ?1 OR CAST(strftime('%H', ${lt}, 'unixepoch') AS INT) < ?2 THEN 'night'
      WHEN strftime('%w', ${lt}, 'unixepoch') IN (${wk}) THEN 'weekend' ELSE 'work' END m, SUM(sum_out) s, SUM(n) n
      FROM hourly WHERE uid=?4 AND h > ?3 GROUP BY m`).bind(c.night[0], c.night[1], from, u.id).all();
  const mw = {};
  for (const r of mr.results || []) if (r.n >= 30) mw[r.m] = r.s / r.n;
  const lc = await env.DB.prepare("SELECT SUM(ch_sum) s, SUM(ch_n) n FROM hourly WHERE uid=? AND h > ?").bind(u.id, Math.floor(nowS - 7 * 86400)).first();
  const pk = await env.DB.prepare("SELECT MAX(max_out) p FROM hourly WHERE uid=? AND h >= ?").bind(u.id, Math.floor((nowS - 86400) / 3600) * 3600).first();
  u.stats = { ts: nowS, mw, charge_w: lc && lc.n >= 30 ? lc.s / lc.n : null, peak24: (pk && pk.p) || 0 };
}

async function tick(env) {
  await ensureSchema(env);
  const all = ((await env.DB.prepare("SELECT * FROM users").all()).results || []).map(rowToUser);
  if (!all.length) return;
  // ліміт безкоштовного плану — ~50 зовнішніх запитів за запуск: ділимо їх між користувачами
  const samples = all.length <= 5 ? 2 : 1;   // 2 виміри за хвилину: ліміт процесора безкоштовного плану — 10 мс на запуск
  for (let i = 0; i < all.length; i += 6) await Promise.all(all.slice(i, i + 6).map((u, j) => tickUser(env, u, samples, i + j).catch(() => {})));
  const now = Date.now() / 1000;
  // прибирання старого — раз на добу (о 03:00 UTC), по кожному користувачу окремо: так база читає лише рядки, що видаляються
  if (Math.floor(now / 60) % 1440 === 180) {
    const cut = Math.floor(now) - KEEP_DAYS * 86400;
    await env.DB.batch(all.flatMap(u => [env.DB.prepare("DELETE FROM samples2 WHERE uid=? AND ts < ?").bind(u.id, cut), env.DB.prepare("DELETE FROM hourly WHERE uid=? AND h < ?").bind(u.id, cut)]));
  }
}

async function track(env, u, rows, sc) {
  const now = Date.now();
  const g = u.grid || { state: null, cand: null, streak: 0, candTs: 0 };
  const events = u.events || [];
  const h = u.health || { since: now / 1000, dischargedPct: 0, chargedPct: 0, lastSoc: null, lastFullTs: null, lastLowTs: null, lastCalibTs: null, lowSinceFull: null, deepCount: 0, maxTemp: null, peakOutW: 0, peakOutTs: null };
  const al = u.alerts || {};
  const need = rows.length >= 3 ? 3 : 2;   // підтвердження зміни: 2–3 записи поспіль
  const say = [];
  const ivs = outageIntervals(sc);
  for (const [, ts, soc, out, inw, temp] of rows) {
    // є вхід — світло є; вхід 0, але щось живиться — від батареї, світла немає;
    // 0 і там, і там (розетки вимкнені, батарея не дозаряджається) — по станції не видно, тож світло «вимикаємо» лише за графіком
    // без навантаження: у вікні відключення за графіком — «ймовірно, немає»; коли вікно скінчилось і «немає» було лише за графіком —
    // так само за графіком «ймовірно, дали». Такі події позначаємо est, і бот пише про них обережно.
    const idle = inw <= 5 && out <= 5, inOut = ivs.some(([a, b]) => ts * 1000 >= a && ts * 1000 < b);
    let gs = null, est = false;
    if (!idle) gs = inw > 5;
    else if (inOut) { gs = false; est = true; }
    else if (g.state === false && g.est) { gs = true; est = true; }
    if (gs === null) { if (g.cand === false) { g.cand = null; g.streak = 0; } }
    else if (g.state === null) { g.state = gs; g.est = est; }
    else if (gs === g.state) { g.cand = null; g.streak = 0; if (!est) g.est = false; }
    else {
      if (g.cand !== gs) { g.cand = gs; g.streak = 1; g.candTs = ts; g.candSoc = soc; g.candEst = est; } else { g.streak++; if (!est) g.candEst = false; }
      if (g.streak >= need) {
        g.state = gs; g.est = !!g.candEst;
        events.push({ ts: g.candTs, type: gs ? "on" : "off", soc: g.candSoc ?? soc, ...(g.est ? { est: true } : {}) });
        g.cand = null; g.streak = 0; say.push((gs ? "on" : "off") + (g.est ? "~" : ""));
      }
    }
    if (h.lastSoc != null) { const d = soc - h.lastSoc; if (d < 0 && d > -20) h.dischargedPct += -d; else if (d > 0 && d < 20) h.chargedPct += d; }
    if (soc <= 5 && (h.lastSoc ?? 100) > 5) h.deepCount++;
    h.lastSoc = soc;
    if (soc >= 99.5) { if (h.lowSinceFull != null && h.lowSinceFull <= 20) h.lastCalibTs = ts; h.lastFullTs = ts; h.lowSinceFull = soc; }
    else h.lowSinceFull = Math.min(h.lowSinceFull ?? soc, soc);
    if (soc <= 20) h.lastLowTs = ts;
    if (temp) h.maxTemp = Math.max(h.maxTemp ?? temp, temp);
    if (out > h.peakOutW) { h.peakOutW = out; h.peakOutTs = ts; }
  }
  while (events.length > 300) events.shift();
  u.grid = g; u.events = events; u.health = h;
  if (!env.TG_TOKEN || !u.tg_chat) { u.alerts = al; return; }

  const s = (u.live && u.live.state) || {};
  // позначку «надіслано» пишемо в базу ДО відправки: якщо Cloudflare обірве запуск посередині, повтору не буде
  const markAlerts = () => env.DB.prepare("UPDATE users SET data = json_set(data, '$.alerts', json(?)) WHERE id=?").bind(JSON.stringify(al), u.id).run();
  const once = async (key, cond, text, again = 0) => {
    if (cond) { if (!al[key] || (again && now / 1000 - al[key] > again)) { al[key] = now / 1000; await markAlerts(); await notify(env, u, text); } }
    else if (al[key]) delete al[key];
  };
  if (say.length) await env.DB.prepare("UPDATE users SET data = json_set(json_set(data, '$.grid', json(?)), '$.events', json(?)) WHERE id=?").bind(JSON.stringify(g), JSON.stringify(events), u.id).run();
  const d = say.length ? await computeState(env, u) : null;
  // «завтра 15:10» / «28.10 09:40», якщо час не сьогодні
  const whenTxt = iso => { const day = iso.slice(0, 10), t = iso.slice(11, 16);
    if (day === dayKey(now)) return t; if (day === dayKey(now + 86400000)) return "завтра " + t; return `${day.slice(8, 10)}.${day.slice(5, 7)} ${t}`; };
  const durTxt = secs => { const m = Math.round(secs / 60), h = Math.floor(m / 60); return h ? `${h} год ${String(m % 60).padStart(2, "0")} хв` : `${m} хв`; };
  for (const e of say) {
    if (s.soc == null) break;
    if (e === "off~" || e === "on~") {
      const ev = [...events].reverse().find(x => x.type === e.slice(0, -1));
      await notify(env, u, (e === "off~" ? `⚡️ <b>Світло, ймовірно, зникло</b> о ${hhmm(ev.ts * 1000)} — за графіком` : `💡 <b>Світло, ймовірно, дали</b> о ${hhmm(ev.ts * 1000)} — за графіком`) +
        `\n🔌 Станція зараз нічого не живить і не заряджається${s.ac_on === false ? " (розетки вимкнені)" : ""}, тож напевно не видно, чи є світло. Увімкніть розетки станції з будь-яким приладом — і бот бачитиме світло точно.` +
        `\n🔋 ${Math.round(s.soc)}%` + (e === "off~" && d && d.power_on_at ? `\n💡 за графіком світло о ${whenTxt(d.power_on_at)}` : ""));
      continue;
    }
    if (e === "off") {
      // скільки світло було — від останнього «дали» до цього «зникло»
      const offEv = [...events].reverse().find(x => x.type === "off"), onEv = offEv && [...events].reverse().find(x => x.type === "on" && x.ts < offEv.ts);
      const had = onEv ? offEv.ts - onEv.ts : 0;
      await notify(env, u, `⚡️ <b>Світло зникло</b> о ${hhmm(now)}` + (had > 0 && had < 7 * 86400 ? `\n⏱ світло було <b>${durTxt(had)}</b>` : "") +
      `\n🔋 ${Math.round(s.soc)}%, навантаження ${s.out_w ?? 0} Вт` +
      (d && d.runout_at ? ((s.out_w || 0) > 5 ? `\n⏳ вистачить приблизно до ${whenTxt(d.runout_at)}`
        : `\n⏳ при звичному споживанні (~${Math.round(((d.scenarios || []).find(x => x.current) || {}).w || 0)} Вт) вистачить до ${whenTxt(d.runout_at)}`) : "") + (d && d.power_on_at ? `\n💡 за графіком світло о ${whenTxt(d.power_on_at)}` : ""));
    }
    else {
      // скільки світла не було і скільки заряду пішло — від останнього «зникло» до цього «дали»
      const onEv = [...events].reverse().find(x => x.type === "on"), offEv = onEv && [...events].reverse().find(x => x.type === "off" && x.ts < onEv.ts);
      const gap = offEv ? onEv.ts - offEv.ts : 0, used = offEv && offEv.soc != null ? Math.round(offEv.soc - (onEv.soc ?? s.soc)) : null;
      await notify(env, u, `💡 <b>Світло дали</b> о ${hhmm(now)}` +
        (gap > 0 && gap < 3 * 86400 ? `\n⏱ світла не було <b>${durTxt(gap)}</b>` + (used > 0 ? ` · витрачено ${used}%` : "") : "") +
        `\n🔋 ${Math.round(s.soc)}%` + (d && d.recharge && d.recharge.full_at && s.soc < 99 ? `, повністю зарядиться ~${whenTxt(d.recharge.full_at)}` : ""));
    }
  }
  const noGrid = g.state === false;
  // гістерезис: повторне сповіщення про низький заряд — лише після підзарядки вище 25 % / 15 %
  const keepLow = k => al[k] && s.soc != null && s.soc < (k === "low20" ? 25 : 15);
  await once("low20", (noGrid && s.soc != null && s.soc <= 20 && s.soc > 10) || keepLow("low20"), `🪫 Заряд <b>${Math.round(s.soc)}%</b>, світла немає. Залиште тільки найважливіше.`);
  await once("low10", (noGrid && s.soc != null && s.soc <= 10) || keepLow("low10"), `🟥 Заряд <b>${Math.round(s.soc)}%</b> — станція скоро вимкнеться.`);
  await once("hot", s.temp != null && s.temp >= 45, `🌡 Станція гаряча: <b>${s.temp} °C</b>. Зменште навантаження й дайте їй повітря.`, 3600);
  // перевантаження — лише якщо тримається хоча б два виміри поспіль (~15 с), а не одиничний сплеск при вмиканні приладу
  const hiRows = rows.filter(r => r[3] >= 2200), hiNow = hiRows.length >= 2 || (hiRows.length === 1 && !!al.load_prev);
  al.load_prev = rows.length ? rows[rows.length - 1][3] >= 2200 : false;
  const hiW = hiRows.length ? Math.round(Math.max(...hiRows.map(r => r[3]))) : s.out_w;
  await once("load", hiNow, `🔥 Навантаження <b>${hiW} Вт</b> — майже межа 2400 Вт.`, 1800);
  const stale = !u.live || !u.live.online || now / 1000 - u.live.updated > 600;
  await once("offline", stale && !u.auth_lost, "📡 Понад 10 хв немає свіжих даних від станції: можливо, вдома немає Wi-Fi чи інтернету, станція вимкнулась, або тимчасово не працює хмара Wonderfree.");
  await once("login", !!u.auth_lost, "🔑 Сервер втратив вхід у Wonderfree (так буває, якщо в акаунт увійшли на іншому пристрої). На Mac: правий клік по іконці «Станції» → «Увійти в Wonderfree знову…». Історія, сповіщення й посилання збережуться.");
  const nxt = outageIntervals(sc).find(iv => iv[0] > now);
  const mins = nxt ? (nxt[0] - now) / 60000 : 1e9;
  await once("soon:" + (nxt ? nxt[0] : 0), mins <= 35 && mins > 0, nxt ? `📅 О ${hhmm(nxt[0])} за графіком відключення (до ${hhmm(nxt[1])}). Заряд зараз <b>${Math.round(s.soc)}%</b>.` : "");
  for (const k of Object.keys(al)) if (k.startsWith("soon:") && Number(k.slice(5)) < now - 86400000) delete al[k];
  u.alerts = al;
}

// ---------- розрахунки для панелі ----------
async function computeState(env, u) {
  const c = cfgOf(u), live = u.live, dv = u.device;
  const sc = scheduleFor(await regionData(env, c), c);
  const now = Date.now(), nowS = now / 1000;
  const s = { ...((live && live.state) || {}) };
  const fresh = !!(live && live.online && nowS - live.updated < 180);
  s.connected = fresh; s.last_update = live ? (fresh ? Math.max(live.updated, nowS - 25) : live.updated) : null; s.source = "cloud";
  if (!fresh) s.error = u.auth_lost ? "сервер: потрібно заново увійти в Wonderfree" : (live ? "станція не на зв'язку з хмарою" : "сервер ще не отримав даних");
  const out = { now: isoMin(now), station: s, fresh, updated: live && live.updated, schedule: sc, setup: { has_key: !!u.tokens, model: (dv && dv.model) || c.model || "" },
    config: { group: c.group, capacity_wh: c.capacity_wh } };
  if (s.soc == null) { out.ready = false; return out; }
  out.ready = true;
  const cap = c.capacity_wh, eff = c.inverter_efficiency, reserve = c.reserve_percent, chEff = c.charge_efficiency, soc = s.soc;
  const usable = Math.max(0, soc - reserve) / 100 * cap * eff;
  out.usable_wh = Math.round(usable); out.stored_wh = Math.round(soc / 100 * cap);
  const w5 = await env.DB.prepare("SELECT AVG(out) a FROM samples2 WHERE uid=? AND ts > ?").bind(u.id, Math.floor(nowS - 300)).first();
  const nowW = (w5 && w5.a != null) ? w5.a : (s.out_w || 0);
  out.now_w = Math.round(nowW);
  const inW = s.in_w || 0, idle = inW <= 5 && (s.out_w || 0) <= 5;
  const grid = inW > 5 || (idle && !!(u.grid && u.grid.state));
  out.grid = grid; out.idle = idle && grid; out.charging = grid && inW > nowW + 20; out.net_w = Math.round(inW - (s.out_w || 0));
  if (!u.stats) await refreshStats(env, u, c);
  const st0 = u.stats || { mw: {} }, mw = {};
  for (const k of ["work", "night", "weekend"]) mw[k] = st0.mw && st0.mw[k] != null ? { w: st0.mw[k], h: true } : { w: c.fallback_watts[k], h: false };
  const curMode = modeAt(now, c);
  out.scenarios = [{ key: "now", name: "Як зараз", w: nowW, src: "середнє за 5 хв" }].concat(
    [["work", "Робота"], ["night", "Ніч"], ["weekend", "Вихідні"]].map(([k, nm]) => ({ key: k, name: nm, w: mw[k].w, current: k === curMode, src: mw[k].h ? "середнє за 14 днів" : "типово" })))
    .map(x => ({ ...x, hours: x.w > 1 ? usable / x.w : null, w: Math.round(x.w) }));
  let sim = usable, tt = now, first = true;
  while (sim > 0 && tt < now + 7 * 86400000) { const m = modeAt(tt, c); const w = first && m === curMode && nowW > 5 ? nowW : mw[m].w; if (m !== curMode) first = false; sim -= Math.max(w, 1) * 900 / 3600; tt += 900000; }
  out.runout_at = sim <= 0 ? isoMin(tt) : null;
  const ivs = outageIntervals(sc), cur = ivs.find(iv => iv[0] <= now && now < iv[1]), nxt = ivs.find(iv => iv[0] > now);
  const powerOn = !grid && cur ? cur[1] : null;
  out.power_on_at = powerOn ? isoMin(powerOn) : null;
  out.next_off = nxt ? [isoMin(nxt[0]), isoMin(nxt[1])] : null;
  const chargeW = st0.charge_w || c.max_ac_charge_w * ((s.ac_limit ?? 100) / 100);
  out.charge_w = Math.round(chargeW);
  const toFull = p => (100 - p) / 100 * cap / (chargeW * chEff);
  if (!grid && powerOn) {
    const hrs = (powerOn - now) / 3600000, endSoc = soc - (nowW * hrs / eff) / cap * 100;
    out.budget = { until: isoMin(powerOn), hours: hrs, avg_w: hrs > 0 ? Math.round(usable / hrs) : null, soc_at_on: Math.max(0, Math.round(endSoc * 10) / 10), enough: endSoc > reserve };
    const after = ivs.find(iv => iv[0] > powerOn), full = powerOn + toFull(Math.max(0, endSoc)) * 3600000;
    out.recharge = { start_soc: Math.round(Math.max(0, endSoc)), full_at: isoMin(full), next_off: after ? isoMin(after[0]) : null, ok: !after || full <= after[0] };
  } else if (grid) {
    const full = soc < 99.5 ? now + toFull(soc) * 3600000 : now;
    const rc = { full_at: isoMin(full), charging: out.charging };
    if (nxt) {
      const hrs = (nxt[0] - now) / 3600000, socThen = Math.min(100, soc + hrs * chargeW * chEff / cap * 100), dur = (nxt[1] - nxt[0]) / 3600000;
      Object.assign(rc, { next_off: isoMin(nxt[0]), ok: full <= nxt[0], soc_at_off: Math.round(socThen), off_hours: dur,
        off_budget_w: dur > 0 ? Math.round((socThen - reserve) / 100 * cap * eff / dur) : null });
    }
    out.recharge = rc;
  }
  out.mode = curMode;
  out.events = (u.events || []).slice(-12).reverse();
  out.health = await healthTips(env, u, s, out, nxt, cap);
  return out;
}

async function healthTips(env, u, s, d, nxt, cap) {
  const h = u.health || {}, now = Date.now() / 1000, tips = [];
  const tip = (level, icon, title, text, action) => tips.push(action ? { level, icon, title, text, action } : { level, icon, title, text });
  const peak = Math.max((u.stats && u.stats.peak24) || 0, s.out_w || 0), soc = s.soc, out = s.out_w || 0;
  if (out > 2200) tip("alert", "peak", "Майже межа інвертора", `Зараз ${out} Вт при максимумі 2400 Вт. Вимкніть щось потужне.`);
  else if (peak > 1900) tip("warn", "peak", `Був пік ${Math.round(peak)} Вт`, "За добу навантаження підходило до межі 2400 Вт.");
  if (!d.grid && soc <= 15) tip("alert", "battery", `Заряд ${Math.round(soc)}%`, "Світла немає, а заряду мало. Залиште тільки найважливіше.");
  if (s.temp != null) {
    if (s.temp >= 45) tip("alert", "temp", `Гаряче: ${s.temp} °C`, "Поставте станцію в прохолодне місце, зменште навантаження.");
    else if (s.temp >= 40) tip("warn", "temp", `Тепло: ${s.temp} °C`, "Не накривайте станцію й не ставте біля опалення.");
    else if (s.temp <= 3 && d.charging) tip("warn", "temp", `Холодно для зарядки: ${s.temp} °C`, "LiFePO4 не варто заряджати на морозі.");
  }
  const calibAge = h.lastCalibTs ? (now - h.lastCalibTs) / 86400 : null;
  if (calibAge == null || calibAge > 30) tip(calibAge == null ? "info" : "warn", "calib", calibAge == null ? "Варто відкалібрувати" : `Калібрування ${Math.round(calibAge)} дн тому`,
    "Раз на місяць розрядіть станцію до 15–20% і одразу зарядіть до 100% без перерви — так BMS уточнює відсотки.");
  if (d.grid && d.charging && soc < 97 && s.ac_limit != null && nxt) {
    const need = (100 - soc) / 100 * cap / 0.92, left = (nxt[0] - Date.now()) / 3600000, half = need / 900;
    if (s.ac_limit > 60 && left > half * 1.5 + 1) tip("info", "slow", "Можна заряджати повільніше", `До відключення о ${hhmm(nxt[0])} ще ${Math.round(left)} год — на половинній потужності встигне.`, { key: "charge_limit", value: 50, label: "Зарядка 50%" });
    else if (s.ac_limit < 100 && left < need / Math.max(200, 1800 * s.ac_limit / 100)) tip("warn", "fast", "Не встигне зарядитись", `Відключення о ${hhmm(nxt[0])}, а на ${s.ac_limit}% потужності до 100% не дійде.`, { key: "charge_limit", value: 100, label: "Зарядка 100%" });
  }
  if (!tips.length || tips.every(t => t.level === "info")) tip("ok", "ok", "Батарея в порядку", "Температура, навантаження й заряд у нормі.");
  const ord = { alert: 0, warn: 1, info: 2, ok: 3 };
  tips.sort((a, b) => ord[a.level] - ord[b.level]);
  return { tips, stats: { cycles: Math.round(h.dischargedPct || 0) / 100, peak_24h: Math.round(peak), temp_max_ever: h.maxTemp ?? null } };
}

// ---------- реєстрація нового користувача (програма передає ключ сесії Wonderfree, НЕ пароль) ----------
async function register(env, b, base) {
  if (!b.tokens || !b.tokens.refresh) return [400, { error: "немає ключа сесії" }];
  const tmp = { id: "tmp", tokens: { access: b.tokens.access, access_exp: sec(b.tokens.access_exp), refresh: b.tokens.refresh, refresh_exp: sec(b.tokens.refresh_exp) } };
  // перевіряємо, що ключ справжній, і знаходимо станцію (якщо ключ доступу довелось оновити — нова пара вже в tmp.tokens)
  const j = await cloud(env, tmp, "/v2/binding/enduserapi/userDeviceList", { params: { page: 1, pageSize: 50, isAssociation: false } }).catch(() => ({}));
  const list = (j.data && j.data.list) || [];
  if (!list.length) return [401, { error: "не вдалося перевірити вхід у Wonderfree або в акаунті немає станцій" }];
  const want = b.device && b.device.dk;
  const x = list.find(v => v.deviceKey === want) || list.find(v => /P2001|P5000|P1201|P800|OUKITEL/i.test(v.productName || v.deviceName || "")) || list[0];
  const dev = { pk: x.productKey, dk: x.deviceKey, name: x.deviceName, model: x.productName };
  const wfUid = x.uid || null;   // ідентифікатор акаунта Wonderfree
  const ex = await env.DB.prepare("SELECT * FROM users WHERE dk=?").bind(dev.dk).first();
  let u;
  if (ex) {
    u = rowToUser(ex);
    // повторний вхід дозволяємо лише тому самому акаунту Wonderfree або з чинним ключем цього користувача
    const sameAccount = !!(u.wf_uid && wfUid && u.wf_uid === wfUid), sameKey = !!(b.key && b.key === u.key);
    if (!sameAccount && !sameKey) return [409, { error: u.wf_uid ? "ця станція вже підключена до сервера з іншого акаунта Wonderfree"
                                                                  : "ця станція вже підключена до сервера; увійдіть з того Mac, де її підключали" }];
    u.wf_uid = u.wf_uid || wfUid;
    u.tokens = tmp.tokens; u.device = dev; delete u.auth_lost; delete u.hf_ts;
    if (b.config) u.config = { ...(u.config || {}), ...b.config };
    await saveFields(env, u, ["wf_uid", "tokens", "device", "auth_lost", "hf_ts", "config"]);
  } else {
    const n = await env.DB.prepare("SELECT COUNT(*) c FROM users").first();
    if (n.c >= MAX_USERS) return [503, { error: "спільний сервер заповнений" }];
    u = { id: "u_" + rid(8), key: rid(32), tokens: tmp.tokens, device: dev, wf_uid: wfUid, config: b.config || {}, tg_code: rid(6).replace(/[-_]/g, "x") };
    const { id, key, ...data } = u;
    await env.DB.prepare("INSERT INTO users (id, key, dk, data, created) VALUES (?, ?, ?, ?, ?)").bind(id, key, dev.dk, JSON.stringify(data), Math.floor(Date.now() / 1000)).run();
  }
  if (!u.tg_code) { u.tg_code = rid(6).replace(/[-_]/g, "x"); await saveFields(env, u, ["tg_code"]); }
  return [200, { ok: true, key: u.key, device: dev, tg_link: tgLink(u), phone_link: phoneLink(base, u) }];
}

// ---------- HTTP ----------
const J = (o, status = 200) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" } });
const cookieKey = req => decodeURIComponent(((req.headers.get("Cookie") || "").match(/(?:^|;\s*)pk=([^;]+)/) || [])[1] || "");
const WEB_PATCH = `<style>html,body{width:auto!important;height:auto!important;min-height:100%;overflow-x:hidden!important;overflow-y:auto!important;background:#05060d!important}
body{max-width:380px;margin:0 auto!important;min-height:878px}#bQuit,#bSet,#bAcc,#bDash{display:none!important}footer{justify-content:center}
footer::after{content:"патужно · хмара";font-size:10px;letter-spacing:.2em;color:#5d6789;text-transform:uppercase}</style>
<meta name="viewport" content="width=390,viewport-fit=cover"><meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent"><meta name="apple-mobile-web-app-title" content="патужно">
<link rel="apple-touch-icon" href="/assets/logo.png"><script>window.WEB=1</script>`;

export default {
  async fetch(req, env, ctx) {
    initEnv(env);
    const url = new URL(req.url), base = `${url.protocol}//${url.host}`;
    await ensureSchema(env);
    if (env.TG_SECRET && url.pathname === `/tg/${env.TG_SECRET}` && req.method === "POST") return handleTelegram(env, req, url);
    if (url.pathname === "/assets/logo.png") return new Response(LOGO, { headers: { "Content-Type": "image/png", "Cache-Control": "public, max-age=86400" } });
    if (url.pathname === "/api/register" && req.method === "POST") { const [code, o] = await register(env, await req.json().catch(() => ({})), base); return J(o, code); }
    const qk = url.searchParams.get("k");
    if (url.pathname === "/" && qk && await userByKey(env, qk))
      return new Response(null, { status: 302, headers: { Location: "/", "Set-Cookie": `pk=${encodeURIComponent(qk)}; Path=/; Max-Age=31536000; HttpOnly; Secure; SameSite=Lax` } });
    const u = await userByKey(env, req.headers.get("X-Key") || cookieKey(req));
    if (!u) {
      if (url.pathname === "/") return new Response("патужно · хмарний сервер працює. Відкрийте посилання з Telegram-бота (/app) або з програми на Mac.", { headers: { "Content-Type": "text/plain; charset=utf-8" } });
      return J({ error: "unauthorized" }, 401);
    }
    try {
      if (url.pathname === "/" || url.pathname === "/panel") return new Response(PANEL.replace("</head>", WEB_PATCH + "</head>"), { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" } });
      if (url.pathname === "/api/state") return J(await computeState(env, u));
      if (url.pathname === "/api/me") {
        if (!u.tg_code) { u.tg_code = rid(6).replace(/[-_]/g, "x"); await saveFields(env, u, ["tg_code"]); }
        return J({ device: u.device, tg_bound: !!u.tg_chat, tg_link: tgLink(u), phone_link: phoneLink(base, u), need_login: !!u.auth_lost });
      }
      if (url.pathname === "/api/live")
        return J({ ...(u.live || {}), device: u.device, need_login: !u.tokens || !!u.auth_lost, last_error: u.last_error || null });
      if (url.pathname === "/api/history") {
        const since = Number(url.searchParams.get("since") || 0);
        const r = await env.DB.prepare("SELECT ts, soc, out, inw, temp FROM samples2 WHERE uid=? AND ts > ? ORDER BY ts LIMIT 50000").bind(u.id, since).all();
        return J({ samples: (r.results || []).map(x => [x.ts, x.soc, x.out, x.inw, x.temp]) });
      }
      if (url.pathname === "/api/control" && req.method === "POST") {
        const b = await req.json();
        const code = { ac: "ac_switch", usb: "usb_switch", dc: "dc_switch", charge_limit: "ac_charging_limit" }[b.key];
        if (!code) return J({ error: "bad control" }, 400);
        const ok = await send(env, u, { [code]: b.key === "charge_limit" ? String(Math.max(3, Math.min(100, Math.round(Number(b.value))))) : (b.value ? "true" : "false") });
        if (ok) {
          u.live = u.live || { state: {} };
          u.live.state[{ ac: "ac_on", usb: "usb_on", dc: "dc_on", charge_limit: "ac_limit" }[b.key]] = b.key === "charge_limit" ? Number(b.value) : !!b.value;
          await saveFields(env, u, ["live", "device"]);
          ctx.waitUntil((async () => { await new Promise(r => setTimeout(r, 2500)); try { const f = await userById(env, u.id); const { s, newest } = await readOnce(env, f); f.live = { ...(f.live || {}), state: s, updated: Math.floor(Math.max(newest || 0, Date.now() / 1000 - 60)), station_ts: newest }; await saveTick(env, f); } catch (e) {} })());
        }
        return J({ ok }, ok ? 200 : 502);
      }
      if (url.pathname === "/api/config" && req.method === "POST") {
        const b = await req.json(), c = u.config || {};
        for (const k of ["group", "region_id", "dso_id", "capacity_wh", "reserve_percent", "night", "weekend_days", "fallback_watts", "model", "inverter_efficiency", "charge_efficiency", "max_ac_charge_w"])
          if (b[k] !== undefined && b[k] !== null) c[k] = b[k];
        u.config = c; await saveFields(env, u, ["config"]);
        return J({ ok: true, config: c });
      }
      if (url.pathname === "/api/login" && req.method === "POST") {   // новий ключ сесії для цього ж користувача
        const b = await req.json();
        if (!b.refresh) return J({ error: "no token" }, 400);
        u.tokens = { access: b.access || null, access_exp: sec(b.access_exp), refresh: b.refresh, refresh_exp: sec(b.refresh_exp) };
        delete u.auth_lost; delete u.hf_ts; delete u.device;
        await saveFields(env, u, ["tokens", "auth_lost", "hf_ts", "device"]);
        return J({ ok: true });
      }
      if (url.pathname === "/api/tick" && req.method === "POST") {
        const { s } = await readOnce(env, u);
        u.live = { state: s, updated: Math.floor(Date.now() / 1000), online: true };
        if (await send(env, u, { high_frequency_reporting: "3" })) u.hf_ts = Date.now() / 1000;
        await saveFields(env, u, ["live", "hf_ts", "device"]);
        return J({ ok: true, state: s, device: u.device });
      }
      if (url.pathname === "/api/unregister" && req.method === "POST") {   // вихід з акаунта в програмі — прибираємо все про користувача
        await env.DB.batch([env.DB.prepare("DELETE FROM samples2 WHERE uid=?").bind(u.id), env.DB.prepare("DELETE FROM hourly WHERE uid=?").bind(u.id), env.DB.prepare("DELETE FROM users WHERE id=?").bind(u.id)]);
        return J({ ok: true });
      }
    } catch (e) {
      await saveFields(env, u, ["auth_lost", "device"]).catch(() => {});
      return J({ error: String(e.message || e) }, String(e.message) === "need_login" ? 409 : 500);
    }
    return J({ error: "not found" }, 404);
  },
  async scheduled(event, env, ctx) { initEnv(env); ctx.waitUntil(tick(env).catch(() => {})); },
};
