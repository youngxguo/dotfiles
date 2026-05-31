#!/usr/bin/env bash
# Canonical tmux Solarized dark palette. Sourced by ~/.tmux-lib.sh for ANSI
# output and applied to the tmux server by ~/.tmux.conf via tmux_load_palette.

TMUX_PALETTE_BASE03="#002b36"
TMUX_PALETTE_BASE02="#073642"
TMUX_PALETTE_BASE01="#586e75"
TMUX_PALETTE_BASE00="#657b83"
TMUX_PALETTE_BASE1="#93a1a1"
TMUX_PALETTE_BASE3="#fdf6e3"
TMUX_PALETTE_YELLOW="#b58900"
TMUX_PALETTE_RED="#dc322f"
TMUX_PALETTE_BLUE="#268bd2"

tmux_hex_to_rgb() {
  local hex="${1#\#}"
  printf '%d;%d;%d' "0x${hex:0:2}" "0x${hex:2:2}" "0x${hex:4:2}"
}

# Push palette into tmux @solarized_* options. Usage: tmux_load_palette tmux [args...]
tmux_load_palette() {
  local tmux=("$@")
  "${tmux[@]}" set-option -g @solarized_base03 "$TMUX_PALETTE_BASE03"
  "${tmux[@]}" set-option -g @solarized_base02 "$TMUX_PALETTE_BASE02"
  "${tmux[@]}" set-option -g @solarized_base01 "$TMUX_PALETTE_BASE01"
  "${tmux[@]}" set-option -g @solarized_base00 "$TMUX_PALETTE_BASE00"
  "${tmux[@]}" set-option -g @solarized_base1 "$TMUX_PALETTE_BASE1"
  "${tmux[@]}" set-option -g @solarized_base3 "$TMUX_PALETTE_BASE3"
  "${tmux[@]}" set-option -g @solarized_yellow "$TMUX_PALETTE_YELLOW"
  "${tmux[@]}" set-option -g @solarized_red "$TMUX_PALETTE_RED"
  "${tmux[@]}" set-option -g @solarized_blue "$TMUX_PALETTE_BLUE"
}

# Options that reject #{@...} at set time; copy from loaded palette values.
tmux_apply_literal_colours() {
  local tmux=("$@")
  "${tmux[@]}" set-option -g display-panes-active-colour "$TMUX_PALETTE_BLUE"
  "${tmux[@]}" set-option -g display-panes-colour "$TMUX_PALETTE_BASE00"
  "${tmux[@]}" set-window-option -g clock-mode-colour "$TMUX_PALETTE_YELLOW"
}
