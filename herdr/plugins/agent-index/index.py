#!/usr/bin/env python3

import json
import os
import subprocess
import time


def main():
    herdr = os.environ.get("HERDR_BIN_PATH", "herdr")
    try:
        output = subprocess.check_output(
            [herdr, "agent", "list"], text=True, stderr=subprocess.DEVNULL
        )
        agents = json.loads(output)["result"]["agents"]
    except (OSError, subprocess.CalledProcessError, KeyError, TypeError, ValueError):
        return

    seq = time.time_ns()
    for index, agent in enumerate(agents, 1):
        pane_id = agent.get("pane_id")
        if not pane_id:
            continue
        command = [
            herdr,
            "pane",
            "report-metadata",
            pane_id,
            "--source",
            "young.agent-index",
            "--seq",
            str(seq),
        ]
        if index <= 9:
            command.extend(["--token", f"num={index}"])
        else:
            command.extend(["--clear-token", "num"])
        subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )


if __name__ == "__main__":
    main()
