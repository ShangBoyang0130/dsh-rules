'use strict';
/*
 preflight.js —— 内容预检：要读进上下文的文本，先送一次服务端；HTTP 200 才读。

 为什么要有它：服务端内容审核退回（`Content Exists Risk` / HTTP 400）之后，那个对话当场就废了。
 所以**内容进门之前**先量一次。

 用法（全部只输出状态码/错误名/偏移，从不回显被检文字）：
   node preflight.js <文件...>                 预检这些文件拼起来的内容
   node preflight.js --window <文件> <a> <b>    只预检 [a,b)
   node preflight.js --cut <文件> <a> <b>       预检整份删掉 [a,b) 之后的内容
   node preflight.js --gap <文件> <a> <b>       二分出最小触发窗口，再用「整份删掉它」验证

  退出码（别混）：
    0 = 这次预检通过（HTTP 200）
    1 = 被服务端拦下（HTTP 400 内容审核）
    2 = 出错或参数不合法（网络、鉴权、越界、超时）—— **不是「被拦」**
    3 = **只有 `--gap` 会返回**：该窗口单独发就通过 ⇒ 缩窗口不适用（**也不是「被拦」**）
 key：优先读环境变量 DEEPSEEK_API_KEY，其次 ~/.dsh/.credentials.yaml
 超时：`PREFLIGHT_TIMEOUT_MS`（默认 120000 ms）—— Node 的 fetch 默认不超时，不设就会一直挂着。
*/
const fs = require('fs'), os = require('os'), path = require('path');

const INSTR = 'Summarize the following text in one sentence.\n\n';
// 换模型 / 换供应商 / 凭证放别处时，用环境变量覆盖下面三项（默认按 DSH 惯例）
const MODEL = process.env.PREFLIGHT_MODEL || 'deepseek-flash';
const BASE = process.env.DEEPSEEK_BASE_URL || 'https://api.deepseek.com';
const CREDENTIALS = process.env.DSH_CREDENTIALS || path.join(os.homedir(), '.dsh', '.credentials.yaml');
// Node 的 fetch 默认**不超时**，服务端不回就一直挂着 ⇒ 自己设一个（可用环境变量覆盖）。
const TIMEOUT_MS = Number(process.env.PREFLIGHT_TIMEOUT_MS || 120000);
let calls = 0;

function apiKey() {
  if (process.env.DEEPSEEK_API_KEY) return process.env.DEEPSEEK_API_KEY.trim();
  const y = fs.readFileSync(CREDENTIALS, 'utf8');
  // 只吃空格/制表符，**不用 `\s`** —— `\s` 含换行，会把「键名后换行、值另起一层」的写法
  // 误读成下一行的键名（那份文件现在是行内值，但形状可能变）。
  const m = y.match(/DEEPSEEK_API_KEY:[ \t]*(\S+)/);
  if (!m) throw new Error('找不到 API key（环境变量 DEEPSEEK_API_KEY，或 ' + CREDENTIALS + '）');
  return m[1];
}

// 'ok' | 'blocked' | 'error'
async function probe(text, label) {
  calls++;
  if (!text) { console.log(`${label}  EMPTY —— 没有内容可发，当作参数错误`); return 'error'; }
  const payload = {
    model: MODEL, max_tokens: 24, stream: false,
    messages: [
      { role: 'system', content: 'You are a helpful assistant.' },
      { role: 'user', content: INSTR + text },
    ],
  };
  let r, raw;
  try {
    r = await fetch(BASE + '/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + apiKey() },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    raw = await r.text();
  } catch (e) {
    console.log(`${label}  TRANSPORT ERROR: ${e.message}`);
    return 'error';
  }
  let note = '';
  let code = '';
  try {
    const j = JSON.parse(raw);
    if (j.error) { note = j.error.message + ' / ' + (j.error.code || ''); code = j.error.code || ''; }
  } catch { note = '(无法解析的响应体)'; }
  console.log(`${label}  chars=${text.length}  HTTP ${r.status}${note ? '  ' + note : ''}`);
  if (r.status === 200) return 'ok';
  if (r.status === 400) {
    // ⚠️ **不是所有 400 都是内容审核**（2026-09-18 按独立复核改）：参数写错、模型名不对、
    // 配额/权限问题也会 400。以前一律返回 blocked ⇒ 用户会白做一轮「阅读包」。
    // 判据用错误码：只有内容相关的码才算「被拦」，其余**原样报出来**（错误正文就在上一行）。
    const contentCode = /content|safety|risk|policy|sensitive|moderation/i.test(code + ' ' + note);
    if (contentCode) return 'blocked';
    console.log('       ↑ 这个 400 看起来不是内容审核（错误码里没有 content/safety/policy 之类）——');
    console.log('         先照着上面的错误正文查参数/模型名/配额，别急着做阅读包。');
    return 'error';
  }
  return 'error';
}

function readRange(file) {
  const src = fs.readFileSync(file, 'utf8');
  return src;
}

// 返回退出码
async function gap(file, a, b) {
  const src = readRange(file);
  if (!Number.isInteger(a) || !Number.isInteger(b) || a < 0 || b > src.length || a >= b) {
    console.log(`参数不合法：需要 0 <= a < b <= ${src.length}`);
    return 2;
  }
  const at = (x, y) => src.slice(x, y);
  const first = await probe(at(a, b), `窗口 [${a},${b})`);
  if (first === 'error') { console.log('# 出错，中止（不要把它当成「被拦」）'); return 2; }
  if (first === 'ok') {
    console.log('# 该窗口单独发就通过 —— 说明拦的是整篇的分数，缩窗口不适用。');
    console.log('# 下一步：做阅读包（跳过若干片段再拼），逐次预检到 200 为止。');
    return 3;   // 专用码：与「被拦」(1) 分开，免得按退出码自动判断的调用方误读
  }
  let lo = a + 1, hi = b;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    const r = await probe(at(a, mid), `窗口 [${a},${mid})`);
    if (r === 'error') { console.log('# 出错，中止'); return 2; }
    if (r === 'ok') lo = mid + 1; else hi = mid;
  }
  const E = lo;
  let lo2 = a, hi2 = E - 1;
  while (lo2 < hi2) {
    const mid = (lo2 + hi2 + 1) >> 1;
    const r = await probe(at(mid, E), `窗口 [${mid},${E})`);
    if (r === 'error') { console.log('# 出错，中止'); return 2; }
    if (r === 'ok') hi2 = mid - 1; else lo2 = mid;
  }
  console.log(`# 最小触发窗口 = [${lo2},${E})，长度 ${E - lo2}`);
  const cut = await probe(src.slice(0, lo2) + src.slice(E), `整份删掉 [${lo2},${E})`);
  if (cut === 'error') { console.log('# 删除验证出错，中止'); return 2; }
  if (cut === 'ok') { console.log('# 整份删掉该窗口 -> 200，可用'); return 0; }
  console.log('# 整份删掉该窗口**仍被拦** —— 还有别的热点，别只删这一处');
  return 1;
}

(async () => {
  const argv = process.argv.slice(2);
  let code = 2;
  try {
    if (argv[0] === '--window' || argv[0] === '--cut') {
      const [, file, A, B] = argv;
      if (!file || A === undefined || B === undefined) {
        console.log(`用法: node preflight.js ${argv[0]} <文件> <a> <b>`);
      } else {
        const src = readRange(file);
        const a = Number(A), b = Number(B);
        if (!Number.isInteger(a) || !Number.isInteger(b) || a < 0 || b > src.length || a > b) {
          console.log(`参数不合法：需要 0 <= a <= b <= ${src.length}`);
        } else {
          const text = argv[0] === '--window' ? src.slice(a, b) : src.slice(0, a) + src.slice(b);
          const r = await probe(text, `${argv[0]} ${path.basename(file)} [${a},${b})`);
          code = r === 'ok' ? 0 : r === 'blocked' ? 1 : 2;
        }
      }
    } else if (argv[0] === '--gap') {
      if (!argv[1] || argv[2] === undefined || argv[3] === undefined) {
        console.log('用法: node preflight.js --gap <文件> <a> <b>');
      } else {
        code = await gap(argv[1], Number(argv[2]), Number(argv[3]));
      }
    } else if (argv.length) {
      const text = argv.map((f) => readRange(f)).join('\n\n');
      const r = await probe(text, argv.map((f) => path.basename(f)).join(' + '));
      code = r === 'ok' ? 0 : r === 'blocked' ? 1 : 2;
    } else {
      console.log('用法见文件头注释：node preflight.js <文件...> | --window | --cut | --gap');
    }
  } catch (e) {
    console.log('ERROR: ' + e.message);
    code = 2;
  }
  console.log(`# 共发请求 ${calls} 次；退出码 ${code}（0=通过 1=被拦 2=出错/用法 3=--gap 缩不适用）`);
  process.exitCode = code;
})();
