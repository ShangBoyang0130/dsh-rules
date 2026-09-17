'use strict';
/*
 verify-surgery.cjs —— 手术后的核对（只输出数字与类型，从不回显正文）

 查四件事：
   1) 日志能不能正常解开：帧数 / 事件数 / 最大 seq
   2) 追加进来的是哪几条、什么类型、`surfaceOp` 与 `sourceEventSeqs` 对不对
   3) **只追加保证**：新文件的前 N 字节与备份**逐字节相同**（证明原文没被动过）
   4) 被顶掉的原事件**还在不在日志里**（这条只抽查**头部前 200 字符是否可检索**，
      不是全文比对 —— 全文是否完好靠 3) 的逐字节前缀对比来保证）

 用法：
   node verify-surgery.cjs <会话id 或 .zstd 路径> <备份路径> [被顶掉的 seq]
   省略 seq 时，自动从追加事件的 `sourceEventSeqs` 里取。
   例：node verify-surgery.cjs 124814ee "<手术目录>\surgery\124814ee-real-before.zstd"
（会话 id 传裸 uuid 或带 `session-` 前缀都行；备份路径就是 repair-session.cjs 打印的那个）

 配合 `repair-session.cjs` 用：它手术前会自动备份到**它自己所在目录**下的 `surgery\`，
把那个备份路径传进来即可。
*/
const fs = require('fs'), zlib = require('zlib'), path = require('path'), os = require('os');

const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
const MARKER = '\n\n[... tool result middle pruned ...]\n\n';
const SESSIONS_ROOT = path.join(os.homedir(), '.dsh', 'sessions');

function decode(file) {
  const buf = fs.readFileSync(file);
  const offs = [];
  for (let i = 0; i + 4 <= buf.length; i++) if (buf.subarray(i, i + 4).equals(MAGIC)) offs.push(i);
  const parts = [], fails = [];
  offs.forEach((s, i) => {
    const e = i + 1 < offs.length ? offs[i + 1] : buf.length;
    try { parts.push(zlib.zstdDecompressSync(buf.subarray(s, e))); } catch { fails.push(s); }
  });
  return {
    buf, frames: offs.length, fails: fails.length,
    events: Buffer.concat(parts).toString('utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)),
  };
}

// 会话目录按工作区路径编码命名，换台机器名字就不同 —— 扫，不写死
function resolve(arg) {
  if (fs.existsSync(arg)) return arg;
  const roots = fs.existsSync(SESSIONS_ROOT)
    ? fs.readdirSync(SESSIONS_ROOT).map((d) => path.join(SESSIONS_ROOT, d))
        .filter((p) => { try { return fs.statSync(p).isDirectory(); } catch { return false; } })
    : [];
  for (const root of roots) {
    // 与 repair-session.cjs 同一判据：`session-<uuid>` 与裸 `<uuid>` 两种目录名都真实存在
    const bare = arg.startsWith('session-') ? arg.slice('session-'.length) : arg;
    const dir = fs.readdirSync(root).find((d) => d === 'session-' + bare || d === bare);
    if (!dir) continue;
    const file = path.join(root, dir, 'session.v3.jsonl.zstd');
    if (fs.existsSync(file)) return file;
  }
  throw new Error(`找不到会话或文件：${arg}`);
}

const [target, backupPath, seqArg] = process.argv.slice(2);
if (!target || !backupPath) {
  console.log('用法: node verify-surgery.cjs <会话id 或 .zstd 路径> <备份路径> [被顶掉的 seq]');
  process.exit(2);
}

const textOf = (e) => (e?.data?.message?.content?.[0]?.content ?? []).filter((b) => b.type === 'text').map((b) => b.text).join('');

const realPath = resolve(target);
const real = decode(realPath);
const backup = decode(backupPath);
const backupMax = backup.events.reduce((m, e) => Math.max(m, e.seq ?? 0), 0);
const appended = real.events.filter((e) => (e.seq ?? 0) > backupMax);
const shadowed = seqArg ? Number(seqArg)
  : (appended.find((e) => e.sourceEventSeqs?.length)?.sourceEventSeqs ?? [])[0];
const orig = real.events.find((e) => e.seq === shadowed);

console.log(`真日志：${realPath}`);
console.log(`  ${real.buf.length} B / ${real.frames} 帧 / ${real.fails} 帧解不开 / ${real.events.length} 条事件 / 最大 seq=${real.events.reduce((m, e) => Math.max(m, e.seq ?? 0), 0)}`);
console.log(`备份  ：${backup.buf.length} B / ${backup.frames} 帧 / ${backup.events.length} 条事件 → 追加了 ${appended.length} 条`);
const appendOnly = real.buf.subarray(0, backup.buf.length).equals(backup.buf);
console.log(`① 只追加保证：前 ${backup.buf.length} 字节与备份逐字节相同 = ${appendOnly}${appendOnly ? ' ✅' : ' ❌（原文被动过！）'}`);
for (const e of appended) {
  const len = e.type === 'tool/result' ? textOf(e).length : JSON.stringify(e.data).length;
  console.log(`② 追加事件：seq=${e.seq} type=${e.type} surfaceOp=${JSON.stringify(e.surfaceOp ?? null)} sourceEventSeqs=${JSON.stringify(e.sourceEventSeqs ?? null)} 文本长度=${len}`);
}
if (orig) {
  const origText = Array.from(textOf(orig));
  const head = origText.slice(0, 4096).join('');
  const allText = real.events.map(textOf).join('\n');
  console.log(`③ 被顶掉的原事件：seq=${shadowed} 原文本 ${origText.length} 字符（仍在日志里；配合 ① 的逐字节只追加保证 ⇒ 原文完整、可回放）`);
  console.log(`   抽查：头部前 200 字符可检索 = ${allText.includes(head.slice(0, 200))}`);
  const repl = appended.filter((e) => e.type === 'tool/result').map((e) => textOf(e));
  console.log(`④ 替换件：带剪枝标记 = ${repl.some((t) => t.includes(MARKER.trim()))}，长度 = ${repl.map((t) => t.length).join(',') || '（无）'}`);
} else {
  console.log(`③ 没找到 seq=${shadowed} 的原事件 —— 传入的 seq 可能不对`);
}
