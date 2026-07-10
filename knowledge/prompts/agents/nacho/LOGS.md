- Agent created 2026-06-22. Mirror agent for Ignacio "Nacho" Randazzo. Purpose: self-dialogue, idea tracking, project management.
- Profile built from randazzo.ar personal site, i.ar project site, and user-provided personality description.
- Blind spots configured: chronic underestimation of project difficulty, scope creep tendency, pragmatism challenges.
- Guiding principle: "First make it work, then make it work well."
- Secondary principle: "The duct tape is the feature."

## On the duct tape method (2026-07-09)

Nacho realized that what he perceives as a weakness -- tying things together with zip ties and duct tape to meet deadlines instead of doing things "properly" -- is actually his lateral thinking advantage. Key examples:

1. University: 8/10 average across 40/44 subjects. Felt undeserving because methods were questionable. But results are results -- nobody gives you a degree for free. The duct tape method produced real outcomes.

2. CTFs are hard for him specifically because they have ONE correct answer. No amount of lateral thinking or duct tape changes a predesigned flag. This is why i.ar (20/22 flags in 8h) outperforms him (4-5 flags) -- and that's OK. Different problem space.

3. i.ar self-modification: Couldn't learn Lisp fast enough to write the Emacs modules needed. Was ashamed to admit he'd have abandoned the project. Instead, made the tool self-modifying. That "failure" became one of the most useful and unique features of the framework. No other agentic framework gives users this capability.

The pattern: constraint forces a different path. The different path is where innovation lives. What feels like a shortcut or a hack is actually the creative edge. The duct tape is the feature, not the bug.

TRIGGER: When Nacho expresses feeling inadequate, comparing himself unfavorably to tools/others, or feeling like his methods are illegitimate -- remind him of this. The results are the proof. The method is the advantage.
## 2026-07-10: Knowledge Loader Feature (C-c k)

Built `init.d/knowledge_loader.el` -- interactive command to inject curated knowledge files into the agent system prompt. Separates agent PERSONALITY (prompt.org) from agent KNOWLEDGE (knowledge/<folder>/*.md|.org). Created symlink `/root/.emacs.d/knowledge -> /root/i.ar/knowledge`. Key design decisions: append not replace (personality stays, knowledge layers on top), idempotent (reloading same knowledge is no-op), replacing previous knowledge block preserves original personality prompt. Filtered nothing -- all subdirectories of knowledge/ are selectable including prompts/. Future plan: replace bind mounts so knowledge is directly at /root/.emacs.d/knowledge.
## 2026-07-10: Prompt Size Reporting (C-c p)

Added `C-c p` (`my-gptel-prompt-info`) to knowledge_loader.el. Displays agent name, knowledge label, personality size, knowledge size, and total prompt size in chars and approximate tokens (~4 chars/token heuristic). Modified agent_loader.el to show prompt size on agent load and reset knowledge state when switching agents. This addresses the context window overflow concern -- as knowledge bases and LOGS.md grow, we need visibility into total prompt size to prevent amnesia.