import sys
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parents[1]
# tools/serving-identifiability modules import each other by bare name
# (schema, bundled, witnesses, census); running the CLIs as scripts
# (python3 tools/serving-identifiability/enumerate.py) puts this directory on
# sys.path already. Tests get the same treatment here.
sys.path.insert(0, str(TOOL_DIR))
