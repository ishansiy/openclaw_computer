#!/bin/sh
set -eu
runtime_python=$(env -u HERMES_HOME PYTHONPATH=/root/.hermes/hermes-agent /usr/bin/python3 -c 'from pathlib import Path; from pm.environments import selected_venv; print(selected_venv(Path("/root/.hermes/hermes-agent")) / "bin/python")')
exec "$runtime_python" "$@"
