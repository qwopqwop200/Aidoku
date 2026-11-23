#!/bin/zsh
# build.sh WT OUTBIN [extra swift files]
V2=$1/Aidoku/Core/Translation/Pipeline
H=${0:a:h}; o=$2; shift 2
source $H/../../workspace.zsh; mkdir -p $EVAL/convmask/harness/mc
nice -n 10 swiftc -O -module-cache-path $EVAL/convmask/harness/mc -o $o $V2/PipelineTypes.swift $V2/PipelineTuning.swift $V2/PipelineRemovalMask.swift $V2/PipelineMaskNet.swift ${LE:+$V2/PipelineLineEnds.swift} $V2/PipelineWeights.swift $V2/PipelineRotation.swift $V2/PipelineStyle.swift $V2/PipelineFontCorrection.swift $H/stub.swift $@ $H/main.swift
