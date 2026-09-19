'use strict';
/*
 repair-session.cjs —— 会话手术：给被内容审核打死的会话日志追加「剪过的替代事件」

 做法照 @deepseek-ai/dsh-compaction-tool-result-pruner（读的是它的 lib/index.js）：
   原 tool/result 一个字节不动，只在日志末尾追加两条事件：
     1) compaction/prune —— 记账（引用被顶掉的 seq）
     2) tool/result      —— 内容换成「头 4096 + 标记 + 尾 1024」，并把
                            surfaceOp:{op:"replace",startSeq,endSeq} 与 sourceEventSeqs:[seq]
                            放在**事件顶层**（isSurfaceEvent 读的是顶层字段）
   会话恢复时按表面规则重放：替代事件顶掉原事件，模型看到的是剪过的版本，原文仍在日志里。

 用法：
   node repair-session.cjs --session <id>                演练：只算不做，预案写到**脚本自己所在目录**下的 surgery\
   node repair-session.cjs --session <id> --apply        动真格：先备份，再往真日志追加
   node repair-session.cjs --file <副本.zstd> --apply    在同一份副本上练手（不出工作区）
   node repair-session.cjs --surface <日志.jsonl> <输出> 按表面规则重建「模型看得见的内容」
*/
const fs = require('fs'), zlib = require('zlib'), path = require('path'), os = require('os');

const HEAD = 4096, TAIL = 1024, THRESHOLD = 8192;
const MARKER = '\n\n[... tool result middle pruned ...]\n\n';
const SURFACE_TYPES = new Set(['system/message', 'user/message', 'assistant/message', 'tool/result']);
const SURGERY = path.join(__dirname, 'surgery');
// 会话目录按「工作区路径编码」命名（作者的叫 --D-dsh-workspace--，你的会不一样）—— 换台机器名字就不同，
// 所以这里扫所有工作区目录，不写死任何一个。
const SESSIONS_ROOT = path.join(os.homedir(), '.dsh', 'sessions');

const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);

function decodeFrames(buf) {
  const offs = [];
  for (let i = 0; i + 4 <= buf.length; i++) if (buf.subarray(i, i + 4).equals(MAGIC)) offs.push(i);
  const parts = [], fails = [];
  offs.forEach((s, i) => {
    const e = i + 1 < offs.length ? offs[i + 1] : buf.length;
    try { parts.push(zlib.zstdDecompressSync(buf.subarray(s, e))); } catch (err) { fails.push(s); }
  });
  return { text: Buffer.concat(parts).toString('utf8'), frames: offs.length, fails };
}

function sessionPath(id) {
  const roots = fs.existsSync(SESSIONS_ROOT)
    ? fs.readdirSync(SESSIONS_ROOT).map((d) => path.join(SESSIONS_ROOT, d))
        .filter((p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } })
    : [];
  for (const root of roots) {
    // ⚠️ 会话目录名有两种真实形态（2026-09-18 在发布方这台机器上实测：60 个里 35 个带 `session-` 前缀、
    //    25 个不带）—— 只认一种会让近一半会话「找不到」。id 传裸 uuid 或带前缀的都要认。
    const bare = id.startsWith('session-') ? id.slice('session-'.length) : id;
    const dir = fs.readdirSync(root).find((d) => d === 'session-' + bare || d === bare);
    if (!dir) continue;
    const file = path.join(root, dir, 'session.v3.jsonl.zstd');
    if (fs.existsSync(file)) return file;
  }
  throw new Error(`找不到会话 ${id}（扫过 ${roots.length} 个工作区目录：${SESSIONS_ROOT}）`);
}

function textOf(ev) {
  const blocks = ev?.data?.message?.content?.[0]?.content ?? [];
  return blocks.filter((b) => b.type === 'text').map((b) => b.text).join('');
}

function pruneText(t) {
  const pts = Array.from(t);
  if (pts.length <= THRESHOLD) return t;
  return pts.slice(0, HEAD).join('') + MARKER + pts.slice(pts.length - TAIL).join('');
}

function buildPlan(events) {
  const maxSeq = events.reduce((m, e) => Math.max(m, e.seq ?? 0), 0);
  const already = new Set(events.filter((e) => e.surfaceOp).flatMap((e) => e.sourceEventSeqs || []));
  const targets = events.filter((e) => e.type === 'tool/result' && !already.has(e.seq) && Array.from(textOf(e)).length > THRESHOLD);
  const out = [];
  let seq = maxSeq;
  for (const ev of targets) {
    const block = ev.data.message.content[0];
    const content = block.content.map((b) => (b.type === 'text' ? { ...b, text: pruneText(b.text) } : b));
    const message = { ...ev.data.message, content: [{ ...block, content }] };
    const chars = Array.from(textOf(ev)).length;
    seq += 1;
    out.push({
      type: 'compaction/prune', seq, time: Date.now(),
      data: { shadowedRange: { start: ev.seq, end: ev.seq }, shadowedSeqs: [ev.seq], shadowedTokenCount: Math.round(chars / 2) },
    });
    seq += 1;
    out.push({
      type: 'tool/result', seq, time: Date.now() + 1,
      data: { ...ev.data, message },
      surfaceOp: { op: 'replace', startSeq: ev.seq, endSeq: ev.seq },
      sourceEventSeqs: [ev.seq],
    });
  }
  return { targets, out, maxSeq };
}

function buildSurface(events) {
  const bySeq = new Map(events.map((e) => [e.seq, e]));
  let list = [];
  for (const e of events) {
    if (!SURFACE_TYPES.has(e.type)) continue;
    if (e.surfaceOp && e.surfaceOp.op === 'replace') {
      const { startSeq, endSeq } = e.surfaceOp;
      const idx = list.indexOf(startSeq);
      list = list.filter((s) => s < startSeq || s > endSeq);
      if (idx >= 0) list.splice(idx, 0, e.seq); else list.push(e.seq);
    } else list.push(e.seq);
  }
  return list.map((s) => {
    const e = bySeq.get(s);
    if (!e) return '';
    if (e.type === 'tool/result') return e.data.message.content.map((b) => (b.content || []).map((x) => x.text || '').join('')).join('\n');
    const c = e.data.content ?? e.data.message?.content;
    if (Array.isArray(c)) return c.map((b) => b.text || '').join('\n');
    return String(c ?? '');
  }).join('\n\n');
}

function main() {
  const argv = process.argv.slice(2);
  const get = (k) => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : undefined; };
  const apply = argv.includes('--apply');

  if (argv[0] === '--surface') {
    const lines = fs.readFileSync(argv[1], 'utf8').split('\n').filter(Boolean);
    const txt = buildSurface(lines.map((l) => JSON.parse(l)));
    fs.writeFileSync(argv[2], txt, 'utf8');
    console.log(`surface -> ${argv[2]}  chars=${txt.length}`);
    return;
  }

  const file = get('--file') || sessionPath(get('--session'));
  const buf = fs.readFileSync(file);
  const { text, frames, fails } = decodeFrames(buf);
  const lines = text.split('\n').filter(Boolean);
  const events = lines.map((l) => JSON.parse(l));
  const { targets, out } = buildPlan(events);

  console.log(`日志 ${file}`);
  console.log(`  ${buf.length} B / ${frames} 帧 / ${fails.length} 帧解不开 / ${events.length} 条事件 / 最大 seq=${events.reduce((m, e) => Math.max(m, e.seq ?? 0), 0)}`);
  console.log(`  待替代的超阈值工具结果：${targets.length} 条`);
  targets.forEach((t) => {
    const chars = Array.from(textOf(t)).length;
    console.log(`    seq=${t.seq} chars=${chars} -> ${HEAD}+${Array.from(MARKER).length}+${TAIL}`);
  });
  if (!targets.length) { console.log('  没有要动的目标，收工。'); return; }

  fs.mkdirSync(SURGERY, { recursive: true });
  const planPath = path.join(SURGERY, `plan-${path.basename(file)}.jsonl`);
  fs.writeFileSync(planPath, out.map((e) => JSON.stringify(e)).join('\n') + '\n', 'utf8');
  console.log(`  预案 -> ${planPath}（含剪过的正文，读它要当敏感内容处理）`);

  if (!apply) { console.log('  （演练模式，没碰日志；要动真格加 --apply）'); return; }

  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const backup = path.join(SURGERY, `backup-${path.basename(file)}-${stamp}`);
  fs.copyFileSync(file, backup);
  console.log(`  备份 -> ${backup}`);

  const appendBuf = zlib.zstdCompressSync(Buffer.from(out.map((e) => JSON.stringify(e)).join('\n') + '\n', 'utf8'));
  fs.appendFileSync(file, appendBuf);
  console.log(`  已追加 ${out.length} 条事件（${appendBuf.length} B 新帧）`);

  const after = decodeFrames(fs.readFileSync(file));
  console.log(`  复核：${after.frames} 帧 / ${after.fails.length} 帧解不开 / ${after.text.split('\n').filter(Boolean).length} 条事件`);
  const surface = buildSurface(after.text.split('\n').filter(Boolean).map((l) => JSON.parse(l)));
  const surfacePath = path.join(SURGERY, `surface-${path.basename(file)}.txt`);
  fs.writeFileSync(surfacePath, surface, 'utf8');
  console.log(`  表面重建 -> ${surfacePath}  chars=${surface.length}`);
  // 提示里的 preflight.js 用「与本脚本同目录」的写法：写死工作区路径的话，只装了这个包的人那边是空的
  console.log('  下一步：预检这份表面（node ' + path.join(__dirname, 'preflight.js') + ' ' + surfacePath + '），200 才算救活。');
}

main();
