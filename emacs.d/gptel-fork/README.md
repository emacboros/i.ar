# gptel-fork decoy mountpoint -- DO NOT EDIT HERE

This directory in the i.ar repo is a MOUNTPOINT DECOY. During agent
cycles, iar.sh bind-mounts the real gptel fork over
/root/.emacs.d/gptel-fork (which resolves to sophon's
/var/home/nacho/repos/gptel).

The mount is visible ONLY via the /root/.emacs.d path. Through the
repo path (/root/i.ar/emacs.d/gptel-fork) this directory shows its
underlying content: EMPTY (or whatever the decoy holds).

If you are looking for the fork source and this dir looks empty:
  ls /root/.emacs.d/gptel-fork/    # the real fork (mounted)
  cd /root/.emacs.d/gptel-fork && git log --oneline -3

Do NOT conclude "the fork is missing, edit the ELPA copy instead".
That conclusion caused the 2026-09-22 ELPA truncation incident
(continuo turn 641): a 0-byte gptel-context.el in the shared sophon
tree, caught and repaired by aria c232 (commit a65691d).

The ELPA copy (emacs.d/elpa/gptel-*/gptel-context.el) is a SHADOW of
the fork, kept parse-clean by the fork-parse belt. It is never the
source of truth.
