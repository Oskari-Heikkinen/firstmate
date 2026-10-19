Run the daily component-skill drift check, which files one backlog item per drifted component skill in that skill's owner home.

From this home's firstmate checkout, run:

    bin/fm-component-drift.sh run --home <this home> --result <the run-summary path named above>

The command is the whole run: it checks every local home's component maps, files and wakes the owner homes, and writes the run summary.
Do not edit any skill, map or source, and do not file or close any drift item by hand.
Close this task once the command exits; on a nonzero exit, the summary's note and the log it names say what failed, and the scheduler reports it to main firstmate.
