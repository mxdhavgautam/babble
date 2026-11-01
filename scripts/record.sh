#!/bin/zsh
# Records you reading Evals/private/prompts.tsv (id<TAB>what to say<TAB>what should be pasted) into
# Evals/recordings, both gitignored, for `scripts/eval.sh real`.
# Speak naturally, the way you'd dictate. Enter starts and stops each take; s skips; q quits.
# Already-recorded prompts are skipped, so it's safe to stop and resume.
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p Evals/recordings
grep -v '^#' Evals/private/prompts.tsv | while IFS=$'\t' read -r id say reference; do
  wav=Evals/recordings/$id.wav
  [[ -f $wav ]] && continue
  print "\n\e[1m$say\e[0m"
  read -sk "key?  Enter to record, s to skip, q to quit " </dev/tty; print
  [[ $key == q ]] && break
  [[ $key == s ]] && continue
  ffmpeg -loglevel error -f avfoundation -i ":0" -ac 1 -ar 16000 -y "$wav" </dev/null &
  pid=$!
  read -s "?  ● recording, Enter to stop " </dev/tty; print
  sleep 0.4  # keep the tail of the last word
  kill -INT $pid; wait $pid 2>/dev/null
  print -r -- "$reference" > Evals/recordings/$id.txt
done
print "\nDone. Score them with: scripts/eval.sh"
