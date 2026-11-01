#!/bin/zsh
# Scores Babble's accuracy. Eval sentences live in Evals/private (gitignored, since they come from
# personal dictations), one per line: id<TAB>what to say<TAB>what should be pasted. Usage:
#   scripts/eval.sh                              Evals/private/corpus.tsv read by macOS's Indian English voices
#   scripts/eval.sh Evals/private/heldout.tsv    same, for sentences never tuned against
#   scripts/eval.sh real                         your own recordings from scripts/record.sh
# Recognizer output is cached; BABBLE_FRESH=1 re-transcribes (needed after changing Dictation).
# Uses Evals/private/personal-vocabulary.txt (gitignored) in place of your own list if it exists, so
# scores don't drift as your list changes.
set -euo pipefail
cd "$(dirname "$0")/.."
corpus=${1:-Evals/private/corpus.tsv}
out=.build/evals/${corpus:t:r}
mkdir -p $out
manifest=$out/manifest.tsv
: > $manifest
if [[ $corpus == real ]]; then
  for wav in Evals/recordings/*.wav(N); do
    print -r -- "$PWD/$wav	$(<${wav:r}.txt)" >> $manifest
  done
else
  for voice in Aman Rishi Tara; do
    mkdir -p "$out/$voice"
    grep -v '^#' $corpus | while IFS=$'\t' read -r id spoken reference; do
      wav="$out/$voice/$id.wav"
      [[ -f $wav ]] || say -v "$voice" -o "$wav" --data-format=LEI16@16000 "$spoken"
      print -r -- "$wav	${reference:-$spoken}" >> $manifest
    done
  done
fi
swift build -c release -q
cp Resources/vocabulary.txt .build/release/vocabulary.txt
vocabulary=Evals/private/personal-vocabulary.txt
[[ -f $vocabulary ]] || vocabulary=/dev/null
BABBLE_VOCABULARY=$vocabulary .build/release/Babble --eval $manifest ${BABBLE_FRESH:+--fresh}
