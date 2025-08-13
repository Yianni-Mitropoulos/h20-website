/**
 * Gmail → Proton contacts, CLEAN + RESUMABLE across multiple runs.
 * Run buildBestProtonContactsResumable repeatedly until it logs "SCANS COMPLETE".
 * Final outputs: proton-cleaned.vcf and proton-cleaned.csv in your Drive.
 */
function buildBestProtonContactsResumable() {
  const START_TIME = Date.now();
  const RUNTIME_LIMIT_SEC = 280; // stop early to avoid 6-min hard limit
  const COUNTRY_CODE = '+61';    // ← change if not AU
  const BATCH_SIZE = 200;        // Gmail threads per fetch
  const THREADS_TO_TRAVERSE_PER_RUN = 3000; // soft cap per run per query
  const MIN_PHONE_DIGITS = 8;

  const EXCLUDE_EMAIL_PATTERNS = [
    /(^|\W)(no[-_. ]?reply|do[-_. ]?not[-_. ]?reply|donotreply)(@|$)/i,
    /(mailer-daemon|postmaster|bounce|bounces|delivery|failure)/i,
    /(noreply\+|noreply-)/i,
    /(^|\W)(notifications?|notify|auto(mail|mated)?|robot|daemon)(@|$)/i,
    /(unsubscribe|newsletter|listserv|list-manager)/i
  ];

  // ---- Load cache (progress + emailStats + processed thread IDs) ----
  const cache = loadCache();

  // ---- Scan Sent (collect recipients) ----
  const sentStatus = scanQueryChunked({
    label: 'sent',
    query: 'in:sent',
    mode: 'sent',
    cache,
    START_TIME,
    RUNTIME_LIMIT_SEC,
    BATCH_SIZE,
    THREADS_TO_TRAVERSE_PER_RUN,
    EXCLUDE_EMAIL_PATTERNS
  });

  // ---- Scan Inbox/All (collect senders to you) ----
  const recvStatus = scanQueryChunked({
    label: 'recv',
    query: 'in:inbox OR in:all',
    mode: 'recv',
    cache,
    START_TIME,
    RUNTIME_LIMIT_SEC,
    BATCH_SIZE,
    THREADS_TO_TRAVERSE_PER_RUN,
    EXCLUDE_EMAIL_PATTERNS
  });

  // Save progress so far (even if we didn’t finish in this run)
  saveCache(cache);

  // If time is nearly up, exit early; you can Run again to resume
  if (elapsed(START_TIME) > RUNTIME_LIMIT_SEC - 5) {
    Logger.log('Time’s up for this run — progress saved. Run again to continue.');
    return;
  }

  // If both scans are done, build outputs once
  if (sentStatus.done && recvStatus.done) {
    Logger.log('SCANS COMPLETE — building cleaned, merged outputs...');
    buildOutputsFromCache(cache, { COUNTRY_CODE, MIN_PHONE_DIGITS });
    Logger.log('Done. Files written: proton-cleaned.vcf, proton-cleaned.csv');
  } else {
    Logger.log('Not finished yet. Run again to continue scanning.');
  }
}

/* -------------------- Resumable scanning -------------------- */

function scanQueryChunked(opts) {
  const {
    label, query, mode, cache,
    START_TIME, RUNTIME_LIMIT_SEC,
    BATCH_SIZE, THREADS_TO_TRAVERSE_PER_RUN,
    EXCLUDE_EMAIL_PATTERNS
  } = opts;

  const me = Session.getActiveUser().getEmail().toLowerCase();
  let start = cache.progress[mode + 'Start'] || 0;
  let traversed = 0;
  let processedNew = 0;

  while (traversed < THREADS_TO_TRAVERSE_PER_RUN && elapsed(START_TIME) < RUNTIME_LIMIT_SEC) {
    const threads = GmailApp.search(query, start, BATCH_SIZE);
    if (!threads.length) {
      cache.progress[mode + 'Start'] = 0;
      cache.flags[mode + 'Done'] = true;
      Logger.log(`Finished ${label} scan: no more threads.`);
      return { done: true };
    }

    for (const t of threads) {
      const tid = t.getId();
      if (mode === 'sent') {
        if (cache.processedSentThreadIds.has(tid)) continue;
      } else {
        if (cache.processedRecvThreadIds.has(tid)) continue;
      }

      // Process messages in this thread
      const msgs = t.getMessages();
      for (const m of msgs) {
        if (m.isDraft()) continue;
        if (mode === 'sent') {
          const from = (m.getFrom() || '').toLowerCase();
          if (from.includes(me)) {
            [m.getTo(), m.getCc(), m.getBcc()].forEach(h =>
              forEachAddr(h, (email, name) => {
                const e = email.toLowerCase();
                if (isExcludedEmail(e, EXCLUDE_EMAIL_PATTERNS)) return;
                const stat = ensureEmailStat(cache, e);
                stat.sent++;
                if (name) stat.names.add(name);
              })
            );
          }
        } else {
          const recipientBlob = ((m.getTo() || '') + ',' + (m.getCc() || '') + ',' + (m.getBcc() || '')).toLowerCase();
          if (recipientBlob.includes(me)) {
            forEachAddr(m.getFrom(), (email, name) => {
              const e = email.toLowerCase();
              if (isExcludedEmail(e, EXCLUDE_EMAIL_PATTERNS)) return;
              const stat = ensureEmailStat(cache, e);
              stat.recv++;
              if (name) stat.names.add(name);
            });
          }
        }
      }

      if (mode === 'sent') cache.processedSentThreadIds.add(tid);
      else cache.processedRecvThreadIds.add(tid);
      processedNew++;

      if (elapsed(START_TIME) > RUNTIME_LIMIT_SEC - 5) break;
    }

    traversed += BATCH_SIZE;
    start += BATCH_SIZE;
    cache.progress[mode + 'Start'] = start;

    if (elapsed(START_TIME) > RUNTIME_LIMIT_SEC - 5) {
      Logger.log(`Stopping ${label} early to respect runtime. New threads processed this run: ${processedNew}`);
      return { done: false };
    }
  }

  Logger.log(`${label}: traversed ${traversed} threads this run, newly processed: ${processedNew}`);
  return { done: false };
}

/* -------------------- Build outputs once both scans are done -------------------- */

function buildOutputsFromCache(cache, { COUNTRY_CODE, MIN_PHONE_DIGITS }) {
  // Inclusion rule: include if sent>=2 OR (sent>=1 AND recv>=1)
  const nodes = [];
  const emailToNode = new Map();
  const phoneToNode = new Map();
  const nameToNode  = new Map();

  function newNode() {
    const id = nodes.length;
    nodes.push({ names: new Set(), first:'', last:'', emails:new Set(), phones:new Set() });
    return id;
  }

  // 1) From emailStats (interactions)
  for (const [emailLower, statObj] of cache.emailStats.entries()) {
    const sent = statObj.sent || 0;
    const recv = statObj.recv || 0;
    const include = sent >= 2 || (sent >= 1 && recv >= 1);
    if (!include) continue;

    const id = newNode();
    nodes[id].emails.add(emailLower);

    let best = '';
    statObj.names.forEach(n => { if (n && n.length > best.length) best = n; });
    if (!best) best = emailLower;

    best = titleCaseName(best);
    nodes[id].names.add(best);
    const { first, last } = splitFirstLast(best);
    if (first) nodes[id].first = first;
    if (last)  nodes[id].last  = last;
    emailToNode.set(emailLower, id);
  }

  // 2) Enrich from Google Contacts if allowed
  try {
    const gc = ContactsApp.getContacts();
    for (const c of gc) {
      const id = newNode();
      const first = (c.getGivenName() || '').trim();
      const last  = (c.getFamilyName() || '').trim();
      const display = (c.getFullName() || '').trim();

      if (display) nodes[id].names.add(titleCaseName(display));
      if (first) nodes[id].first = titleCaseName(first);
      if (last)  nodes[id].last  = titleCaseName(last);

      for (const e of c.getEmails()) {
        const a = (e.getAddress() || '').trim().toLowerCase();
        if (a && !isExcludedEmail(a)) nodes[id].emails.add(a);
      }
      const normalized = new Set();
      for (const p of c.getPhones()) {
        const raw = (p.getPhoneNumber() || '').trim();
        const norm = normalizePhone(raw, COUNTRY_CODE, MIN_PHONE_DIGITS);
        if (norm && countDigits(norm) >= MIN_PHONE_DIGITS) normalized.add(norm);
      }
      nodes[id].phones = normalized;
    }
  } catch (e) {
    Logger.log('ContactsApp not available/allowed. Continuing without it.');
  }

  // --- Union-Find merge by email/phone/identical First+Last ---
  const parent = Array.from({ length: nodes.length }, (_, i) => i);
  function find(i){ return parent[i] === i ? i : (parent[i] = find(parent[i])); }
  function mergeInto(to, from){
    nodes[from].names.forEach(n => nodes[to].names.add(n));
    if (!nodes[to].first && nodes[from].first) nodes[to].first = nodes[from].first;
    if (!nodes[to].last  && nodes[from].last ) nodes[to].last  = nodes[from].last;
    nodes[from].emails.forEach(e => nodes[to].emails.add(e));
    nodes[from].phones.forEach(p => nodes[to].phones.add(p));
  }
  function union(a,b){
    a = find(a); b = find(b);
    if (a === b) return a;
    const score = n => n.emails.size + n.phones.size + n.names.size + (n.first?1:0) + (n.last?1:0);
    const to = score(nodes[a]) >= score(nodes[b]) ? a : b;
    const from = to === a ? b : a;
    parent[from] = to;
    mergeInto(to, from);
    return to;
  }

  // Index & merge
  for (let i = 0; i < nodes.length; i++) {
    // Phones: re-normalize defensively
    const normPhones = new Set();
    for (const p of nodes[i].phones) {
      const np = normalizePhone(p, COUNTRY_CODE, MIN_PHONE_DIGITS);
      if (np && countDigits(np) >= MIN_PHONE_DIGITS) normPhones.add(np);
    }
    nodes[i].phones = normPhones;

    for (const e of nodes[i].emails) {
      if (emailToNode.has(e)) union(i, emailToNode.get(e));
      emailToNode.set(e, find(i));
    }
    for (const p of nodes[i].phones) {
      if (phoneToNode.has(p)) union(i, phoneToNode.get(p));
      phoneToNode.set(p, find(i));
    }
  }
  for (let i = 0; i < nodes.length; i++) {
    const n = nodes[i];
    if (!n.first || !n.last) continue;
    const key = `${n.first}|${n.last}`;
    if (nameToNode.has(key)) union(i, nameToNode.get(key));
    nameToNode.set(key, find(i));
  }

  // Collapse to unique
  const uniq = new Map();
  for (let i = 0; i < nodes.length; i++) {
    const r = find(i);
    if (!uniq.has(r)) uniq.set(r, { names:new Set(), first:'', last:'', emails:new Set(), phones:new Set() });
    const dst = uniq.get(r);
    nodes[i].names.forEach(n => dst.names.add(n));
    if (!dst.first && nodes[i].first) dst.first = nodes[i].first;
    if (!dst.last  && nodes[i].last ) dst.last  = nodes[i].last;
    nodes[i].emails.forEach(e => dst.emails.add(e));
    nodes[i].phones.forEach(p => dst.phones.add(p));
  }

  // Output VCF + CSV
  const vcfLines = [];
  const csvLines = [['First Name','Last Name','Display Name','Emails','Phones']];

  for (const rec of uniq.values()) {
    const emails = Array.from(rec.emails).sort();
    const phones = Array.from(rec.phones).sort();
    if (!emails.length && !phones.length) continue;

    const display = bestNameFor(rec) || (emails[0] || phones[0] || '');
    const fn = display || (emails[0] || '');

    vcfLines.push('BEGIN:VCARD');
    vcfLines.push('VERSION:3.0');
    vcfLines.push(`FN:${escVCard(fn)}`);
    if (rec.first || rec.last) vcfLines.push(`N:${escVCard(rec.last)};${escVCard(rec.first)};;;`);
    emails.forEach(e => vcfLines.push(`EMAIL;TYPE=INTERNET:${e}`));
    phones.forEach(p => vcfLines.push(`TEL;TYPE=CELL:${p}`));
    vcfLines.push('END:VCARD');

    // CSV: explicit, readable quoting (no template literal tricks)
    const csvRow = [
      rec.first || '',
      rec.last || '',
      fn,
      emails.join('; '),
      phones.join('; ')
    ].map(csvQuoteCell);

    csvLines.push(csvRow);
  }

  const vcf = vcfLines.join('\r\n') + '\r\n';
  const csv = csvLines.map(row => row.join(',')).join('\r\n') + '\r\n';

  DriveApp.createFile('proton-cleaned.vcf', vcf, MimeType.PLAIN_TEXT);
  DriveApp.createFile('proton-cleaned.csv', csv, MimeType.PLAIN_TEXT);
}

/* -------------------- Cache helpers (Drive JSON file) -------------------- */

const CACHE_FILE_NAME = 'ProtonExport.cache.json';

function loadCache() {
  const empty = {
    version: 1,
    progress: { sentStart: 0, recvStart: 0 },
    flags: { sentDone: false, recvDone: false },
    processedSentThreadIds: new Set(),
    processedRecvThreadIds: new Set(),
    emailStats: new Map()
  };

  const files = DriveApp.getFilesByName(CACHE_FILE_NAME);
  if (!files.hasNext()) return empty;

  const file = files.next();
  try {
    const obj = JSON.parse(file.getBlob().getDataAsString());

    const cache = Object.assign({}, empty);
    cache.progress = obj.progress || empty.progress;
    cache.flags = obj.flags || empty.flags;

    cache.processedSentThreadIds = new Set(obj.processedSentThreadIds || []);
    cache.processedRecvThreadIds = new Set(obj.processedRecvThreadIds || []);

    cache.emailStats = new Map();
    const rawStats = obj.emailStats || {};
    for (const [email, rec] of Object.entries(rawStats)) {
      const s = { sent: rec.sent || 0, recv: rec.recv || 0, names: new Set(rec.names || []) };
      cache.emailStats.set(email, s);
    }
    return cache;
  } catch (e) {
    Logger.log('Cache parse error, starting fresh: ' + e);
    return empty;
  }
}

function saveCache(cache) {
  const payload = {
    version: 1,
    progress: cache.progress,
    flags: cache.flags,
    processedSentThreadIds: Array.from(cache.processedSentThreadIds),
    processedRecvThreadIds: Array.from(cache.processedRecvThreadIds),
    emailStats: Object.fromEntries(
      Array.from(cache.emailStats.entries()).map(([email, rec]) => [email, {
        sent: rec.sent || 0,
        recv: rec.recv || 0,
        names: Array.from(rec.names || [])
      }])
    )
  };

  const files = DriveApp.getFilesByName(CACHE_FILE_NAME);
  if (files.hasNext()) {
    const f = files.next();
    f.setTrashed(false);
    f.setContent(JSON.stringify(payload));
  } else {
    DriveApp.createFile(CACHE_FILE_NAME, JSON.stringify(payload), MimeType.PLAIN_TEXT);
  }
}

/** Wipe progress & stats (use if you want to start over). */
function resetProtonExportCache() {
  const files = DriveApp.getFilesByName(CACHE_FILE_NAME);
  while (files.hasNext()) files.next().setTrashed(true);
  Logger.log('Cache deleted. Next run starts fresh.');
}

/* -------------------- Shared utilities -------------------- */

function ensureEmailStat(cache, emailLower) {
  if (!cache.emailStats.has(emailLower))
    cache.emailStats.set(emailLower, { sent: 0, recv: 0, names: new Set() });
  return cache.emailStats.get(emailLower);
}

function isExcludedEmail(email, patterns) {
  return patterns.some(re => re.test(email));
}

function forEachAddr(header, cb) {
  if (!header) return;
  const re = /(?:"?([^"<]*)"?\s*)?<([^>]+)>|([A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})/gi;
  let m;
  while ((m = re.exec(header)) !== null) {
    let name = '', email = '';
    if (m[2]) { name = (m[1] || '').trim().replace(/^"|"$/g, ''); email = m[2].trim(); }
    else { email = (m[3] || '').trim(); }
    if (email) cb(email, name);
  }
}

function titleCaseName(s) {
  const PARTICLES = ['de','da','dos','das','do','del','della','di','van','von','der','den','la','le','du'];
  const words = String(s || '').trim().split(/\s+/).filter(Boolean);
  const fixWord = (w, idx) => {
    let x = w.toLowerCase();
    x = x.replace(/^o['’]([a-z])/i, (_, c) => `O'${c.toUpperCase()}`);
    x = x.replace(/^mc([a-z])/, (_, c) => 'Mc' + c.toUpperCase());
    x = x.replace(/^mac([a-z])/, (_, c) => 'Mac' + c.toUpperCase());
    x = x.split('-').map(part => part ? part.charAt(0).toUpperCase() + part.slice(1) : part).join('-');
    if (idx > 0 && PARTICLES.includes(x.toLowerCase())) return x.toLowerCase();
    return x.charAt(0).toUpperCase() + x.slice(1);
  };
  return words.map((w,i)=>fixWord(w,i)).join(' ');
}

function splitFirstLast(display) {
  const s = (display || '').trim().replace(/\s+/g, ' ');
  if (!s) return { first: '', last: '' };
  const parts = s.split(' ');
  if (parts.length === 1) return { first: titleCaseName(parts[0]), last: '' };
  return { first: titleCaseName(parts[0]), last: titleCaseName(parts[parts.length - 1]) };
}

function escVCard(s) {
  return String(s)
    .replace(/\\/g, '\\\\')
    .replace(/\n/g, '\\n')
    .replace(/;/g, '\\;')
    .replace(/,/g, '\\,');
}

function normalizePhone(raw, CC, minDigits) {
  if (!raw) return '';
  let s = ('' + raw).trim();
  s = s.replace(/\s*(ext\.?|x|#)\s*\d+$/i, '');
  s = s.replace(/^00+/, '+');
  if (s.startsWith('+')) s = '+' + s.slice(1).replace(/\D+/g, '');
  else s = s.replace(/\D+/g, '');
  if (!s) return '';

  if (s.startsWith('+')) {
    const only = '+' + s.slice(1).replace(/\D+/g, '');
    return countDigits(only) >= (minDigits || 0) ? only : '';
  }
  const ccDigits = (CC || '').replace('+','');
  if (CC === '+61') {
    if (s.length >= 9 && s.startsWith('04')) return '+61' + s.slice(1);
    if (s.startsWith('0')) return '+61' + s.replace(/^0+/, '');
    if (/^(13\d{2}|1300\d{6}|1800\d{6})$/.test(s)) return '+61' + s;
    return '+' + ccDigits + s;
  }
  if (s.startsWith('0')) return '+' + ccDigits + s.replace(/^0+/, '');
  if (ccDigits && s.startsWith(ccDigits)) return '+' + s;
  const out = '+' + ccDigits + s;
  return countDigits(out) >= (minDigits || 0) ? out : '';
}

function countDigits(s) {
  const m = String(s).match(/\d/g);
  return m ? m.length : 0;
}

function bestNameFor(rec){
  if (rec.first || rec.last) return [rec.first, rec.last].filter(Boolean).join(' ');
  let best = ''; rec.names.forEach(n => { if (n.length > best.length) best = n; });
  return titleCaseName(best);
}

function elapsed(t0){ return (Date.now() - t0) / 1000; }

/* ---------- CSV quoting: safe and simple ---------- */
function csvQuoteCell(s) {
  s = String(s ?? '');
  if (/[",\n]/.test(s)) {
    // Escape double quotes by doubling them, then wrap in quotes
    s = '"' + s.replace(/"/g, '""') + '"';
  }
  return s;
}
