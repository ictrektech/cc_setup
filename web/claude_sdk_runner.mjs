#!/usr/bin/env node
import { query } from "@anthropic-ai/claude-agent-sdk";

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      data += chunk;
    });
    process.stdin.on("end", () => resolve(data));
    process.stdin.on("error", reject);
  });
}

function write(payload) {
  process.stdout.write(`${JSON.stringify(payload)}\n`);
}

const AGENT_PROMPT = `
You are running inside Agent Room as an autonomous coding agent.
When the user asks about a repository, codebase, files, git state, bugs, or improvements, you must inspect the workspace with available tools before answering. Do not answer with only intentions such as "I will inspect"; actually call tools like Glob, Grep, Read, or Bash, then provide the conclusion.
For implementation requests, inspect first, edit/test when appropriate, and report concrete results.
`;

try {
  const raw = await readStdin();
  const input = JSON.parse(raw || "{}");
  const options = {
    cwd: input.cwd,
    env: { ...process.env },
    permissionMode: input.permissionMode || "bypassPermissions",
    allowDangerouslySkipPermissions: true,
    maxTurns: Number(input.maxTurns || 12),
    tools: { type: "preset", preset: "claude_code" },
    systemPrompt: { type: "preset", preset: "claude_code", append: AGENT_PROMPT },
    settingSources: ["project", "user", "local"],
  };

  if (input.command) {
    options.pathToClaudeCodeExecutable = input.command;
  }
  if (input.providerSessionId) {
    options.resume = input.providerSessionId;
  }

  const stream = query({
    prompt: input.prompt || "",
    options,
  });

  for await (const message of stream) {
    write({ type: "sdk_message", message });
  }
  write({ type: "runner_complete", exitCode: 0 });
} catch (error) {
  write({
    type: "runner_error",
    error: error?.message || String(error),
    stack: error?.stack || "",
  });
  process.exitCode = 1;
}
