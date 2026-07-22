# BashTab demo — regenerates docs/demo.gif
# Run from the repo root:  vhs docs/demo.tape
# Requires: vhs, ttyd, ffmpeg (https://github.com/charmbracelet/vhs)
# Container note: if chromium fails with a namespace/sandbox error, run as
#   PATH=/tmp/vhs-bin:$PATH vhs docs/demo.tape   (wrapper that adds --no-sandbox)

Output docs/demo.gif

Set Shell "bash"
Set FontSize 18
Set Width 1200
Set Height 675
Set Padding 16
Set Theme "Catppuccin Mocha"
Set TypingSpeed 60ms

# ── Setup: clean prompt, clean module path, deterministic fixtures ──
Type "export BU_MODULE_PATH=; cd /home/user/AgentProjects/BashTab && source ./activate 2>/dev/null"
Enter
Sleep 2s
Type "PROMPT_COMMAND=; PS1='$ '; mkdir -p /tmp/bu-demo && cd /tmp/bu-demo; touch report.md notes.txt app.py data.json; clear"
Enter
Sleep 500ms

# ── Beat 1: `bu` command listing ────────────────────────────
Type "bu"
Enter
Sleep 3s
Type "clear"
Enter

# ── Beat 2: fzf autocomplete with namespace discovery ──────
Type "bu get-"
Tab
Sleep 2s
Type "proc"
Sleep 1s
Enter
Sleep 500ms
Enter
Sleep 2s
Type "clear"
Enter

# ── Beat 3: structured output pipeline ─────────────────────
Type "bu get-process | bu where-object '.mem_percent > 1' | bu sort-object mem_percent --desc | bu select-object pid,command,mem_percent"
Enter
Sleep 3.5s

# ── Beat 4: option completion with hints + preview ─────────
Type "bu new-command --"
Tab
Sleep 4s

# ── Outro: hold the final frame ────────────────────────────
Sleep 3s
