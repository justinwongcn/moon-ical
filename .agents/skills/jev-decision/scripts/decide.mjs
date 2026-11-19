#!/usr/bin/env node
/**
 * JEV 决策模型调用脚本（TokenRhythm / tokenrhythm.studio，模型固定为 NeoHorse-Jev-4B）
 *
 * 用法：
 *   echo '<json>' | node decide.mjs                      # 请求体从 stdin 读入
 *   node decide.mjs request.json                         # 请求体从文件读入
 *   node decide.mjs request.json --endpoint systemone    # 切换 System One 兼容端点
 *   node decide.mjs request.json --dry-run               # 只做本地校验并打印归一化请求体，
 *                                                        # 不读密钥、不发网络请求
 *
 * 请求体形如 {"state": "...", "questions": {...}}，model 可省略（脚本默认补全）。
 * 密钥来源：环境变量 TOKENRHYTHM_API_KEY 优先，其次本技能根目录的 .env 文件。
 * 成功时把返回的结构化 JSON 原样打印到 stdout；失败时把 code/message/traceId 打印到 stderr
 * 并以非零退出码结束，便于上层把"调用失败"当错误处理，而不是当成某个答案。
 */
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SKILL_ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const DEFAULT_MODEL = 'NeoHorse-Jev-4B';
const ENDPOINTS = {
  decision: 'https://tokenrhythm.studio/v1/decision',
  systemone: 'https://tokenrhythm.studio/v1/systemone',
};

// ---- 参数解析 ----
const args = process.argv.slice(2);
let endpoint = 'decision';
let inputPath = '-';
let dryRun = false;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--endpoint') endpoint = args[++i];
  else if (args[i] === '--dry-run') dryRun = true;
  else if (args[i] === '--help' || args[i] === '-h') {
    console.log('用法: node decide.mjs [请求体文件|-] [--endpoint decision|systemone] [--dry-run]');
    process.exit(0);
  } else inputPath = args[i];
}
const url = ENDPOINTS[endpoint];
if (!url) {
  console.error(`未知端点：${endpoint}（可选 decision | systemone）`);
  process.exit(2);
}

// ---- 读取并校验请求体 ----
let payload;
try {
  const raw = inputPath === '-' ? readFileSync(0, 'utf8') : readFileSync(inputPath, 'utf8');
  payload = JSON.parse(raw);
} catch (err) {
  console.error(`读取或解析请求体失败：${err.message}`);
  process.exit(2);
}
if (!payload.model) payload.model = DEFAULT_MODEL;
if (!payload.questions || typeof payload.questions !== 'object' || Array.isArray(payload.questions)) {
  console.error('请求体缺少 questions 对象（键为问题 ID，值为 {type, instructions?, criteria?}）');
  process.exit(2);
}
if (dryRun) {
  // 校验通过即打印归一化请求体（含补全的默认 model），不读密钥、不发网络请求。
  console.log(JSON.stringify(payload, null, 2));
  process.exit(0);
}

// ---- 读取密钥 ----
function loadApiKey() {
  if (process.env.TOKENRHYTHM_API_KEY) return process.env.TOKENRHYTHM_API_KEY.trim();
  const envPath = join(SKILL_ROOT, '.env');
  if (!existsSync(envPath)) return null;
  const line = readFileSync(envPath, 'utf8')
    .split(/\r?\n/)
    .find((l) => l.startsWith('TOKENRHYTHM_API_KEY='));
  if (!line) return null;
  return line.slice('TOKENRHYTHM_API_KEY='.length).trim().replace(/^["']|["']$/g, '');
}
const apiKey = loadApiKey();
if (!apiKey || apiKey.includes('填入')) {
  console.error('未找到平台密钥：请设置环境变量 TOKENRHYTHM_API_KEY，或把 sk_ 开头的密钥写入本技能根目录的 .env');
  process.exit(2);
}

// ---- 调用接口（非流式 JSON）----
let response;
try {
  response = await fetch(url, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(payload),
  });
} catch (err) {
  // 网络层失败（含超时）：已发出的请求不要无条件重试，先人工确认
  console.error(`网络请求失败：${err.cause?.code || err.message}（超时请求不要无条件重试）`);
  process.exit(1);
}

const text = await response.text();
let body;
try {
  body = JSON.parse(text);
} catch {
  body = { raw: text };
}

if (!response.ok) {
  // 平台错误统一返回 code、message、traceId，保留 traceId 供排障
  console.error(`调用失败 HTTP ${response.status}: ${JSON.stringify(body, null, 2)}`);
  process.exit(1);
}

console.log(JSON.stringify(body, null, 2));
