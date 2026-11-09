#!/bin/zsh
# Live view for the demo recording: waits for a new meeting folder, redraws transcript.md
# whenever it changes, then shows notes.md once Babble writes it.
MEETINGS=~/Babble/Meetings
B=$'\e[1m'; D=$'\e[2m'; R=$'\e[0m'; BLUE=$'\e[38;5;75m'; RED=$'\e[38;5;203m'; GRN=$'\e[38;5;114m'; YEL=$'\e[38;5;221m'
before=$(ls -1 $MEETINGS 2>/dev/null)

header() {
  print -n $'\e[2J\e[H'
  print "${B}Babble${R} ${D}nightly · meeting mode${R}"
  print "${D}⌥T start/stop · mic = ${R}${B}Me${R}${D} · system audio = ${R}${BLUE}${B}Them${R}${D} · everything on device${R}"
  print
}

render_transcript() {
  sed -E \
    -e "s/^\[([0-9:]+)\] Them:/${D}[\1]${R} ${BLUE}${B}Them:${R}/" \
    -e "s/^\[([0-9:]+)\] Me:/${D}[\1]${R} ${B}Me:${R}/" "$1"
}

render_notes() {
  sed -E \
    -e "s/^# (.*)/${B}${YEL}\1${R}/" \
    -e "s/^#{2,3} (.*)/${B}${GRN}\1${R}/" \
    -e "s/^- \[ \] /  ${RED}☐${R} /" \
    -e "s/^- /  • /" "$1"
}

header
print "${D}Waiting for a meeting. Press ⌥T.${R}"
dir=""
while [[ -z $dir ]]; do
  sleep 0.3
  for d in ${(f)"$(ls -1 $MEETINGS 2>/dev/null)"}; do
    [[ -n $d ]] || continue
    print -r -- "$before" | grep -qxF -- "$d" || dir="$MEETINGS/$d"
  done
done

last=""
while [[ ! -s $dir/notes.md ]]; do
  [[ -d $dir ]] || { header; print "${RED}Meeting discarded (⌥Esc).${R}"; exit 0; }
  sum=$(md5 -q $dir/transcript.md 2>/dev/null)
  if [[ $sum != $last ]]; then
    last=$sum
    header
    print "${RED}●${R} ${B}recording${R}  ${D}${dir/#$HOME/~}/transcript.md, rewritten live${R}"
    print
    [[ -s $dir/transcript.md ]] && render_transcript $dir/transcript.md || print "${D}(listening…)${R}"
  fi
  sleep 0.4
done

header
print "${GRN}✓${R} ${B}notes ready${R}  ${D}${dir/#$HOME/~}/notes.md, made by Apple's on-device model${R}"
print
render_notes $dir/notes.md
print
print "${D}transcript.md and notes.md are mode $(stat -f %Lp $dir/notes.md). No audio is saved.${R}"
sleep 100000
