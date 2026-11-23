#!/bin/zsh
# ab.zsh REF WORKTREE NAME [png|nopng] [splits...] [VAR=VALUE ...]
# In ONE heavy slot: replays the REF worktree (as NAME-ref) then WORKTREE (as NAME) on the same splits,
# then prints compare.py NAME-ref NAME. Same machine conditions for both timings.
ref=${1:?}; wt=${2:?}; n=${3:?}; png=${4:-nopng}; shift 4 2>/dev/null || shift $#
splits=(); envs=(); for a in $@; do if [[ $a == *=* ]]; then envs+=$a; else splits+=$a; fi; done
(( ${#splits} )) || splits=(dev)
source ${0:a:h:h}/lock.zsh
R=$EVAL/runs/speed2; mkdir -p $R
take_slot speed2-$n
flag=(); [[ $png == nopng ]] && flag=(--no-png)
run() { # worktree name split [env...]
  local w=$1 name=$2 s=$3; shift 3
  rm -rf "$R/${name:?}_$s"
  (cd $w && env $@ /usr/bin/time -l swift Scripts/image-translation.swift --split $s \
    --manifest $MANIFEST \
    --jobs 4 $flag --replay-translations $REPLAY \
    --output $R/${name}_$s > $R/${name}_$s.log 2> $R/${name}_$s.time)
  echo "$name $s exit $?"
}
for s in $splits; do
  run $ref $n-ref $s
  run $wt $n $s $envs
done
rm -rf "${slot:?}"
$PYTHON ${0:a:h}/compare.py $n-ref $n $splits
