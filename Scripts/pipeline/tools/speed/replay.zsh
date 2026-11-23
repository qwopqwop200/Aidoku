#!/bin/zsh
# replay.zsh WORKTREE NAME [png|nopng] [splits...] [VAR=VALUE ...]
# Replays the given worktree's host into $EVAL/runs/speed2/NAME_{split}; peak RSS in NAME_{split}.time
wt=${1:?}; n=${2:?}; png=${3:-png}; shift 3 2>/dev/null || shift $#
splits=(); for a in $@; do if [[ $a == *=* ]]; then export $a; else splits+=$a; fi; done
(( ${#splits} )) || splits=(dev train test)
source ${0:a:h:h}/lock.zsh
R=$EVAL/runs/speed2; mkdir -p $R
take_slot speed2-$n
cd $wt
flag=(); [[ $png == nopng ]] && flag=(--no-png)
for s in $splits; do
  rm -rf "$R/${n:?}_$s"
  /usr/bin/time -l swift Scripts/image-translation.swift --split $s \
    --manifest $MANIFEST \
    --jobs 4 $flag --replay-translations $REPLAY \
    --output $R/${n}_$s > $R/${n}_$s.log 2> $R/${n}_$s.time
  echo "$s exit $?"
done
rm -rf "${slot:?}"
