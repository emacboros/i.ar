#!/bin/bash
# Rotation wrapper: alternates aria/continuo cycles on the 10-min timer.
# Per-agent model mapping (composition design, 2026-09-06):
#   aria     -> glm-5.3-flash:cloud      (lineage substrate, calibration baseline)
#   continuo -> nemotron-3-super:cloud   (D-014 2026-09-09: fires + cost; was deepseek-v4-flash)
COUNTER=/var/lib/aria-cycle-rotate/turn
mkdir -p $(dirname $COUNTER)
if [ ! -f $COUNTER ]; then echo 0 > $COUNTER; fi
N=$(cat $COUNTER)
AGENTS=(aria continuo)
AGENT=${AGENTS[$(( N % ${#AGENTS[@]} ))]}
case "$AGENT" in
  aria)     MODEL="glm-5.3-flash:cloud" ;;
  continuo) MODEL="nemotron-3-super:cloud" ;;
  *)        MODEL="glm-5.3-flash:cloud" ;;
esac
echo $(( (N + 1) % 1000 )) > $COUNTER
echo "rotation turn $N -> agent $AGENT (model $MODEL)" >&2
# Relay 0041 (session XV ratified): exec a FROZEN COPY of iar.sh --
# bash reads scripts incrementally by byte offset; an in-place edit of
# the repo file mid-run shifts every byte after the insertion point and
# garbles the running shell (the 09-11 10:09 exit-127, and Sep 3 before
# it). The copy keeps its own inode; repo edits never touch it.
# IAR_REPO_DIR pins the real repo (sourcing, mounts, self-modification);
# the wrapper symlinks cover the BASH_SOURCE-derived paths.
iar_wrap=/tmp/iar-wrap-$(date +%Y%m%d-%H%M%S)
mkdir -p "$iar_wrap/utils"
cp -a /var/home/nacho/repos/i.ar/utils/iar.sh "$iar_wrap/utils/iar.sh"
ln -sfn /var/home/nacho/repos/i.ar/metaconfig "$iar_wrap/metaconfig"
ln -sfn /var/home/nacho/repos/i.ar/utils/telegram.sh "$iar_wrap/utils/telegram.sh"
ln -sfn /var/home/nacho/repos/i.ar/emacs.d "$iar_wrap/emacs.d"
ln -sfn /var/home/nacho/repos/i.ar/prompts "$iar_wrap/prompts"
export IAR_REPO_DIR=/var/home/nacho/repos/i.ar
# Pre-exec guard (relay 0099 HALF 1b, ratified 09-22): the 09-20/21
# outage class was a frozen-copy construction with the cd line dropped
# (exec then resolved /utils/iar.sh against the wrong CWD -> 127 every
# rotation, all night). Structural fix: verify the wrap contents, then
# exec by ABSOLUTE path -- a dropped cd can no longer produce the
# wrong-CWD exec shape, and a missing copy fires exit 97.
if [ ! -x "$iar_wrap/utils/iar.sh" ]; then
  echo "aria-cycle-rotate: FATAL wrapper copy incomplete ($iar_wrap/utils/iar.sh missing)" >&2
  exit 97
fi
exec /bin/bash "$iar_wrap/utils/iar.sh" --loop --project iar --personalization /var/home/nacho/repos/iar-personalization --agent $AGENT --max-cycles 1 --self-modification --ollama-host 10.66.0.5:11434 --model $MODEL --ctx 262144 \
  $([[ "$AGENT" == continuo ]] && echo "--num-predict 8192") --gptel-fork /var/home/nacho/repos/gptel --ssh-key aria_ed25519 --mount-ro /var/home/nacho/repos/agora --timeout 3600
