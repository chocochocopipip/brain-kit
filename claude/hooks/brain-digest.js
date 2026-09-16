#!/usr/bin/env node
/**
 * Condense a Claude Code transcript (.jsonl) into a compact digest for
 * summarization by ~/.claude/hooks/session-end-brain.sh.
 *
 * Usage: node brain-digest.js <transcript.jsonl>
 * Prints the digest to stdout. Exits 1 if there is nothing worth summarizing.
 */
const fs = require('fs');

const MAX_TOTAL = 60000;   // hard cap on digest size handed to the summarizer
const MAX_USER = 4000;     // per user prompt
const MAX_ASSISTANT = 2000; // per assistant text block
const MAX_TOOL = 300;      // per tool invocation line

const path = process.argv[2];
if (!path || !fs.existsSync(path)) process.exit(1);

const clip = (s, n) => {
  s = String(s == null ? '' : s).replace(/\r/g, '').trim();
  return s.length > n ? s.slice(0, n) + ' …[truncated]' : s;
};

// Pull plain text out of a message content field (string or content-block array).
const textOf = (content) => {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.filter((b) => b && b.type === 'text').map((b) => b.text).join('\n');
};

const parts = [];
let userPrompts = 0;

let lines;
try {
  lines = fs.readFileSync(path, 'utf8').split('\n');
} catch {
  process.exit(1);
}

for (const line of lines) {
  if (!line.trim()) continue;
  let o;
  try { o = JSON.parse(line); } catch { continue; }
  const msg = o.message;
  if (!msg) continue;

  if (o.type === 'user') {
    // Skip tool_result turns - they are tool output, not what the user said.
    if (Array.isArray(msg.content) && msg.content.some((b) => b && b.type === 'tool_result')) continue;
    const t = textOf(msg.content);
    // Ignore harness-injected reminders and command wrappers.
    const cleaned = t.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '').trim();
    if (!cleaned) continue;
    userPrompts++;
    parts.push('## USER\n' + clip(cleaned, MAX_USER));
  } else if (o.type === 'assistant') {
    const t = textOf(msg.content);
    if (t.trim()) parts.push('## ASSISTANT\n' + clip(t, MAX_ASSISTANT));
    if (Array.isArray(msg.content)) {
      for (const b of msg.content) {
        if (!b || b.type !== 'tool_use') continue;
        const i = b.input || {};
        const detail = i.command || i.file_path || i.pattern || i.path || i.prompt || '';
        parts.push('## TOOL ' + b.name + ': ' + clip(detail, MAX_TOOL));
      }
    }
  }
}

if (!userPrompts) process.exit(1);

// Keep the beginning (the ask) and the end (the outcome) when over budget.
let digest = parts.join('\n\n');
if (digest.length > MAX_TOTAL) {
  const head = digest.slice(0, Math.floor(MAX_TOTAL * 0.4));
  const tail = digest.slice(-Math.floor(MAX_TOTAL * 0.6));
  digest = head + '\n\n…[middle of session omitted]…\n\n' + tail;
}
process.stdout.write(digest);
