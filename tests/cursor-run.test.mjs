import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("..", import.meta.url));
const scriptPath = path.join(repoRoot, "scripts", "cursor-run.sh");
const chatId = "123e4567-e89b-12d3-a456-426614174000";

async function writeExecutable(file, contents) {
  await writeFile(file, contents, { mode: 0o755 });
}

async function createHarness() {
  const root = await mkdtemp(path.join(tmpdir(), "cursor-run-test-"));
  const bin = path.join(root, "bin");
  const cache = path.join(root, "cache");
  const home = path.join(root, "home");
  const argLog = path.join(root, "cursor-agent-args.log");

  await mkdir(bin, { recursive: true });
  await mkdir(cache, { recursive: true });
  await mkdir(home, { recursive: true });

  await writeExecutable(
    path.join(bin, "timeout"),
    `#!/usr/bin/env bash
set -uo pipefail
if [[ "\${1:-}" == --kill-after=* ]]; then
  shift
fi
shift
exec "$@"
`,
  );

  await writeExecutable(
    path.join(bin, "cursor-agent"),
    `#!/usr/bin/env bash
set -uo pipefail
if [ -n "\${FAKE_CURSOR_LOG:-}" ]; then
  for arg in "$@"; do
    printf '<%s>' "$arg" >> "$FAKE_CURSOR_LOG"
  done
  printf '\\n' >> "$FAKE_CURSOR_LOG"
fi

case "\${1:-}" in
  status)
    if [ "\${FAKE_CURSOR_STATUS:-ok}" = "ok" ]; then
      printf 'Logged in\\n'
    else
      printf '%b' "\${FAKE_CURSOR_STATUS_OUTPUT:-Not logged in\\n}"
    fi
    exit "\${FAKE_CURSOR_STATUS_RC:-0}"
    ;;
  create-chat)
    printf '%b' "\${FAKE_CURSOR_CREATE_OUTPUT:-${chatId}\\n}"
    exit "\${FAKE_CURSOR_CREATE_RC:-0}"
    ;;
  *)
    printf '%b' "\${FAKE_CURSOR_RUN_OUTPUT:-executor ok\\n}"
    exit "\${FAKE_CURSOR_RUN_RC:-0}"
    ;;
esac
`,
  );

  return {
    argLog,
    cache,
    env(extra = {}) {
      const env = {
        ...process.env,
        FAKE_CURSOR_LOG: argLog,
        HOME: home,
        PATH: `${bin}${path.delimiter}${process.env.PATH ?? ""}`,
        XDG_CACHE_HOME: cache,
        ...extra,
      };
      delete env.CURSOR_API_KEY;
      delete env.CURSOR_AUTH_TOKEN;
      return env;
    },
    root,
  };
}

function runCursor(args, { cwd, env }) {
  return spawnSync("bash", [scriptPath, ...args], {
    cwd,
    encoding: "utf8",
    env,
  });
}

function runGit(args, cwd) {
  const result = spawnSync("git", args, {
    cwd,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr || result.stdout);
  return result;
}

async function createGitRepo(root, name = "repo") {
  const repo = path.join(root, name);
  await mkdir(repo, { recursive: true });
  runGit(["init"], repo);
  return repo;
}

test("auth parses logged-in cursor-agent status", async () => {
  const harness = await createHarness();
  const result = runCursor(["auth"], {
    cwd: harness.root,
    env: harness.env(),
  });

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "STATUS=ok\n");
});

test("auth fails when cursor-agent status is not logged in", async () => {
  const harness = await createHarness();
  const result = runCursor(["auth"], {
    cwd: harness.root,
    env: harness.env({ FAKE_CURSOR_STATUS: "fail" }),
  });

  assert.equal(result.status, 1);
  assert.match(result.stderr, /not authenticated/);
});

test("new refuses a dirty in-place git workspace", async () => {
  const harness = await createHarness();
  const repo = await createGitRepo(harness.root);
  await writeFile(path.join(repo, "dirty.txt"), "uncommitted\n");

  const result = runCursor(["new", "--prompt", "Make the change"], {
    cwd: repo,
    env: harness.env(),
  });

  assert.equal(result.status, 1);
  assert.match(result.stdout, /STEP=auth/);
  assert.match(result.stderr, /working tree has uncommitted changes/);
});

test("new accepts final create-chat line and writes run metadata", async () => {
  const harness = await createHarness();
  const repo = await createGitRepo(harness.root);
  const result = runCursor(["new", "--prompt", "Make the change"], {
    cwd: repo,
    env: harness.env({
      FAKE_CURSOR_CREATE_OUTPUT: `Preparing chat\\n${chatId}\\n`,
      FAKE_CURSOR_RUN_OUTPUT: "executor changed files\n",
    }),
  });

  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /STEP=auth/);
  assert.match(result.stdout, /STEP=create-chat/);
  assert.match(result.stdout, new RegExp(`CHAT_ID=${chatId}`));
  assert.match(result.stdout, /STEP=run/);
  assert.match(result.stdout, /STATUS=ok/);

  const latest = await readFile(
    path.join(harness.cache, "cursor-handoff", "latest.env"),
    "utf8",
  );
  assert.match(latest, new RegExp(`CHAT_ID=${chatId}`));

  const logPath = result.stdout.match(/^LOG=(.*)$/m)?.[1];
  assert.ok(logPath, result.stdout);
  assert.equal(await readFile(logPath, "utf8"), "executor changed files\n");
});

test("new forwards MCP approval only when explicitly requested", async () => {
  const harness = await createHarness();
  const repo = await createGitRepo(harness.root);
  const defaultResult = runCursor(["new", "--prompt", "Make the change"], {
    cwd: repo,
    env: harness.env(),
  });

  assert.equal(defaultResult.status, 0, defaultResult.stderr);
  assert.doesNotMatch(
    await readFile(harness.argLog, "utf8"),
    /<--approve-mcps>/,
  );

  await writeFile(harness.argLog, "");
  const approvedResult = runCursor(
    ["new", "--approve-mcps", "--prompt", "Make the change"],
    {
      cwd: repo,
      env: harness.env(),
    },
  );

  assert.equal(approvedResult.status, 0, approvedResult.stderr);
  assert.match(await readFile(harness.argLog, "utf8"), /<--approve-mcps>/);
});

test("new fails when cursor-agent prints an error despite exit zero", async () => {
  const harness = await createHarness();
  const repo = await createGitRepo(harness.root);
  const result = runCursor(["new", "--prompt", "Make the change"], {
    cwd: repo,
    env: harness.env({
      FAKE_CURSOR_RUN_OUTPUT: "Authentication required\n",
    }),
  });

  assert.equal(result.status, 1);
  assert.match(result.stderr, /cursor-agent reported an error/);
});

test("continue last resumes the worktree recorded in metadata", async () => {
  const harness = await createHarness();
  const repo = await createGitRepo(harness.root);
  const worktree = path.join(harness.root, "recorded-worktree");
  const metadataDir = path.join(harness.cache, "cursor-handoff");
  await mkdir(worktree, { recursive: true });
  await mkdir(metadataDir, { recursive: true });
  await writeFile(
    path.join(metadataDir, "latest.env"),
    `CHAT_ID=${chatId}\nWORKTREE=${worktree}\n`,
  );

  const result = runCursor(["continue", "last", "--prompt", "Follow up"], {
    cwd: repo,
    env: harness.env(),
  });

  assert.equal(result.status, 0, result.stderr);
  const args = await readFile(harness.argLog, "utf8");
  assert.match(args, new RegExp(`<--resume><${chatId}>`));
  assert.match(args, new RegExp(`<--workspace><${worktree}>`));
});
