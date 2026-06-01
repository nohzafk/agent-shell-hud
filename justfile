set shell := ["bash", "-euo", "pipefail", "-c"]

emacs := env_var_or_default("EMACS", "emacs")

[group('Test')]
default:
    @just --list

# Byte-compile the adapter as a verification check.
[group('Test')]
compile:
    {{emacs}} -Q --batch \
      -L /Users/randall/projects/emacs-workspace-hud/lisp \
      -L /Users/randall/projects/agent-shell \
      -L /Users/randall/.config/emacs/hypervisor/sources/acp \
      -L /Users/randall/.config/emacs/hypervisor/sources/shell-maker \
      -L . \
      -f batch-byte-compile *.el
    rm -f *.elc

[group('Build')]
clean:
    rm -f *.elc
