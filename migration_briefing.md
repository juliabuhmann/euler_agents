# Briefing: migrate an existing `euler_agents` setup to `hpc_agents`

For people who used this launcher when it was called `euler_agents` (repo
`juliabuhmann/euler_agents`, commands `euler-agent-run` / `euler-agent-submit`). Point your agent
at this file, or follow it by hand. It is written for an agent running **as you on an Euler login
node, outside the container** (it needs your whole home, `squeue` and `git`).

Status: generalised from one migration on Euler (November 2026). Not yet tested by a second user;
if a step doesn't match what you see, stop and check rather than force it.

## What changed

- The GitHub repo is now `juliabuhmann/hpc_agents` (GitHub redirects the old URL).
- Commands: `bin/euler-agent-run` → `bin/hpc-agent-run`, `bin/euler-agent-submit` →
  `bin/hpc-agent-submit`. `make install` removes the old `~/.local/bin` links.
- Names: Remote Control sessions `euler-rc-*` → `hpc-rc-*`; env var `EULER_AGENTS_DIR` →
  `HPC_AGENTS_DIR`; `images/euler-agents.def` → `images/hpc-agents.def`. Existing `.sif` images
  keep working.
- **Cluster profiles** in `config/sites/`, selected by the setting `"site"`. **The shipped
  default is `curnagl`** (UNIL), so Euler users must set `"site": "euler"` locally.
- Default settings changed in `config/settings.json`: `image_path` is now a Curnagl placeholder
  (it used to be the Euler image), `git_user_name`/`git_user_email` default to `hpc-agent`, and the
  Claude model defaults to `"opus"` (the newest Opus).
- Commits made inside the container: author and committer are exported as `GIT_AUTHOR_*` /
  `GIT_COMMITTER_*`, so a repo-local `user.name`/`user.email` no longer overrides them. The
  `commit-msg` hook keeps one `Co-Authored-By` per vendor, puts it last, and **rejects a Claude
  commit without a Claude `Co-Authored-By` trailer** (Codex still gets one added).

Read `README.md` and `CLAUDE.md` in the repo for how the harness works.

Below, `OLD` is your current clone (usually `~/src/euler_agents`) and `NEW` is where it should
live (e.g. `~/src/hpc_agents`). Renaming the folder is optional; the rest is not.

## Before you change anything

1. **No agent may be running from `OLD`.** Check `squeue --me`. Agent homes (`home-claude/`) and
   per-launch session folders (`launches-claude/`) live inside the repo dir, so moving it breaks
   running agents. If a job is running, find out whether it uses `OLD` (an allocation holding
   only idle shells is fine); if unsure, stop and ask.
2. `git -C OLD status`: only untracked logs (`slurm-*.out`) are expected. Any other local change:
   stop and ask.
3. Note the pre-merge defaults before pulling: `git -C OLD show HEAD:config/settings.json`.
   You need the old `image_path` if your local settings don't set one.
4. `git -C OLD pull`.

## Steps (one check each)

1. **Local settings** (`OLD/config/settings.local.json`, gitignored). Never edit
   `config/settings.json`: other clusters rely on its defaults.
   - Add `"site": "euler"`.
   - Make sure `image_path`, `workspace_dir` and `logs_dir` are set here. If `image_path` was
     missing, set it to the old default from step 3 above.
   - If you relied on the default commit identity, set `git_user_name` / `git_user_email`.
   - The merge is **shallow**: a `"claude"` block here replaces the default one whole. If it pins
     an old model id, consider `"opus"`.
   - Check: source the merge and print the result:
     ```bash
     cd OLD && REPO_DIR=$PWD bash -c 'source bin/host-config.sh; _setting "s[\"site_cfg\"][\"name\"], s[\"image_path\"], s[\"workspace_dir\"], s[\"logs_dir\"], s[\"git_user_email\"]"'
     ```
     The site must be `euler` and the image file must exist.
2. **Remote.** `git -C OLD remote set-url origin <same scheme>…/juliabuhmann/hpc_agents.git`
   (keep SSH vs HTTPS as it is now; if `origin` is your own fork, leave it and update `upstream`).
3. **Folder (optional).** `mv OLD NEW && ln -s NEW OLD`. The symlink keeps old paths in your
   scripts and notes working.
4. **Install.** `make -C NEW install`. Check: `hpc-agent-run --help` works, and
   `ls ~/.local/bin` has no `euler-agent-*` links.
5. **Keep launcher-dir sessions resumable** (only if you renamed the folder). Claude stores
   sessions under `~/.claude/projects/<cwd with every non-alphanumeric char except '-' as '-'>`.
   Sessions you ran *in the repo dir itself* would disappear from `claude --resume`; agent
   workspace sessions are not affected.
   ```bash
   enc() { python3 -c 'import re,sys; print(re.sub(r"[^A-Za-z0-9-]", "-", sys.argv[1]))' "$1"; }
   OLD_ABS=$HOME/src/euler_agents   # absolute path of OLD as typed before the move (not resolved through the new symlink)
   NEW_ABS=$HOME/src/hpc_agents
   P=~/.claude/projects; O=$P/$(enc "$OLD_ABS"); N=$P/$(enc "$NEW_ABS")
   [ -d "$O" ] && [ ! -e "$N" ] && ln -s "$O" "$N"
   ```
   If `$HOME` is itself a symlink, use the physical path (`pwd -P` in the folder), since Claude
   keys sessions by that.
   If `N` already exists, stop and ask. Check: `claude --resume` started in `NEW` lists them
   (Claude may first ask to trust the new path).
6. **Smoke test** (login node, throwaway project):
   `NEW/bin/hpc-agent-run --agent claude --project harness-test --interactive`, then inside:
   - `git config user.email` is yours;
   - `echo $https_proxy` is set and `curl -sI https://api.anthropic.com` answers (`eth_proxy`
     module loaded by the Euler profile);
   - `head /tmp/agent-briefing.md` exists;
   - `claude -p "reply with exactly: OK"` prints OK.

   Also check a real workspace: launch with your usual `--project` (and `--workspace`) and run
   `claude --resume` inside; your old sessions should be listed. Don't resume one that another
   job is running. Remote Control sessions started before the migration can still be reattached:
   `--rc-session-id` / `--rc-continue` find them by ID and workspace, not by the `*-rc-*` name.
7. **Update references** to the old path and command names in your own files:
   ```bash
   grep -rIl --exclude-dir=.git --exclude-dir=.pixi --exclude-dir=home-claude --exclude-dir=launches-claude \
     "euler_agents\|euler-agent-run\|euler-agent-submit\|EULER_AGENTS_DIR\|euler-rc-" \
     ~/src ~/.claude/CLAUDE.md ~/.claude/skills ~/.bashrc 2>/dev/null
   ```
   Fix launch commands, scripts that look up `euler-agent-*` on `PATH`, and docs. Leave history
   alone (session transcripts, old reports, digests). Files named `euler-agents.binds` don't need
   renaming: `--binds-file` takes any path. Commit per repo, in small units; don't push without
   the user.

## Report back

What changed (per repo, with commit hashes), the smoke-test result, which references you left
alone and why, and the push commands for the user.
