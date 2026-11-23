# sourced: take_slot NAME -> holds one of 2 global heavy slots (shared with imp/replay.sh)
source ${${(%):-%x}:a:h}/workspace.zsh
S=$EVAL/runs/imp/.slots; mkdir -p $S
take_lock() { # dir name
  local d=$1
  while true; do
    if mkdir $d 2>/dev/null; then echo $$ > $d/pid; echo "$2 $(date +%H:%M)" > $d/who; return; fi
    local pid=$(cat $d/pid 2>/dev/null)
    if [[ -n $pid ]] && ! kill -0 $pid 2>/dev/null; then rm -rf $d; continue; fi
    sleep 15
  done
}
take_slot() {
  slot=""
  while [[ -z $slot ]]; do
    for i in 1 2; do
      if mkdir $S/slot$i 2>/dev/null; then slot=$S/slot$i; echo $$ > $slot/pid; echo "$1 $(date +%H:%M)" > $slot/who; break; fi
      local pid=$(cat $S/slot$i/pid 2>/dev/null)
      if [[ -n $pid ]] && ! kill -0 $pid 2>/dev/null; then rm -rf $S/slot$i; fi
    done
    [[ -z $slot ]] && sleep 15
  done
}
